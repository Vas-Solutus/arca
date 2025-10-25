# Building Custom vminit:latest

This guide explains how to build Arca's custom `vminit:latest` OCI image with networking extensions.

## What is vminit?

`vminit` is the init system (PID 1) that runs inside each container's Linux VM. Arca uses a custom fork of Apple's vminitd with extensions for networking:

- **vminitd** - Apple's init system (PID 1) with Arca extensions
- **vmexec** - Apple's exec helper for running processes in containers
- **vlan-service** - VLAN configuration service (vsock:50051) for bridge networks
- **arca-tap-forwarder** - TAP forwarder for overlay networks

## Prerequisites

### 1. Initialize vminitd Submodule

The vminitd fork is managed as a git submodule:

```bash
cd /Users/kiener/code/arca
git submodule update --init --recursive
```

This clones the `Liquescent-Development/arca-vminitd` fork into `vminitd/`.

### 2. Install Swift Static Linux SDK (One-Time Setup)

The static Linux SDK is required to cross-compile Swift code from macOS to Linux.

```bash
cd vminitd/vminitd
make cross-prep
```

This downloads and installs:
- Swift 6.2
- Swift Static Linux SDK for ARM64
- Takes ~5 minutes (one-time setup)

**Verification:**
```bash
swift sdk list
# Should show: swift-6.0.3-RELEASE-static-linux-0.0.1 (default)
```

### 3. Install Go (for Extensions)

The VLAN service and TAP forwarder are written in Go:

```bash
brew install go
# Or download from https://go.dev/dl/
```

Verify:
```bash
go version
# Should be Go 1.24 or later
```

## Building vminit

### Quick Build (Recommended)

From the Arca project root:

```bash
make vminit
```

This runs `scripts/build-vminit.sh` which:
1. Builds VLAN service (Go → Linux ARM64)
2. Builds TAP forwarder (Go → Linux ARM64)
3. Builds vminitd and vmexec (Swift → Linux ARM64)
4. Creates OCI image layout at `~/.arca/vminit/`

**Build time:** ~2-3 minutes (after cross-prep)

### Manual Build Steps

If you want to understand the process or debug issues:

#### Step 1: Build VLAN Service

```bash
cd vminitd/vminitd/extensions/vlan-service
./build.sh
```

Output: `vlan-service` (Linux ARM64 binary, ~10MB)

#### Step 2: Build TAP Forwarder

```bash
cd vminitd/vminitd/extensions/tap-forwarder
./build.sh
```

Output: `arca-tap-forwarder` (Linux ARM64 binary, ~10MB)

#### Step 3: Build vminitd

```bash
cd vminitd/vminitd
BUILD_CONFIGURATION=release make all
```

Outputs:
- `.build/aarch64-unknown-linux-musl/release/vminitd`
- `.build/aarch64-unknown-linux-musl/release/vmexec`

#### Step 4: Create OCI Image

```bash
cd /Users/kiener/code/arca
./scripts/build-vminit.sh
```

This assembles the binaries into an OCI image at `~/.arca/vminit/`.

## Verification

After building, verify the OCI image:

```bash
# Check image layout
ls -lh ~/.arca/vminit/
# Should show: oci-layout, index.json, blobs/

# Check binaries in the layer
cat ~/.arca/vminit/index.json | jq
```

## Using the Custom vminit

### Automatic Usage

Arca's Containerization framework automatically looks for vminit images in this order:

1. `~/.arca/vminit/` (custom build)
2. System-wide locations
3. Bundled vminit (if available)

**No configuration needed** - if `~/.arca/vminit/` exists, it will be used for all containers.

### Restart Arca Daemon

After building a new vminit, restart the daemon to pick it up:

```bash
# If running via make run
Ctrl+C

# Rebuild and restart
make run
```

Or if running as a service:

```bash
sudo launchctl stop com.arca.daemon
sudo launchctl start com.arca.daemon
```

### Verification

Start a container and check if the extensions are available:

```bash
# Start daemon
make run

# In another terminal
export DOCKER_HOST=unix:///tmp/arca.sock

# Create and start a container
docker run -d --name test alpine sleep 3600

# Check if vlan-service is available in the container's VM
# (This would normally be done by Arca automatically)
docker exec test ls -la /usr/local/bin/
# Should show: vlan-service, arca-tap-forwarder
```

