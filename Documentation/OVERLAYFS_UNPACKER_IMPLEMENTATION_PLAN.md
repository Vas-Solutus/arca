# OverlayFS Unpacker Implementation Plan

**Status**: 🟡 NOT STARTED
**Goal**: Replace sequential layer unpacking with parallel OverlayFS-based architecture
**Expected Performance**: 129s → ~80s first container, <1s subsequent containers

---

## Table of Contents
- [Overview](#overview)
- [Current vs Proposed Architecture](#current-vs-proposed-architecture)
- [Success Criteria](#success-criteria)
- [Implementation Phases](#implementation-phases)
- [Testing Strategy](#testing-strategy)
- [Performance Benchmarks](#performance-benchmarks)

---

## Overview

### Problem
Container creation takes 129 seconds because ALL image layers are unpacked sequentially into a single EXT4 filesystem, even though:
1. Layers could be unpacked in parallel (they're independent until merge)
2. Layers are reused across containers (nginx and apache share base debian)
3. Sequential unpacking prevents parallelization of decompression (CPU-bound)

### Solution
Implement Docker's production architecture:
1. **Parallel unpacking**: Each layer unpacks to its own isolated EXT4 in parallel
2. **Layer caching**: Layers stored at `~/.arca/layers/{digest}/layer.ext4` and reused
3. **OverlayFS stacking**: Layers mounted as read-only, stacked with OverlayFS in guest
4. **Copy-on-write upper layer**: Container writes go to dedicated upper directory

### Architecture Benefits
- ✅ **40% faster first container** (129s → ~80s with 3 concurrent unpacks)
- ✅ **99% faster subsequent containers** (129s → <1s, all layers cached)
- ✅ **Perfect layer reuse** (automatic sharing across images)
- ✅ **Docker-native** (matches production Docker architecture)
- ✅ **Enables future features** (buildx, layer export, garbage collection)

---

## Current vs Proposed Architecture

### Current (Sequential EXT4)
```swift
// 129 seconds for 9-layer nginx image
let filesystem = EXT4.Formatter(path, size: 8.gib())
for layer in manifest.layers {  // ← SEQUENTIAL
    let content = await image.getContent(layer.digest)
    filesystem.unpack(content)  // ← Unpack onto same EXT4, must wait for previous
}
// Result: Single rootfs.ext4 with all layers merged
```

**Flow**:
```
Container 1: Unpack all 9 layers → 129s
Container 2: Unpack all 9 layers → 129s (no reuse!)
```

### Proposed (Parallel OverlayFS)
```swift
// 80 seconds first time, <1s subsequent
let unpacker = OverlayFSUnpacker()
let layerMounts = try await withThrowingTaskGroup { group in
    for layer in manifest.layers {  // ← PARALLEL
        group.addTask {
            await unpacker.unpackLayerToCache(layer)  // ← Each layer isolated
        }
    }
    return await group.collect()
}
// Result: Multiple read-only layer.ext4 files + empty upper/work dirs
// Guest: mount -t overlay -o lowerdir=L1:L2:L3,upperdir=upper,workdir=work overlay /
```

**Flow**:
```
Container 1:
  Parallel unpack (3 concurrent): Layer1(40s), Layer2(30s), Layer3(20s) = 40s
  Parallel unpack (3 concurrent): Layer4-6 = 20s
  Parallel unpack (3 concurrent): Layer7-9 = 20s
  Total: ~80s

Container 2:
  Check cache for all 9 layers → ALL HIT
  Create empty upper/work dirs → <0.1s
  Mount OverlayFS in guest → <0.5s
  Total: <1s 🚀
```

---

## Success Criteria

### Phase 1: Parallel Layer Cache (Host-Side)
- [ ] **SC-1.1**: `OverlayFSUnpacker` unpacks 3 layers in parallel (measured via timestamps)
- [ ] **SC-1.2**: Each layer cached at `~/.arca/layers/{digest}/layer.ext4`
- [ ] **SC-1.3**: Cache hit for existing layers (no re-unpack)
- [ ] **SC-1.4**: 9-layer nginx image unpacks in <90s (vs 129s baseline)
- [ ] **SC-1.5**: Database tracks cached layers (digest, path, size, created_at)

**Test Command**:
```bash
# First nginx container (cache miss)
time docker run -d nginx:latest
# Expected: 70-90 seconds (parallel unpacking)

# Second nginx container (cache hit)
time docker run -d nginx:latest
# Expected: <2 seconds (all layers cached)

# Check cache
ls -lh ~/.arca/layers/sha256:*/layer.ext4
# Expected: 9 layer.ext4 files (one per nginx layer)
```

### Phase 2: OverlayFS Guest Integration
- [ ] **SC-2.1**: vminitd extension mounts OverlayFS with multiple lower layers
- [ ] **SC-2.2**: Multiple block devices attached to guest VM (one per layer)
- [ ] **SC-2.3**: Container filesystem shows merged view of all layers
- [ ] **SC-2.4**: Container writes persist to upper layer only (lower layers unchanged)
- [ ] **SC-2.5**: Whiteout files work correctly (deleted files from lower layers)

**Test Command**:
```bash
# Create container
docker run -it --name test-overlay alpine sh

# Inside container - verify merged filesystem
ls -la /  # Should show files from all layers

# Write a file
echo "test" > /root/newfile.txt

# Exit and inspect layers
docker stop test-overlay
# Verify: lower layers unchanged, upper layer has newfile.txt
```

### Phase 3: Layer Cache Management
- [ ] **SC-3.1**: `LayerCacheManager` tracks all cached layers in database
- [ ] **SC-3.2**: `docker system df` shows layer cache usage
- [ ] **SC-3.3**: `docker system prune` can clean unused layers
- [ ] **SC-3.4**: Reference counting prevents deletion of in-use layers
- [ ] **SC-3.5**: Garbage collection removes unreferenced layers

**Test Command**:
```bash
# Check cache usage
docker system df
# Expected: Shows "LAYER CACHE" section

# Pull multiple images sharing base
docker pull nginx:latest
docker pull nginx:alpine
# Expected: Shared layers only cached once

# Remove containers and images
docker rm -f $(docker ps -aq)
docker rmi nginx:latest nginx:alpine

# Prune dangling layers
docker system prune --volumes
# Expected: Unreferenced layers removed from ~/.arca/layers/
```

### End-to-End Success Criteria
- [ ] **SC-E2E-1**: First nginx container creation: <90s (baseline: 129s)
- [ ] **SC-E2E-2**: Second nginx container creation: <2s (baseline: 129s)
- [ ] **SC-E2E-3**: nginx + apache containers share base layer (verified in DB)
- [ ] **SC-E2E-4**: All existing tests pass (Phase 1-6 integration tests)
- [ ] **SC-E2E-5**: Container functionality unchanged (exec, logs, network, volumes)
- [ ] **SC-E2E-6**: Disk usage reasonable (layers + upper < 2x original)

---

## Implementation Phases

### Phase 1: Parallel Layer Cache (Host-Side)
**Estimated Time**: 3-4 days

#### Task 1.1: Create OverlayFSUnpacker ✅ NOT STARTED
**File**: `containerization/Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift`

**Implementation**:
```swift
public struct OverlayFSUnpacker: Unpacker {
    let layerCachePath: URL

    /// Unpack image layers in parallel to cache directory
    public func unpack(
        _ image: Image,
        for platform: Platform,
        at containerPath: URL,
        progress: ProgressHandler? = nil
    ) async throws -> OverlayFSConfig {
        let manifest = try await image.manifest(for: platform)

        // Parallel unpack with concurrency limit (3 concurrent)
        let layerMounts = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            var results: [(Int, URL)] = []

            for (index, layer) in manifest.layers.enumerated() {
                // Limit concurrency to 3
                if results.count >= 3 {
                    if let result = try await group.next() {
                        results.append(result)
                    }
                }

                group.addTask {
                    let path = try await self.unpackLayerToCache(
                        image: image,
                        layer: layer,
                        progress: progress
                    )
                    return (index, path)
                }
            }

            // Collect remaining
            for try await result in group {
                results.append(result)
            }

            // Sort by index to maintain layer order
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        // Create upper and work directories for this container
        let upperDir = containerPath.appendingPathComponent("upper")
        let workDir = containerPath.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: upperDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        return OverlayFSConfig(
            lowerLayers: layerMounts,
            upperDir: upperDir,
            workDir: workDir
        )
    }

    private func unpackLayerToCache(
        image: Image,
        layer: Descriptor,
        progress: ProgressHandler?
    ) async throws -> URL {
        let cacheKey = layer.digest
        let layerDir = layerCachePath.appendingPathComponent(cacheKey)
        let layerPath = layerDir.appendingPathComponent("layer.ext4")

        // Check cache
        if FileManager.default.fileExists(atPath: layerPath.path) {
            logger.debug("Layer cache HIT", metadata: [
                "digest": "\(cacheKey.prefix(19))...",
                "path": "\(layerPath.path)"
            ])
            return layerPath
        }

        logger.debug("Layer cache MISS - unpacking", metadata: [
            "digest": "\(cacheKey.prefix(19))..."
        ])

        // Create layer directory
        try FileManager.default.createDirectory(at: layerDir, withIntermediateDirectories: true)

        // Get layer content
        let content = try await image.getContent(digest: layer.digest)

        // Determine compression
        let compression: ContainerizationArchive.Filter
        switch layer.mediaType {
        case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
            compression = .none
        case MediaTypes.imageLayerGzip, MediaTypes.dockerImageLayerGzip:
            compression = .gzip
        default:
            throw ContainerizationError(.unsupported, message: "Media type \(layer.mediaType) not supported")
        }

        // Unpack to isolated EXT4 (2GB should be enough for most layers)
        let filesystem = try EXT4.Formatter(
            FilePath(layerPath.path),
            minDiskSize: 2 * 1024 * 1024 * 1024  // 2 GB
        )
        defer { try? filesystem.close() }

        try filesystem.unpack(
            source: content.path,
            format: .paxRestricted,
            compression: compression,
            progress: progress
        )

        logger.info("Layer cached", metadata: [
            "digest": "\(cacheKey.prefix(19))...",
            "path": "\(layerPath.path)"
        ])

        return layerPath
    }
}

/// Configuration for OverlayFS mount
public struct OverlayFSConfig: Sendable {
    public let lowerLayers: [URL]  // Paths to layer.ext4 files (ordered bottom to top)
    public let upperDir: URL       // Writable upper directory
    public let workDir: URL        // OverlayFS work directory

    public init(lowerLayers: [URL], upperDir: URL, workDir: URL) {
        self.lowerLayers = lowerLayers
        self.upperDir = upperDir
        self.workDir = workDir
    }
}
```

**Success Criteria**:
- [ ] File compiles without errors
- [ ] Can unpack nginx:latest layers to `~/.arca/layers/{digest}/layer.ext4`
- [ ] Logs show parallel execution (3 layers unpacking simultaneously)
- [ ] Second call with same image shows cache hits for all layers

**Test**:
```bash
# Unit test
swift test --filter OverlayFSUnpackerTests

# Integration test - time first unpack
time swift run cctl run --name test1 nginx:latest
# Expected: Logs show "Layer cache MISS" for all layers

# Time second unpack (should use cache)
time swift run cctl run --name test2 nginx:latest
# Expected: Logs show "Layer cache HIT" for all layers, much faster
```

---

#### Task 1.2: Update ContainerManager to use OverlayFSUnpacker ✅ NOT STARTED
**File**: `containerization/Sources/Containerization/ContainerManager.swift`

**Changes**:
1. Replace `unpack()` method to use `OverlayFSUnpacker`
2. Store `OverlayFSConfig` instead of single `Mount`
3. Update `create()` methods to handle new flow

**Implementation**:
```swift
// Replace lines 439-454
private func unpackWithOverlay(image: Image, containerPath: URL, size: UInt64) async throws -> OverlayFSConfig {
    let layerCachePath = imageStore.path.appendingPathComponent("layers")

    // Create cache directory if needed
    try FileManager.default.createDirectory(at: layerCachePath, withIntermediateDirectories: true)

    let unpacker = OverlayFSUnpacker(layerCachePath: layerCachePath)
    return try await unpacker.unpack(image, for: .current, at: containerPath)
}

// Update create() method (lines 375-394)
public mutating func create(
    _ id: String,
    image: Image,
    rootfsSizeInBytes: UInt64 = 8.gib(),
    configuration: (inout LinuxContainer.Configuration) throws -> Void
) async throws -> LinuxContainer {
    let path = try createContainerRoot(id)

    let overlayConfig = try await unpackWithOverlay(
        image: image,
        containerPath: path,
        size: rootfsSizeInBytes
    )

    return try await create(
        id,
        image: image,
        overlayConfig: overlayConfig,
        configuration: configuration
    )
}

// Add new create() overload that accepts OverlayFSConfig
public mutating func create(
    _ id: String,
    image: Image,
    overlayConfig: OverlayFSConfig,
    configuration: (inout LinuxContainer.Configuration) throws -> Void
) async throws -> LinuxContainer {
    // Store config for later use when creating VM
    // For now, just use first layer as rootfs (temporary - Phase 2 will fix this)
    let rootfs = Mount.block(
        format: "ext4",
        source: overlayConfig.lowerLayers[0].path,
        destination: "/",
        options: []
    )

    // Create container with temporary single-layer mount
    // Phase 2 will extend this to mount all layers + setup OverlayFS
    return try await create(
        id,
        image: image,
        rootfs: rootfs,
        configuration: configuration
    )
}
```

**Success Criteria**:
- [ ] Code compiles without errors
- [ ] Can create containers with new unpacker
- [ ] Layers cached at `~/.arca/layers/{digest}/layer.ext4`
- [ ] Second container creation shows cache hits

**Test**:
```bash
# Create first container
docker run -d --name test1 nginx:latest
# Expected: Logs show layer unpacking, files in ~/.arca/layers/

# Create second container
docker run -d --name test2 nginx:latest
# Expected: Much faster, logs show cache hits

# Verify cache directory
ls -lh ~/.arca/layers/sha256:*/layer.ext4
```

---

#### Task 1.3: Add Layer Cache Database Schema ✅ NOT STARTED
**File**: `Sources/ContainerBridge/StateStore.swift`

**Implementation**:
```swift
// Add to StateStore class (around line 25)
private nonisolated(unsafe) let layerCache = Table("layer_cache")

// Add columns (around line 90)
private nonisolated(unsafe) let layerDigest = Expression<String>("digest")
private nonisolated(unsafe) let layerPath = Expression<String>("path")
private nonisolated(unsafe) let layerSize = Expression<Int64>("size")
private nonisolated(unsafe) let layerCreatedAt = Expression<Date>("created_at")
private nonisolated(unsafe) let layerLastUsed = Expression<Date>("last_used")
private nonisolated(unsafe) let layerRefCount = Expression<Int>("ref_count")

// Add table creation in initialize() (around line 320)
try db.run(layerCache.create(ifNotExists: true) { t in
    t.column(layerDigest, primaryKey: true)
    t.column(layerPath)
    t.column(layerSize)
    t.column(layerCreatedAt)
    t.column(layerLastUsed)
    t.column(layerRefCount, defaultValue: 0)
})

try db.run(layerCache.createIndex(layerDigest, unique: true, ifNotExists: true))

// Add CRUD operations
public func recordLayerCache(digest: String, path: String, size: Int64) throws {
    let now = Date()
    try db.run(layerCache.insert(or: .replace,
        layerDigest <- digest,
        layerPath <- path,
        layerSize <- size,
        layerCreatedAt <- now,
        layerLastUsed <- now,
        layerRefCount <- 0
    ))
}

public func incrementLayerRefCount(digest: String) throws {
    let layer = layerCache.filter(layerDigest == digest)
    try db.run(layer.update(
        layerRefCount += 1,
        layerLastUsed <- Date()
    ))
}

public func decrementLayerRefCount(digest: String) throws {
    let layer = layerCache.filter(layerDigest == digest)
    try db.run(layer.update(layerRefCount -= 1))
}

public func loadLayerCache(digest: String) throws -> (path: String, size: Int64, refCount: Int)? {
    guard let row = try db.pluck(layerCache.filter(layerDigest == digest)) else {
        return nil
    }
    return (
        path: row[layerPath],
        size: row[layerSize],
        refCount: row[layerRefCount]
    )
}

public func loadAllCachedLayers() throws -> [(digest: String, path: String, size: Int64, refCount: Int, lastUsed: Date)] {
    var result: [(String, String, Int64, Int, Date)] = []
    for row in try db.prepare(layerCache) {
        result.append((
            row[layerDigest],
            row[layerPath],
            row[layerSize],
            row[layerRefCount],
            row[layerLastUsed]
        ))
    }
    return result
}

public func getUnreferencedLayers() throws -> [String] {
    var digests: [String] = []
    for row in try db.prepare(layerCache.filter(layerRefCount == 0)) {
        digests.append(row[layerDigest])
    }
    return digests
}

public func deleteLayerCache(digest: String) throws {
    let layer = layerCache.filter(layerDigest == digest)
    try db.run(layer.delete())
}
```

**Success Criteria**:
- [ ] Database migration runs successfully
- [ ] Can record layer cache entries
- [ ] Can query cached layers
- [ ] Reference counting works correctly

**Test**:
```bash
# Create container (should record layers in DB)
docker run -d nginx:latest

# Query database directly
sqlite3 ~/.arca/state.db "SELECT digest, path, ref_count FROM layer_cache;"
# Expected: 9 rows (one per nginx layer)

# Remove container (should decrement ref counts)
docker rm -f $(docker ps -aq)

# Check ref counts
sqlite3 ~/.arca/state.db "SELECT digest, ref_count FROM layer_cache;"
# Expected: All ref_count = 0
```

---

#### Task 1.4: Integrate Layer Cache with OverlayFSUnpacker ✅ NOT STARTED
**File**: `containerization/Sources/Containerization/Image/Unpacker/OverlayFSUnpacker.swift`

**Changes**:
1. Add `StateStore` parameter to `OverlayFSUnpacker`
2. Record layers in database after unpacking
3. Update reference counts when containers use layers

**Implementation**:
```swift
public struct OverlayFSUnpacker: Unpacker {
    let layerCachePath: URL
    let stateStore: StateStore?  // Optional for testing

    public init(layerCachePath: URL, stateStore: StateStore? = nil) {
        self.layerCachePath = layerCachePath
        self.stateStore = stateStore
    }

    private func unpackLayerToCache(...) async throws -> URL {
        // ... existing cache check ...

        // After unpacking:
        if let stateStore = self.stateStore {
            let fileSize = try FileManager.default.attributesOfItem(atPath: layerPath.path)[.size] as? Int64 ?? 0
            try await stateStore.recordLayerCache(
                digest: cacheKey,
                path: layerPath.path,
                size: fileSize
            )
        }

        return layerPath
    }

    public func unpack(...) async throws -> OverlayFSConfig {
        let config = // ... existing implementation ...

        // Increment ref count for all layers used by this container
        if let stateStore = self.stateStore {
            for layer in manifest.layers {
                try await stateStore.incrementLayerRefCount(digest: layer.digest)
            }
        }

        return config
    }
}
```

**Success Criteria**:
- [ ] Layers recorded in database after unpacking
- [ ] Reference counts increment when containers created
- [ ] Reference counts decrement when containers removed

**Test**:
```bash
# Create container
docker run -d --name test1 nginx:latest

# Check ref counts (should be 1 for all nginx layers)
sqlite3 ~/.arca/state.db "SELECT substr(digest,1,19), ref_count FROM layer_cache;"

# Create second container
docker run -d --name test2 nginx:latest

# Check ref counts (should be 2 for all nginx layers)
sqlite3 ~/.arca/state.db "SELECT substr(digest,1,19), ref_count FROM layer_cache;"

# Remove first container
docker rm -f test1

# Check ref counts (should be 1 for all nginx layers)
sqlite3 ~/.arca/state.db "SELECT substr(digest,1,19), ref_count FROM layer_cache;"
```

---

### Phase 2: OverlayFS Guest Integration (vminitd)
**Estimated Time**: 3-4 days

#### Task 2.1: Create OverlayFS Mounter Extension ✅ NOT STARTED
**Files**:
- `containerization/vminitd/extensions/overlayfs-mounter/mounter.go`
- `containerization/vminitd/extensions/overlayfs-mounter/proto/overlayfs.proto`

**Implementation** (`proto/overlayfs.proto`):
```protobuf
syntax = "proto3";

package arca.overlayfs.v1;

option go_package = "github.com/apple/containerization/vminitd/extensions/overlayfs-mounter/proto";

service OverlayFSService {
    // Mount OverlayFS with multiple lower layers
    rpc MountOverlay(MountOverlayRequest) returns (MountOverlayResponse);

    // Unmount OverlayFS
    rpc UnmountOverlay(UnmountOverlayRequest) returns (UnmountOverlayResponse);
}

message MountOverlayRequest {
    // Block device paths in guest (e.g., /dev/vda, /dev/vdb, ...)
    repeated string lower_block_devices = 1;

    // Upper directory for writable layer
    string upper_dir = 2;

    // Work directory for OverlayFS metadata
    string work_dir = 3;

    // Target mount point (usually /)
    string target = 4;
}

message MountOverlayResponse {
    bool success = 1;
    string error_message = 2;
}

message UnmountOverlayRequest {
    string target = 1;
}

message UnmountOverlayResponse {
    bool success = 1;
    string error_message = 2;
}
```

**Implementation** (`mounter.go`):
```go
package overlayfs

import (
    "context"
    "fmt"
    "os"
    "os/exec"
    "strings"

    "golang.org/x/sys/unix"
    pb "github.com/apple/containerization/vminitd/extensions/overlayfs-mounter/proto"
)

type Server struct {
    pb.UnimplementedOverlayFSServiceServer
}

func (s *Server) MountOverlay(ctx context.Context, req *pb.MountOverlayRequest) (*pb.MountOverlayResponse, error) {
    // 1. Create mount points for lower layers
    lowerDirs := []string{}
    for i, blockDev := range req.LowerBlockDevices {
        mountPoint := fmt.Sprintf("/overlay/lower/%d", i)
        if err := os.MkdirAll(mountPoint, 0755); err != nil {
            return &pb.MountOverlayResponse{
                Success: false,
                ErrorMessage: fmt.Sprintf("failed to create lower mount point: %v", err),
            }, nil
        }

        // Mount the block device (read-only EXT4)
        if err := unix.Mount(blockDev, mountPoint, "ext4", unix.MS_RDONLY, ""); err != nil {
            return &pb.MountOverlayResponse{
                Success: false,
                ErrorMessage: fmt.Sprintf("failed to mount %s: %v", blockDev, err),
            }, nil
        }

        lowerDirs = append(lowerDirs, mountPoint)
    }

    // 2. Create upper and work directories
    if err := os.MkdirAll(req.UpperDir, 0755); err != nil {
        return &pb.MountOverlayResponse{
            Success: false,
            ErrorMessage: fmt.Sprintf("failed to create upper dir: %v", err),
        }, nil
    }

    if err := os.MkdirAll(req.WorkDir, 0755); err != nil {
        return &pb.MountOverlayResponse{
            Success: false,
            ErrorMessage: fmt.Sprintf("failed to create work dir: %v", err),
        }, nil
    }

    // 3. Mount OverlayFS
    // lowerdir must be ordered from top to bottom (reverse of input)
    reversedLowers := make([]string, len(lowerDirs))
    for i, dir := range lowerDirs {
        reversedLowers[len(lowerDirs)-1-i] = dir
    }
    lowerOpt := strings.Join(reversedLowers, ":")

    data := fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lowerOpt, req.UpperDir, req.WorkDir)

    if err := unix.Mount("overlay", req.Target, "overlay", 0, data); err != nil {
        return &pb.MountOverlayResponse{
            Success: false,
            ErrorMessage: fmt.Sprintf("failed to mount overlay: %v", err),
        }, nil
    }

    return &pb.MountOverlayResponse{Success: true}, nil
}

func (s *Server) UnmountOverlay(ctx context.Context, req *pb.UnmountOverlayRequest) (*pb.UnmountOverlayResponse, error) {
    if err := unix.Unmount(req.Target, 0); err != nil {
        return &pb.UnmountOverlayResponse{
            Success: false,
            ErrorMessage: fmt.Sprintf("failed to unmount: %v", err),
        }, nil
    }

    // Clean up lower mounts
    exec.Command("umount", "-R", "/overlay/lower").Run()

    return &pb.UnmountOverlayResponse{Success: true}, nil
}
```

**Success Criteria**:
- [ ] Protocol buffer compiles successfully
- [ ] Go service compiles and runs
- [ ] Can mount OverlayFS with multiple layers manually
- [ ] Writes go to upper layer only
- [ ] Lower layers remain read-only

**Test** (manual in VM):
```bash
# Inside a test VM, manually test the service
# 1. Create test layers
dd if=/dev/zero of=/tmp/layer1.ext4 bs=1M count=100
mkfs.ext4 /tmp/layer1.ext4
mount /tmp/layer1.ext4 /mnt
echo "layer1" > /mnt/file1.txt
umount /mnt

# 2. Test mount via gRPC
grpcurl -plaintext -d '{
  "lower_block_devices": ["/tmp/layer1.ext4"],
  "upper_dir": "/tmp/upper",
  "work_dir": "/tmp/work",
  "target": "/mnt"
}' localhost:51821 arca.overlayfs.v1.OverlayFSService/MountOverlay

# 3. Verify
ls /mnt  # Should show layer1 contents
echo "test" > /mnt/file2.txt  # Should succeed
ls /tmp/upper  # Should show file2.txt
```

---

#### Task 2.2: Integrate OverlayFS Service into vminitd ✅ NOT STARTED
**Files**:
- `containerization/vminitd/Sources/vminitd/Server+GRPC.swift`
- `containerization/vminitd/cmd/vminitd/main.go` (if Go-based)

**Implementation**:
```swift
// Add to Server+GRPC.swift (if Swift-based vminitd)
// Or update main.go if Go-based

// Register OverlayFS service on vsock port 51821
let overlayfsService = OverlayFSServer()
grpcServer.register(overlayfsService, on: 51821)
```

**Success Criteria**:
- [ ] vminitd starts successfully with OverlayFS service
- [ ] Service listens on vsock port 51821
- [ ] Can connect from host to service

**Test**:
```bash
# Rebuild vminit with new service
make vminit

# Start container
docker run -d nginx:latest

# Check if service is running (from host)
# This will be testable once we have the client in Phase 2.3
```

---

#### Task 2.3: Create OverlayFS Client in Arca ✅ NOT STARTED
**File**: `Sources/ContainerBridge/OverlayFSClient.swift`

**Implementation**:
```swift
import Foundation
import Logging
import GRPC
import NIO

/// Client for OverlayFS service running in container VM
public actor OverlayFSClient {
    private let channel: GRPCChannel
    private let client: Arca_Overlayfs_V1_OverlayFSServiceAsyncClient
    private let logger: Logger

    public init(container: Containerization.Container, logger: Logger) async throws {
        self.logger = logger

        // Connect to OverlayFS service via vsock port 51821
        let connection = try await container.dial(51821)

        // Create NIO channel from file descriptor
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.channel = try GRPCChannelPool.with(
            target: .unixDomainSocket(connection.fileDescriptor),
            transportSecurity: .plaintext,
            eventLoopGroup: group
        )

        self.client = Arca_Overlayfs_V1_OverlayFSServiceAsyncClient(channel: channel)
    }

    /// Mount OverlayFS with specified layer configuration
    public func mountOverlay(
        lowerBlockDevices: [String],
        upperDir: String,
        workDir: String,
        target: String
    ) async throws {
        logger.debug("Mounting OverlayFS", metadata: [
            "layers": "\(lowerBlockDevices.count)",
            "target": "\(target)"
        ])

        let request = Arca_Overlayfs_V1_MountOverlayRequest.with {
            $0.lowerBlockDevices = lowerBlockDevices
            $0.upperDir = upperDir
            $0.workDir = workDir
            $0.target = target
        }

        let response = try await client.mountOverlay(request)

        guard response.success else {
            logger.error("OverlayFS mount failed", metadata: [
                "error": "\(response.errorMessage)"
            ])
            throw OverlayFSClientError.mountFailed(response.errorMessage)
        }

        logger.info("OverlayFS mounted successfully", metadata: [
            "layers": "\(lowerBlockDevices.count)",
            "target": "\(target)"
        ])
    }

    /// Unmount OverlayFS
    public func unmountOverlay(target: String) async throws {
        logger.debug("Unmounting OverlayFS", metadata: ["target": "\(target)"])

        let request = Arca_Overlayfs_V1_UnmountOverlayRequest.with {
            $0.target = target
        }

        let response = try await client.unmountOverlay(request)

        guard response.success else {
            logger.error("OverlayFS unmount failed", metadata: [
                "error": "\(response.errorMessage)"
            ])
            throw OverlayFSClientError.unmountFailed(response.errorMessage)
        }

        logger.info("OverlayFS unmounted successfully")
    }

    deinit {
        try? channel.close().wait()
    }
}

public enum OverlayFSClientError: Error, CustomStringConvertible {
    case mountFailed(String)
    case unmountFailed(String)
    case connectionFailed(String)

    public var description: String {
        switch self {
        case .mountFailed(let msg): return "OverlayFS mount failed: \(msg)"
        case .unmountFailed(let msg): return "OverlayFS unmount failed: \(msg)"
        case .connectionFailed(let msg): return "Failed to connect to OverlayFS service: \(msg)"
        }
    }
}
```

**Success Criteria**:
- [ ] Can connect to OverlayFS service in container
- [ ] Can send mount request
- [ ] Receives success response
- [ ] Handles errors gracefully

**Test**:
```bash
# Unit test
swift test --filter OverlayFSClientTests

# Integration test - create container and mount overlay
docker run -d nginx:latest
# Logs should show "OverlayFS mounted successfully"
```

---

#### Task 2.4: Update LinuxContainer to Attach Multiple Block Devices ✅ NOT STARTED
**File**: `containerization/Sources/Containerization/LinuxContainer.swift`

**Changes**:
1. Accept `OverlayFSConfig` in configuration
2. Attach all layer block devices to VM
3. Attach upper directory as VirtioFS share
4. Call OverlayFS mount after VM starts

**Implementation**:
```swift
// Add to LinuxContainer.Configuration (around line 40)
public struct Configuration: Sendable {
    // ... existing fields ...

    /// OverlayFS configuration (if using layered rootfs)
    public var overlayConfig: OverlayFSConfig?
}

// Update create() method (around line 250)
public func create() async throws {
    // ... existing VM setup ...

    // If using OverlayFS, attach all layer block devices
    if let overlayConfig = config.overlayConfig {
        // Attach lower layer block devices (read-only)
        for (index, layerPath) in overlayConfig.lowerLayers.enumerated() {
            let device = try VZDiskImageStorageDeviceAttachment(
                url: layerPath,
                readOnly: true,
                cachingMode: .automatic,
                synchronizationMode: .none
            )
            let blockConfig = VZVirtioBlockDeviceConfiguration(attachment: device)
            vmConfig.storageDevices.append(blockConfig)

            logger.debug("Attached layer block device", metadata: [
                "index": "\(index)",
                "path": "\(layerPath.path)"
            ])
        }

        // Attach upper directory as VirtioFS (read-write)
        let upperShare = VZVirtioFileSystemDeviceConfiguration(tag: "overlay-upper")
        upperShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: overlayConfig.upperDir, readOnly: false)
        )
        vmConfig.directorySharingDevices.append(upperShare)

        // Attach work directory as VirtioFS (read-write)
        let workShare = VZVirtioFileSystemDeviceConfiguration(tag: "overlay-work")
        workShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: overlayConfig.workDir, readOnly: false)
        )
        vmConfig.directorySharingDevices.append(workShare)
    }

    // ... start VM ...

    // After VM starts, mount OverlayFS if configured
    if let overlayConfig = config.overlayConfig {
        try await mountOverlayFS(overlayConfig)
    }
}

private func mountOverlayFS(_ config: OverlayFSConfig) async throws {
    logger.info("Mounting OverlayFS in container", metadata: [
        "layers": "\(config.lowerLayers.count)"
    ])

    guard let vm = try? await state.value.createdState("mount overlayfs").vm else {
        throw ContainerizationError(.invalidState, message: "Container not in created state")
    }

    // Connect to OverlayFS service
    let client = try await OverlayFSClient(container: self, logger: logger)

    // Build block device paths (guest sees them as /dev/vdX)
    // First N devices are layers, then upper/work VirtioFS mounts
    var blockDevices: [String] = []
    for i in 0..<config.lowerLayers.count {
        // Block devices start at vda, vdb, vdc, ...
        let deviceChar = Character(UnicodeScalar(97 + i)!)  // 97 = 'a'
        blockDevices.append("/dev/vd\(deviceChar)")
    }

    // Mount OverlayFS
    try await client.mountOverlay(
        lowerBlockDevices: blockDevices,
        upperDir: "/mnt/overlay-upper",  // VirtioFS mount point in guest
        workDir: "/mnt/overlay-work",    // VirtioFS mount point in guest
        target: "/"
    )

    logger.info("OverlayFS mounted successfully")
}
```

**Success Criteria**:
- [ ] VM starts with multiple block devices attached
- [ ] OverlayFS mounts successfully after VM boot
- [ ] Container filesystem shows merged view
- [ ] Writes persist to upper layer

**Test**:
```bash
# Create container
docker run -it --name test-overlay alpine sh

# Inside container
ls -la /  # Should show merged filesystem from all layers
echo "test" > /root/newfile.txt
exit

# Restart container
docker start -ai test-overlay
cat /root/newfile.txt  # Should show "test"
```

---

### Phase 3: Layer Cache Management & Cleanup
**Estimated Time**: 2 days

#### Task 3.1: Implement docker system df for Layer Cache ✅ NOT STARTED
**File**: `Sources/DockerAPI/Handlers/SystemHandlers.swift`

**Implementation**:
```swift
// Update handleSystemDf to include layer cache
public func handleSystemDf() async -> Result<SystemDfResponse, ErrorResponse> {
    // ... existing code for containers, images, volumes ...

    // Add layer cache info
    let layerCacheData: SystemDfLayerCache
    do {
        let cachedLayers = try await stateStore.loadAllCachedLayers()
        let totalSize = cachedLayers.reduce(0) { $0 + $1.size }
        let reclaimable = cachedLayers.filter { $0.refCount == 0 }.reduce(0) { $0 + $1.size }

        layerCacheData = SystemDfLayerCache(
            layerCount: cachedLayers.count,
            size: totalSize,
            reclaimable: reclaimable
        )
    } catch {
        logger.error("Failed to load layer cache data", metadata: ["error": "\(error)"])
        layerCacheData = SystemDfLayerCache(layerCount: 0, size: 0, reclaimable: 0)
    }

    let response = SystemDfResponse(
        // ... existing fields ...
        layerCache: layerCacheData
    )

    return .success(response)
}
```

**Add to Models**:
```swift
// Sources/DockerAPI/Models/System.swift
public struct SystemDfLayerCache: Codable {
    public let layerCount: Int
    public let size: Int64
    public let reclaimable: Int64

    enum CodingKeys: String, CodingKey {
        case layerCount = "LayerCount"
        case size = "Size"
        case reclaimable = "Reclaimable"
    }
}

// Update SystemDfResponse
public struct SystemDfResponse: Codable {
    // ... existing fields ...
    public let layerCache: SystemDfLayerCache?

    enum CodingKeys: String, CodingKey {
        // ... existing cases ...
        case layerCache = "LayerCache"
    }
}
```

**Success Criteria**:
- [ ] `docker system df` shows layer cache section
- [ ] Displays total size and reclaimable size
- [ ] Numbers match database and filesystem

**Test**:
```bash
# Create some containers
docker run -d nginx:latest
docker run -d nginx:alpine

# Check disk usage
docker system df
# Expected output:
# TYPE            TOTAL   ACTIVE  SIZE      RECLAIMABLE
# Images          2       0       xxx MB    xxx MB
# Containers      2       2       xxx KB    0 B
# Local Volumes   0       0       0 B       0 B
# Layer Cache     12      12      xxx MB    0 MB

# Remove containers
docker rm -f $(docker ps -aq)

# Check again (should show reclaimable)
docker system df
# Layer Cache should show Size > Reclaimable
```

---

#### Task 3.2: Implement docker system prune for Layer Cache ✅ NOT STARTED
**File**: `Sources/DockerAPI/Handlers/SystemHandlers.swift`

**Implementation**:
```swift
// Update handleSystemPrune
public func handleSystemPrune(volumes: Bool, all: Bool) async -> Result<SystemPruneResponse, ErrorResponse> {
    // ... existing cleanup logic ...

    // Add layer cache cleanup
    var layersDeleted = 0
    var spaceReclaimed: Int64 = 0

    do {
        // Get unreferenced layers
        let unreferencedLayers = try await stateStore.getUnreferencedLayers()

        for digest in unreferencedLayers {
            guard let layerInfo = try await stateStore.loadLayerCache(digest: digest) else {
                continue
            }

            // Delete from filesystem
            let layerPath = URL(fileURLWithPath: layerInfo.path)
            let parentDir = layerPath.deletingLastPathComponent()

            if FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.removeItem(at: parentDir)
                layersDeleted += 1
                spaceReclaimed += layerInfo.size

                logger.info("Deleted cached layer", metadata: [
                    "digest": "\(digest.prefix(19))...",
                    "size": "\(layerInfo.size)"
                ])
            }

            // Delete from database
            try await stateStore.deleteLayerCache(digest: digest)
        }
    } catch {
        logger.error("Failed to prune layer cache", metadata: ["error": "\(error)"])
    }

    let response = SystemPruneResponse(
        // ... existing fields ...
        layersDeleted: layersDeleted,
        spaceReclaimed: spaceReclaimed + existingSpaceReclaimed
    )

    return .success(response)
}
```

**Success Criteria**:
- [ ] `docker system prune` removes unreferenced layers
- [ ] Filesystem cleaned up correctly
- [ ] Database updated correctly
- [ ] In-use layers protected (ref count > 0)

**Test**:
```bash
# Create and remove containers
docker run -d --name test1 nginx:latest
docker rm -f test1

# Layers should be unreferenced but still exist
ls ~/.arca/layers/sha256:*/layer.ext4
# Expected: Files exist

# Prune
docker system prune -f
# Expected: Output shows "X layers deleted, Y MB reclaimed"

# Verify cleanup
ls ~/.arca/layers/sha256:*/layer.ext4
# Expected: No files (or only referenced layers if other containers exist)
```

---

#### Task 3.3: Add Layer Cache Garbage Collection ✅ NOT STARTED
**File**: `Sources/ContainerBridge/LayerCacheManager.swift`

**Implementation**:
```swift
import Foundation
import Logging

/// Manages layer cache lifecycle and garbage collection
public actor LayerCacheManager {
    private let cachePath: URL
    private let stateStore: StateStore
    private let logger: Logger

    public init(cachePath: URL, stateStore: StateStore, logger: Logger) {
        self.cachePath = cachePath
        self.stateStore = stateStore
        self.logger = logger
    }

    /// Perform garbage collection on layer cache
    /// - Parameter ageDays: Remove layers unused for this many days (default: 30)
    public func garbageCollect(ageDays: Int = 30) async throws {
        logger.info("Starting layer cache garbage collection", metadata: [
            "age_threshold_days": "\(ageDays)"
        ])

        let threshold = Date().addingTimeInterval(-Double(ageDays * 24 * 60 * 60))
        var deletedCount = 0
        var reclaimedBytes: Int64 = 0

        // Get all cached layers
        let allLayers = try await stateStore.loadAllCachedLayers()

        for layer in allLayers {
            // Skip if referenced
            if layer.refCount > 0 {
                continue
            }

            // Skip if recently used
            if layer.lastUsed > threshold {
                continue
            }

            // Delete layer
            let layerPath = URL(fileURLWithPath: layer.path)
            let parentDir = layerPath.deletingLastPathComponent()

            do {
                if FileManager.default.fileExists(atPath: parentDir.path) {
                    try FileManager.default.removeItem(at: parentDir)
                    deletedCount += 1
                    reclaimedBytes += layer.size

                    logger.debug("Deleted stale layer", metadata: [
                        "digest": "\(layer.digest.prefix(19))...",
                        "last_used": "\(layer.lastUsed)",
                        "size": "\(layer.size)"
                    ])
                }

                // Remove from database
                try await stateStore.deleteLayerCache(digest: layer.digest)
            } catch {
                logger.warning("Failed to delete layer", metadata: [
                    "digest": "\(layer.digest.prefix(19))...",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("Garbage collection complete", metadata: [
            "deleted_layers": "\(deletedCount)",
            "reclaimed_bytes": "\(reclaimedBytes)"
        ])
    }

    /// Verify layer cache integrity (filesystem vs database)
    public func verifyIntegrity() async throws {
        logger.info("Verifying layer cache integrity")

        var orphanedFiles = 0
        var missingFiles = 0

        // Check filesystem for orphaned files
        let fm = FileManager.default
        let layerDirs = try fm.contentsOfDirectory(
            at: cachePath,
            includingPropertiesForKeys: nil
        )

        for layerDir in layerDirs {
            let digest = layerDir.lastPathComponent

            // Check if in database
            if try await stateStore.loadLayerCache(digest: digest) == nil {
                logger.warning("Orphaned layer file", metadata: ["digest": "\(digest.prefix(19))..."])
                orphanedFiles += 1

                // Auto-cleanup orphaned files
                try? fm.removeItem(at: layerDir)
            }
        }

        // Check database for missing files
        let allLayers = try await stateStore.loadAllCachedLayers()
        for layer in allLayers {
            if !fm.fileExists(atPath: layer.path) {
                logger.warning("Missing layer file", metadata: [
                    "digest": "\(layer.digest.prefix(19))...",
                    "path": "\(layer.path)"
                ])
                missingFiles += 1

                // Remove from database
                try await stateStore.deleteLayerCache(digest: layer.digest)
            }
        }

        logger.info("Integrity check complete", metadata: [
            "orphaned_files": "\(orphanedFiles)",
            "missing_files": "\(missingFiles)"
        ])
    }
}
```

**Success Criteria**:
- [ ] Can run garbage collection manually
- [ ] Removes old unreferenced layers
- [ ] Protects recently used and referenced layers
- [ ] Verifies database/filesystem consistency

**Test**:
```bash
# Create old layers (simulate by modifying last_used in DB)
sqlite3 ~/.arca/state.db "UPDATE layer_cache SET last_used = datetime('now', '-60 days');"

# Run GC via internal API (need to expose as CLI command)
arca system gc-layers --age-days 30

# Verify old layers removed
sqlite3 ~/.arca/state.db "SELECT COUNT(*) FROM layer_cache;"
# Expected: 0 (or only recent layers)
```

---

## Testing Strategy

### Unit Tests
Location: `Tests/ArcaTests/OverlayFSTests.swift`

```swift
import XCTest
@testable import ContainerBridge

final class OverlayFSUnpackerTests: XCTestCase {
    func testParallelLayerUnpacking() async throws {
        // Test that layers unpack in parallel
        // Verify via timestamps that layers overlap in time
    }

    func testLayerCacheHit() async throws {
        // Test that second unpack uses cached layers
        // Verify no filesystem writes on cache hit
    }

    func testLayerRefCounting() async throws {
        // Test reference counting
        // Create 2 containers, remove 1, verify ref count = 1
    }

    func testGarbageCollection() async throws {
        // Test that old unreferenced layers are removed
        // Test that referenced layers are protected
    }
}
```

### Integration Tests
Location: `Tests/ArcaTests/OverlayFSIntegrationTests.swift`

```swift
@Suite("OverlayFS Integration Tests", .serialized)
struct OverlayFSIntegrationTests {
    static let socketPath = "/tmp/arca-overlayfs-test.sock"

    @Test("First container creates layer cache")
    func testFirstContainerCreatesCache() async throws {
        // docker run nginx:latest
        // Verify layers at ~/.arca/layers/{digest}/layer.ext4
        // Verify database entries
    }

    @Test("Second container uses cached layers")
    func testSecondContainerUsesCache() async throws {
        // docker run nginx:latest (second time)
        // Verify <2s creation time
        // Verify no new files in cache directory
    }

    @Test("Shared layers between images")
    func testSharedLayers() async throws {
        // docker run nginx:latest
        // docker run nginx:alpine
        // Verify some layers are shared (same digest)
    }

    @Test("Container writes persist to upper layer")
    func testUpperLayerWrites() async throws {
        // Create container, write file
        // Stop, start, verify file exists
        // Check that lower layers unchanged
    }

    @Test("System prune removes unreferenced layers")
    func testSystemPrune() async throws {
        // Create container, remove it
        // Run docker system prune
        // Verify layers deleted from filesystem and DB
    }
}
```

### Performance Tests
Location: `Tests/ArcaTests/OverlayFSPerformanceTests.swift`

```swift
@Suite("OverlayFS Performance Tests", .serialized)
struct OverlayFSPerformanceTests {
    @Test("First container creation time")
    func testFirstContainerSpeed() async throws {
        let start = Date()
        // docker run nginx:latest
        let duration = Date().timeIntervalSince(start)

        // Should be <90s (baseline: 129s)
        #expect(duration < 90.0)
    }

    @Test("Second container creation time")
    func testSecondContainerSpeed() async throws {
        // docker run nginx:latest (first time, warm cache)

        let start = Date()
        // docker run nginx:latest (second time)
        let duration = Date().timeIntervalSince(start)

        // Should be <2s (baseline: 129s)
        #expect(duration < 2.0)
    }

    @Test("Parallel unpacking performance")
    func testParallelUnpackingSpeed() async throws {
        // Measure time to unpack 9-layer image
        // Compare to sequential baseline
        // Expect 30-40% improvement
    }
}
```

---

## Performance Benchmarks

### Baseline (Current Sequential)
```
Image: nginx:latest (9 layers)
├── First container:  129 seconds
├── Second container: 129 seconds (no reuse)
└── Shared layers:    None (each container unpacks all layers)
```

### Target (OverlayFS Parallel)
```
Image: nginx:latest (9 layers)
├── First container:  70-90 seconds (parallel unpacking, 3 concurrent)
│   ├── Batch 1 (3 layers in parallel): 40s
│   ├── Batch 2 (3 layers in parallel): 20s
│   └── Batch 3 (3 layers in parallel): 20s
│
├── Second container: <2 seconds (all layers cached)
│   ├── Cache lookup: <0.5s
│   ├── OverlayFS mount: <0.5s
│   └── Total: <2s
│
└── Shared layers (nginx:latest + nginx:alpine):
    ├── Base debian layer: Shared (cache hit)
    ├── nginx layer: Shared (cache hit)
    └── Config layers: Unique (cache miss)
```

### Success Metrics
- [x] **40% faster first container**: 129s → <90s
- [x] **99% faster subsequent containers**: 129s → <2s
- [x] **Layer reuse**: nginx + apache share base layers
- [x] **Disk efficiency**: 10 nginx containers ≈ 1 nginx container + 10 upper layers
- [x] **Correctness**: All Phase 1-6 tests pass with new unpacker

---

## Risk Mitigation

### Risk 1: OverlayFS Kernel Support
**Mitigation**: Kernel config shows `CONFIG_OVERLAY_FS=y` (verified in planning phase)

### Risk 2: Performance Regression
**Mitigation**:
- Implement feature flag to toggle between old/new unpacker
- Run full test suite before and after
- Benchmark both approaches side-by-side

### Risk 3: Data Corruption in Upper Layer
**Mitigation**:
- Upper layer is regular directory (VirtioFS), not OverlayFS responsibility
- OverlayFS is battle-tested (Docker production for years)
- Comprehensive testing of write operations

### Risk 4: Layer Cache Corruption
**Mitigation**:
- Layers are read-only after creation
- Checksum verification (layer digest matches filesystem content)
- Integrity check command (`LayerCacheManager.verifyIntegrity()`)

### Risk 5: Breaking Existing Functionality
**Mitigation**:
- Feature flag allows rollback
- All existing tests must pass
- Incremental rollout (Phase 1 → Phase 2 → Phase 3)

---

## Rollout Plan

### Stage 1: Alpha (Phase 1 Complete)
- Feature flag: `ARCA_USE_OVERLAYFS_UNPACKER=1`
- Limited testing with nginx/alpine images
- Performance validation

### Stage 2: Beta (Phase 2 Complete)
- Feature flag: Default ON, can disable
- Full test suite validation
- Production-like workload testing

### Stage 3: General Availability (Phase 3 Complete)
- Feature flag: Removed (always on)
- Old unpacker code removed
- Documentation updated

---

## Success Declaration

The OverlayFS unpacker implementation will be considered **COMPLETE** when:

1. ✅ All tasks in Phases 1-3 marked complete
2. ✅ All success criteria (SC-*) verified
3. ✅ All unit tests passing
4. ✅ All integration tests passing
5. ✅ Performance benchmarks met:
   - First container: <90s (vs 129s baseline)
   - Second container: <2s (vs 129s baseline)
6. ✅ No regressions in existing functionality
7. ✅ Layer cache management working (df, prune, gc)
8. ✅ Documentation complete

---

## Next Steps

1. **Review this plan** - Get approval on approach and estimates
2. **Begin Phase 1, Task 1.1** - Create `OverlayFSUnpacker.swift`
3. **Iterate through tasks** - Mark complete with evidence (test output, logs)
4. **Update this document** - Track progress, adjust estimates as needed

---

**Document Version**: 1.0
**Last Updated**: 2025-11-13
**Author**: Claude + User Collaboration
