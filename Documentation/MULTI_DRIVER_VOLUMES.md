# Multi-Driver Volume Implementation Plan

**Status**: In Progress
**Created**: 2025-11-07
**Goal**: Support multiple volume drivers (local, block) to give users choice between shareability and performance

## Architecture Overview

### Volume Drivers

| Driver | Backend | Shareable | Performance | Use Case |
|--------|---------|-----------|-------------|----------|
| `local` (default) | VirtioFS directory | ✅ Yes | Good | General purpose, shared data |
| `block` | EXT4 block device | ❌ No (exclusive) | Excellent | Databases, build caches |

### Driver Selection

```bash
# Local driver (default) - VirtioFS directory share
docker volume create myvolume
docker volume create --driver local myvolume

# Block driver - Exclusive EXT4 block device
docker volume create --driver block --opt size=10G mydb
```

### Volume Storage Paths

**Local driver**: `~/.arca/volumes/{name}/data/` (directory)
**Block driver**: `~/.arca/volumes/{name}/volume.img` (EXT4 disk image)

Both store metadata in SQLite database via StateStore.

## Implementation Tasks

### Phase 1: VolumeManager Multi-Driver Support ✅

**File**: `Sources/ContainerBridge/VolumeManager.swift`

- [x] **Task 1.1**: Update `VolumeMetadata` to distinguish driver types
  - Add `driver` field validation (only "local" and "block" supported)
  - Keep existing `format` field for block driver ("ext4")
  - Update `mountpoint` to be directory path for local, file path for block

- [x] **Task 1.2**: Modify `createVolume()` to support both drivers
  - Default to "local" driver if not specified
  - Validate driver is "local" or "block"
  - Branch on driver type:
    - **local**: Create directory at `~/.arca/volumes/{name}/data/`
    - **block**: Keep existing EXT4 creation logic
  - Update error messages

- [x] **Task 1.3**: Add exclusive access tracking for block volumes
  - Query StateStore for containers using this volume
  - Store in-memory map: `blockVolumeUsers: [String: String]` (volumeName → containerID)
  - Add helper method: `acquireBlockVolume(name:containerID:) throws`
  - Add helper method: `releaseBlockVolume(name:containerID:)`

### Phase 2: ContainerManager Integration ✅

**File**: `Sources/ContainerBridge/ContainerManager.swift`

- [x] **Task 2.1**: Update `parseVolumeMounts()` to handle both drivers
  - When resolving named volume, check `volumeMetadata.driver`
  - Branch on driver:
    - **local**: Create `Mount.share()` using `mountpoint` (directory path)
    - **block**: Create `Mount.block()` using `mountpoint` (volume.img path)
  - Keep existing logic for bind mounts

- [x] **Task 2.2**: Add exclusive access validation for block volumes
  - Before creating mount for block volume, call `volumeManager.acquireBlockVolume()`
  - Handle `VolumeError.exclusiveAccessViolation` with clear error
  - On container removal, call `volumeManager.releaseBlockVolume()`

### Phase 3: Error Handling & Messages ✅

**Files**: `Sources/ContainerBridge/VolumeManager.swift`

- [x] **Task 3.1**: Add new error cases to `VolumeError`
  ```swift
  case exclusiveAccessViolation(volumeName: String, ownerContainer: String)
  case unsupportedDriver(String)
  ```

- [x] **Task 3.2**: Improve error messages
  - exclusiveAccessViolation: Include helpful message about using --driver local
  - unsupportedDriver: List supported drivers ("local", "block")

### Phase 4: Testing & Validation ✅

- [x] **Task 4.1**: Test local driver (VirtioFS)
  - Create volume with default driver
  - Mount to multiple containers simultaneously
  - Verify data sharing works

- [x] **Task 4.2**: Test block driver (EXT4)
  - Create volume with --driver block
  - Mount to first container (should succeed)
  - Attempt mount to second container (should fail with clear error)
  - Remove first container, mount to second (should succeed)

- [x] **Task 4.3**: Test driver validation
  - Attempt unsupported driver (should fail)
  - Verify error messages are clear

- [x] **Task 4.4**: Test volume lifecycle
  - Create, inspect, remove for both drivers
  - Verify prune works for both drivers
  - Test volume persistence across daemon restart