## Troubleshooting

### Error: Swift Static Linux SDK not installed

```
ERROR: Swift Static Linux SDK not installed
```

**Solution:**
```bash
cd vminitd/vminitd
make cross-prep
```

### Error: vlan-service binary not built

```
ERROR: vlan-service binary not built
```

**Check:**
```bash
cd vminitd/vminitd/extensions/vlan-service
./build.sh
ls -lh vlan-service
```

**Common causes:**
- Go not installed: `brew install go`
- Missing dependencies: `go mod download`

### Error: vminitd binary not built

```
ERROR: vminitd binary not built at .build/aarch64-unknown-linux-musl/release/vminitd
```

**Check:**
```bash
cd vminitd/vminitd
BUILD_CONFIGURATION=release make all
ls -lh .build/aarch64-unknown-linux-musl/release/
```

**Common causes:**
- Static Linux SDK not installed
- Swift version mismatch
- Xcode command line tools not active

### Binaries Too Large

The binaries are statically linked for Linux and include all dependencies:

- vminitd: ~40-50MB (Swift runtime + dependencies)
- vmexec: ~20-30MB
- vlan-service: ~10MB (Go + netlink)
- arca-tap-forwarder: ~10MB (Go + TAP logic)

**Total OCI layer:** ~100-120MB (compressed in tar)

This is normal for statically-linked cross-compiled binaries.

## Updating vminit

When you update the vminitd submodule or modify extensions:

```bash
# Pull latest vminitd changes
cd vminitd
git pull origin main

# Rebuild everything
cd ..
make vminit

# Restart daemon
# (Ctrl+C if running, then make run)
```

## Development Workflow

### Modifying VLAN Service

```bash
# Edit code
vim vminitd/vminitd/extensions/vlan-service/server.go

# Rebuild just the VLAN service
cd vminitd/vminitd/extensions/vlan-service
./build.sh

# Rebuild full vminit image
cd /Users/kiener/code/arca
make vminit

# Restart daemon to pick up changes
```

### Modifying vminitd

```bash
# Edit Swift code
vim vminitd/vminitd/Sources/vminitd/main.swift

# Rebuild vminitd
cd vminitd/vminitd
BUILD_CONFIGURATION=release make all

# Rebuild full vminit image
cd /Users/kiener/code/arca
make vminit

# Restart daemon
```

## Architecture Details

### OCI Image Structure

```
~/.arca/vminit/
├── oci-layout              # OCI version marker
├── index.json              # Image index with "latest" tag
└── blobs/sha256/
    ├── <layer-digest>      # Layer tarball (contains rootfs)
    ├── <config-digest>     # Image config
    └── <manifest-digest>   # Manifest

Layer contents:
/sbin/vminitd                      # Init system (PID 1)
/sbin/vmexec                       # Exec helper
/usr/local/bin/vlan-service        # VLAN service (vsock:50051)
/usr/local/bin/arca-tap-forwarder  # TAP forwarder (legacy)
```

### Service Startup

When a container starts:

1. Containerization framework loads vminit:latest OCI image
2. Boots Linux VM with vminitd as PID 1
3. vminitd starts and listens on vsock for management commands
4. vlan-service binary is available for Arca to exec via vsock
5. Container's main process runs as child of vminitd

### VLAN Service Usage

The VLAN service runs **on-demand** - it's exec'd by Arca when needed:

```swift
// In NetworkConfigClient.swift
let execID = "vlan-service"
let process = try await container.exec(execID,
    arguments: ["/usr/local/bin/vlan-service", "--vsock-port", "50051"])
```

It stays running for the container's lifetime and handles VLAN configuration via gRPC.

## See Also

- [VLAN Router Architecture](VLAN_ROUTER_ARCHITECTURE.md) - Complete VLAN networking design
- [Implementation Plan](IMPLEMENTATION_PLAN.md) - Phase 3.5.5 details
- [CLAUDE.md](../CLAUDE.md) - Build instructions and project overview