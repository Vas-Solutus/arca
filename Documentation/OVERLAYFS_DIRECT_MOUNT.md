# OverlayFS Direct Mount Architecture

## Overview

Arca implements OverlayFS-based container filesystem layering by mounting OverlayFS directly at each container's rootfs path. This approach avoids Linux kernel limitations with bind mounts from OverlayFS becoming read-only.

## Architecture

### Components

1. **OverlayFSMounter** (Host - Swift)
   - Unpacks OCI image layers to cache (`~/.arca/layers/`)
   - Creates writable upperdir for each container (`~/.arca/containers/{id}/upperdir`)
   - Attaches block devices to VM (vdb=writable.ext4, vdc+=layer filesystems)

2. **vminitd** (Guest - PID 1)
   - Detects OverlayFS layers during boot via block device inspection
   - Saves mount options in global state (does NOT mount at `/`)
   - Intercepts rootfs bind mount requests via gRPC handler
   - Mounts OverlayFS directly at `/run/container/{id}/rootfs`

3. **LinuxContainer** (Host - Swift)
   - Filters block device mounts from OCI spec before passing to vmexec
   - Prevents vmexec from attempting duplicate mounts

### Data Flow

```
Container Creation
    ↓
1. OverlayFSMounter unpacks layers to ~/.arca/layers/{sha256}
    ↓
2. Create writable upperdir at ~/.arca/containers/{id}/upperdir
    ↓
3. Format writable.ext4 (vdb) and attach layer devices (vdc, vdd, ...)
    ↓
4. VM boots - vminitd detects layers on vdc, vdd, ...
    ↓
5. vminitd saves OverlayFS mount options:
   "lowerdir=/mnt/vdc:/mnt/vdd:...,upperdir=/mnt/vdb/upper,workdir=/mnt/vdb/work"
    ↓
6. LinuxContainer filters block device mounts from OCI spec
    ↓
7. Host requests bind mount: source=/, dest=/run/container/{id}/rootfs
    ↓
8. vminitd gRPC handler intercepts, mounts OverlayFS directly:
   mount -t overlay overlay /run/container/{id}/rootfs -o {saved_options}
    ↓
9. Container starts with writable OverlayFS rootfs
```

## Implementation Details

### Why Direct Mount Instead of Bind Mount?

**Problem**: Bind mounts from OverlayFS become read-only due to Linux kernel limitations:
```bash
# This pattern FAILS:
mount -t overlay overlay / -o lowerdir=...,upperdir=...,workdir=...  # Writable
mount --bind / /run/container/rootfs  # Becomes READ-ONLY (kernel limitation)
```

**Solution**: Mount OverlayFS directly at the target path:
```bash
# This pattern WORKS:
mount -t overlay overlay /run/container/{id}/rootfs -o lowerdir=...,upperdir=...,workdir=...
# Stays writable!
```

### Key Files

#### containerization/vminitd/Sources/vminitd/Application.swift

```swift
// Global OverlayFS configuration for remounting at container rootfs paths
actor OverlayFSConfig {
    static let shared = OverlayFSConfig()
    private(set) var mountOptions: String?

    func setMountOptions(_ options: String) {
        self.mountOptions = options
    }
}
```

Layer detection during boot:
```swift
// Detect layers on vdc, vdd, vde, ...
let opts = "lowerdir=\(lowerDirs.joined(separator: ":")),upperdir=/mnt/vdb/upper,workdir=/mnt/vdb/work"

// Save options but DON'T mount at /
await OverlayFSConfig.shared.setMountOptions(opts)
```

#### containerization/vminitd/Sources/vminitd/Server+GRPC.swift

Intercept rootfs bind mount requests:
```swift
// Skip block device mounts - already mounted during boot
if request.source.hasPrefix("/dev/vd") && request.source != "/dev" {
    log.info("Skipping block device mount (already mounted during boot)")
    return .init()
}

// Detect rootfs mount request (bind mount from / to /run/container/{id}/rootfs)
// Mount OverlayFS directly at the rootfs path instead of bind mounting
if request.type == "none" &&
   request.options.contains("bind") &&
   request.source == "/" &&
   request.destination.contains("/rootfs") {

    guard let opts = await OverlayFSConfig.shared.mountOptions else {
        throw GRPCStatus(code: .internalError, message: "OverlayFS mount options not available")
    }

    // Mount OverlayFS directly at /run/container/{id}/rootfs
    guard Musl.mount("overlay", request.destination, "overlay", 0, opts) == 0 else {
        throw GRPCStatus(code: .internalError, message: "failed to mount OverlayFS: errno \(errno)")
    }

    return .init()
}
```

#### containerization/Sources/Containerization/LinuxContainer.swift

Filter block device mounts from OCI spec:
```swift
// Filter out block device mounts (/dev/vdb, /dev/vdc, etc.) - these are
// mounted by vminitd during boot for OverlayFS, not by vmexec
let containerMounts = createdState.vm.mounts[self.id] ?? []
spec.mounts = containerMounts.dropFirst().compactMap { mount in
    // Skip block device mounts - they're infrastructure for OverlayFS
    if mount.source.hasPrefix("/dev/vd") && mount.source != "/dev" {
        return nil
    }
    return mount.to
}
```

## Block Device Layout

- **vda**: initfs (vminitd, vmexec, Swift runtime)
- **vdb**: writable.ext4 (upperdir + workdir for OverlayFS)
- **vdc**: First read-only layer (base image)
- **vdd**: Second read-only layer (if exists)
- **vde**: Third read-only layer (if exists)
- ... and so on

Each layer device is mounted at `/mnt/vdc`, `/mnt/vdd`, etc. during boot.

## Container Lifecycle

1. **Create**: Unpack layers, create writable upperdir, attach devices
2. **Start**: vminitd mounts OverlayFS directly at rootfs path
3. **Run**: Container writes go to upperdir on vdb
4. **Stop**: Filesystem remains intact
5. **Remove**: Clean up upperdir and layer references

## Advantages

1. **Writable rootfs**: No bind mount read-only limitation
2. **Layer caching**: Layers shared across containers at `~/.arca/layers/`
3. **Container isolation**: Each container gets own writable upperdir
4. **Clean separation**: Block devices managed by vminitd, not vmexec
5. **OCI compliance**: Proper layered filesystem semantics

## Performance

- Layer unpacking: ~1-2s for typical images (cached after first use)
- OverlayFS mount: <10ms
- Container startup: No additional overhead vs bind mount approach
- Runtime writes: Direct to ext4 upperdir (no VirtioFS overhead)

## Debugging

Enable debug logging in vminitd to see OverlayFS detection and mounting:
```
log.info("Detected OverlayFS layers", metadata: ["count": "\(layers.count)"])
log.info("Mounting OverlayFS at rootfs path", metadata: ["destination": "\(request.destination)"])
```

Check mounted filesystems in guest:
```bash
docker exec {container} mount | grep overlay
```

Should show:
```
overlay on /run/container/{id}/rootfs type overlay (rw,...)
```