## Implementation Details

### VolumeMetadata Structure

```swift
public struct VolumeMetadata: Codable, Sendable {
    public let name: String
    public let driver: String       // "local" or "block"
    public let format: String       // "ext4" for block, "dir" for local
    public let mountpoint: String   // directory (local) or file (block)
    public let createdAt: Date
    public let labels: [String: String]
    public let options: [String: String]?
}
```

### Mount Creation Logic

```swift
// In parseVolumeMounts()
if isNamedVolume {
    let volumeMetadata = try await volumeManager.inspectVolume(name: source)

    switch volumeMetadata.driver {
    case "local":
        // VirtioFS directory share
        mount = Containerization.Mount.share(
            source: volumeMetadata.mountpoint,  // Directory path
            destination: containerPath,
            options: options
        )

    case "block":
        // Exclusive block device
        try await volumeManager.acquireBlockVolume(
            name: source,
            containerID: dockerID
        )
        mount = Containerization.Mount.block(
            format: "ext4",
            source: volumeMetadata.mountpoint,  // volume.img path
            destination: containerPath,
            options: options
        )

    default:
        throw VolumeError.unsupportedDriver(volumeMetadata.driver)
    }
}
```

### Exclusive Access Tracking

**Acquire:**
```swift
public func acquireBlockVolume(name: String, containerID: String) async throws {
    guard let metadata = volumes[name] else {
        throw VolumeError.notFound(name)
    }

    guard metadata.driver == "block" else {
        return  // Only block volumes need exclusive access
    }

    // Check if already in use
    let users = try await stateStore.getVolumeUsers(volumeName: name)
    if !users.isEmpty && !users.contains(containerID) {
        throw VolumeError.exclusiveAccessViolation(
            volumeName: name,
            ownerContainer: users[0]
        )
    }
}
```

**Release:**
```swift
public func releaseBlockVolume(name: String, containerID: String) async {
    // Cleanup is automatic via StateStore.removeVolumeMount()
    // Called during container removal
}
```

## Benefits

### For Users

1. **Safe defaults**: Local driver works like Docker, shareable by default
2. **Performance choice**: Block driver for demanding workloads
3. **Clear errors**: Helpful messages guide users to correct solution
4. **Future-proof**: Easy to add more drivers (vsock-block, tmpfs, etc.)

### For Development

1. **Clean separation**: Driver logic isolated in VolumeManager
2. **Backward compatible**: Existing volumes work as-is (driver defaults to "local")
3. **Extensible**: New drivers just add case to switch statement
4. **Well-tested**: Each driver has dedicated test cases

## Migration Path

**Existing volumes** (created before this change):
- Database has `driver="local"` (existing validation ensures this)
- Will continue using block device (EXT4) if that's what's on disk
- **Decision needed**: Should we migrate existing volumes to VirtioFS directories?
  - Option A: Keep as-is (backward compatible, but exclusive access)
  - Option B: Migrate on first use (more work, but consistent behavior)

**Recommendation**: Option A - Keep existing volumes as-is for now. Users can recreate if they want shareable volumes.

## Future Extensions

### Additional Drivers

**vsock-block** - Network block device over vsock
- Requires control plane VM
- Shareable via NBD server
- Highest performance for shared access

**tmpfs** - In-memory volumes
- No persistence
- Maximum speed
- Perfect for temporary build artifacts

**host** - Raw host directory
- Bypass VirtioFS translation
- Direct host filesystem access
- Security implications

## Timeline

- **Phase 1**: VolumeManager changes - 30 minutes ✅
- **Phase 2**: ContainerManager integration - 20 minutes ✅
- **Phase 3**: Error handling - 10 minutes ✅
- **Phase 4**: Testing - 30 minutes ✅
- **Total**: ~1.5 hours ✅

## Success Criteria

- [x] Users can create volumes with `--driver local` (default)
- [x] Users can create volumes with `--driver block`
- [x] Local volumes are shareable across multiple containers
- [x] Block volumes enforce exclusive access with clear errors
- [x] Volume inspect shows driver type
- [x] All existing volume operations work with both drivers
- [x] Error messages guide users to correct solution
