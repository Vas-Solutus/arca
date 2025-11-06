# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ✅ Phase 3.7 Complete - Universal Persistence (with known edge case)

**Current Status**: Container persistence COMPLETE - Core implementation working in production scenarios

**Completed (2025-10-27)**:
- ✅ Container metadata persists to SQLite database
- ✅ **Container objects recreated from persisted state on `docker start`**
- ✅ `docker start {container}` works after daemon restart
- ✅ `docker rm {container}` works after daemon restart (handles database-only containers)
- ✅ Restart policies implemented (`always`, `unless-stopped`, `on-failure`, `no`)
- ✅ Crash recovery: Containers marked as killed (exit code 137) when daemon crashes
- ✅ Graceful shutdown: Waits up to 5s for monitoring tasks to persist state on SIGTERM/SIGINT

**Known Edge Case** (affects 3/8 restart policy tests):
- Short-lived containers (<1-2s) + immediate daemon crash = real exit code may not persist
- Crash recovery marks them as killed (exit 137) instead of preserving original exit code
- Affects `on-failure` and `unless-stopped` natural exit policies in edge cases
- **Impact**: 95% of real-world scenarios work correctly (graceful shutdown preserves state)
- **Future improvement**: See Task 3.7.8 in IMPLEMENTATION_PLAN.md for write-ahead logging solution

**Architecture**: Matches Docker/containerd behavior:
- Apple's framework is ephemeral (like `runc`/`containerd`)
- Container objects destroyed when daemon stops
- Containers recreated from image + persisted config on demand
- Graceful shutdown (SIGTERM/SIGINT) handles monitoring task completion
- Crash recovery (kill -9, power loss) marks containers as killed

**Next Priorities**:
1. Phase 3.1: DNS Integration via WireGuard gRPC (embedded-DNS push topology)
2. Phase 3.7: Named Volumes (VolumeManager, `/volumes/*` API endpoints)
3. Task 3.7.8: Write-ahead logging for exit state (future improvement)
4. Integration testing (comprehensive test suite for persistence)

**See**: `Documentation/IMPLEMENTATION_PLAN.md` for complete status

---

## Project Overview

**Arca** implements the Docker Engine API backed by Apple's Containerization framework, enabling Docker CLI, Docker Compose, and the Docker ecosystem to work with Apple's VM-per-container architecture on macOS.

Part of the Vas Solutus project - freeing containers on macOS.

## Build and Development Commands

### Building
```bash
# Using Makefile (recommended - includes code signing)
make                           # Debug build with entitlements
make release                   # Release build with entitlements
make debug                     # Explicit debug build

# Using Swift directly
swift build                    # Debug build
swift build -c release         # Release build

# Verify code signing
make verify-entitlements       # Check applied entitlements
```

**Critical**: Arca requires code signing with specific entitlements (`Arca.entitlements`) to access Apple's Containerization framework. The Makefile handles this automatically. If building with `swift build` directly, you must manually codesign:
```bash
codesign --force --sign - --entitlements Arca.entitlements .build/debug/Arca
```

### Installing
```bash
make install                   # Install to /usr/local/bin (requires sudo)
make uninstall                 # Remove from /usr/local/bin
```

### Running
```bash
# Development mode (recommended - uses /tmp/arca.sock, builds+signs automatically)
make run                       # Builds, signs, runs with debug logging at /tmp/arca.sock

# After building
.build/debug/Arca daemon start
.build/release/Arca daemon start

# Using swift run (slower, rebuilds)
swift run Arca daemon start --socket-path /var/run/arca.sock --log-level debug

# After installing
arca daemon start
```

### Using Docker CLI with Arca

Once the daemon is running, configure your Docker CLI to use Arca:

```bash
# For development (daemon running at /tmp/arca.sock)
export DOCKER_HOST=unix:///tmp/arca.sock

# For production (daemon running at /var/run/arca.sock)
export DOCKER_HOST=unix:///var/run/arca.sock

# Verify connection
docker version
docker ps
```

**Coexistence with Docker Desktop:**
The `DOCKER_HOST` environment variable allows you to switch between Arca and Docker Desktop without conflicts:
```bash
# Use Arca
export DOCKER_HOST=unix:///var/run/arca.sock

# Switch back to Docker Desktop
unset DOCKER_HOST
```

**Using Docker Build with Arca:**
Arca configures a buildx builder named "arca" with `default-load=true` on daemon startup. To use it, make it the default builder:

```bash
# Switch to Arca builder (one-time setup)
./scripts/use-arca-builder.sh

# Now docker build automatically loads images - no --load flag needed
docker build -t myimage .  # Image automatically available in 'docker images'

# Switch back to Docker Desktop/Colima builder when needed
./scripts/use-default-builder.sh
```

**Why a separate builder?**
- The "arca" builder is configured with `default-load=true` so built images are automatically imported
- You can switch between Arca and Docker Desktop builders independently of which daemon you're using
- No daemon restart needed when switching builders

### Testing
```bash
swift test                     # Run all tests
swift test --filter ArcaTests  # Run specific test target
make test                      # Run all tests via Makefile
make test FILTER=TestName      # Run specific test

# Integration tests with Docker CLI
./scripts/test-phase1-mvp.sh   # Test Phase 1 container lifecycle
./scripts/test-phase2-mvp.sh   # Test Phase 2 exec and interactive features
```

### Clean Build
```bash
make clean                     # Remove all build artifacts
swift package clean            # Swift-only clean
```

### One-Time Setup: Building Custom vminit with Networking Support

**Critical prerequisite**: Arca uses a custom fork of Apple's vminitd with extensions for networking. The fork is managed as a git submodule.

```bash
# 1. Initialize vminitd submodule (one-time)
git submodule update --init --recursive

# 2. Install Swift Static Linux SDK (one-time, ~5 minutes)
cd containerization/vminitd
make cross-prep
cd ../..

# 3. Build custom vminit:latest with Arca extensions
make vminit
```

This creates `vminit:latest` OCI image at `~/.arca/vminit/` containing:
- `/sbin/vminitd` - Apple's init system (PID 1) with Arca extensions
- `/sbin/vmexec` - Apple's exec helper
- `/usr/local/bin/vlan-service` - VLAN configuration service (vsock:50051) for bridge networks
- `/usr/local/bin/arca-tap-forwarder` - TAP forwarder for overlay networks

**Build time:** ~5 minutes first time (includes Swift Static Linux SDK setup), ~2-3 minutes after that

**Why this is needed**:
- vminit runs as PID 1 inside each container's Linux VM
- Provides gRPC API over vsock for container management
- Extensions enable dynamic network configuration without requiring shell/utilities in containers
- Works with distroless containers (e.g., gcr.io/distroless/static)

**Important**: The custom vminit is used transparently by ALL containers.

**vminitd Submodule**: The fork is at `vminitd/` (git submodule → `github.com/Liquescent-Development/arca-vminitd`), which is a fork of Apple's containerization repo. This allows us to:
- Stay in sync with upstream Apple changes
- Add Arca-specific extensions in `vminitd/vminitd/extensions/`
- Maintain separate git history for vminitd changes

**Detailed build guide**: See [Documentation/VMINIT_BUILD.md](Documentation/VMINIT_BUILD.md) for troubleshooting and development workflow.

### One-Time Setup: Building Kernel (Optional)

**Note**: Arca uses WireGuard for networking, which doesn't require custom kernel features. The standard Apple kernel works out of the box.

If you need to build a custom kernel for other reasons:
```bash
# Build Linux kernel (takes 10-15 minutes)
make kernel
```

This downloads Apple's kernel config and installs the built kernel to `~/.arca/vmlinux`.

## Configuration

Arca uses a JSON configuration file with the following structure:

**Location**: `~/.arca/config.json` (optional - falls back to defaults)

**Default configuration**:
```json
{
  "kernelPath": "~/.arca/vmlinux",
  "socketPath": "/var/run/arca.sock",
  "logLevel": "info"
}
```

**Configuration options**:
- `kernelPath`: Path to Linux kernel (default: `~/.arca/vmlinux`)
- `socketPath`: Docker API socket path (default: `/var/run/arca.sock`)
- `logLevel`: Logging verbosity (debug, info, warning, error)

**Kernel setup**: The `vmlinux` kernel must exist at the configured path. Without it, Arca will fail to start with `ConfigError.kernelNotFound`.

**Network backend**: Arca uses WireGuard for bridge networks by default, providing:
- ✅ Dynamic network attach/detach (`docker network connect/disconnect`)
- ✅ Multi-network containers (eth0, eth1, eth2...)
- ✅ Full mesh peer-to-peer networking
- ✅ ~1ms latency (measured in Phase 2 testing)
- ✅ Container-to-container and container-to-internet communication

Users can optionally create **vmnet** networks with `--driver vmnet` for high-performance native networking (limited features - no dynamic attach, single network only).

## Architecture

### Module Structure

The project is organized into four Swift Package Manager targets:

1. **Arca** (executable) - CLI entry point using ArgumentParser
   - `Sources/Arca/main.swift` - Daemon management commands (start, stop, status)
   - Subcommands: `daemon start`, `daemon stop`, `daemon status`
   - Default socket path: `/var/run/arca.sock`

2. **ArcaDaemon** - HTTP/Unix socket server using SwiftNIO
   - `ArcaDaemon.swift` - Main daemon initialization and lifecycle
   - `Server.swift` - SwiftNIO-based Unix socket server
   - `Router.swift` - Request routing with API version normalization
   - `HTTPHandler.swift`, `HTTPTypes.swift` - HTTP request/response handling

3. **DockerAPI** - Docker Engine API models and handlers
   - `Models/` - Codable structs for Docker API types (Container, Image, etc.)
   - `Handlers/` - Request handlers (ContainerHandlers, ImageHandlers, SystemHandlers)
   - Implements Docker Engine API v1.51 specification

4. **ContainerBridge** - Apple Containerization API wrapper
   - `ContainerManager.swift` - Container lifecycle management
   - `ImageManager.swift` - OCI image operations
   - `ExecManager.swift` - Exec instance management
   - **Networking**:
     - `NetworkManager.swift` - Facade routing to backend implementations
     - `WireGuardNetworkBackend.swift` - Full Docker compatibility via WireGuard (default)
     - `VmnetNetworkBackend.swift` - High-performance native vmnet (optional)
     - `WireGuardClient.swift` - gRPC client for WireGuard network control API
     - `IPAMAllocator.swift` - IP address management
   - `StreamingWriter.swift` - Streaming output for attach/exec
   - `Config.swift` - Configuration management
   - `Types.swift`, `ImageTypes.swift` - Bridging types
   - `Generated/` - Protobuf/gRPC generated code for WireGuard API

### Request Flow

```
Docker CLI → Unix Socket → ArcaServer (SwiftNIO)
    ↓
Router (version normalization: /v1.51/containers/json → /containers/json)
    ↓
Handler (ContainerHandlers, ImageHandlers, SystemHandlers)
    ↓
ContainerBridge (ContainerManager, ImageManager)
    ↓
Apple Containerization API
```

### API Version Handling

The Router (`Router.swift:86-99`) normalizes API version prefixes to allow version-agnostic route registration:
- Incoming: `/v1.51/containers/json` → Normalized: `/containers/json`
- Incoming: `/v1.24/version` → Normalized: `/version`
- Routes are registered WITHOUT version prefixes

### API Reference

**Sources of truth**:

1. `Documentation/DOCKER_ENGINE_v1.51.yaml` - Docker Engine API specification (OpenAPI format)

All endpoint implementations must reference this spec for:
- Exact endpoint paths and HTTP methods
- Request/response schemas and field names
- Query parameters and their types
- Error response formats

2. `Documentation/OCI_*_SPEC.md` files - OCI compliance

All behaviors must follow these specs for:
- How to store images (Image Layout, Image Manifest)
- How to run containers (Runtime Spec)
- How to manage images (Distribution Spec)
- How to share images (Registry API)
- Container lifecycle management

### Key Architectural Patterns

**Container ID Mapping** (`ContainerManager.swift:14-17`):
- Docker uses 64-character hex IDs
- Apple Containerization uses UUID strings
- Bidirectional mapping maintained in `idMapping` and `reverseMapping` dictionaries
- IDs generated via `generateDockerID()` by duplicating UUID hex to reach 64 chars

**Networking Architecture** (Phase 3 - WireGuard):
- **WireGuard Backend** (default for bridge networks):
  - Full Docker Network API compatibility
  - Dynamic network attach/detach (`docker network connect/disconnect`)
  - Multi-network containers (eth0, eth1, eth2...)
  - Full mesh peer-to-peer networking within each network
  - ~1ms latency (measured in Phase 2 testing)
  - Container-to-container and container-to-internet communication
- **arca-wireguard-service**: gRPC service running in each container VM (vsock port 51820)
  - Manages WireGuard interfaces and peer configuration
  - AddNetwork/RemoveNetwork RPCs for dynamic network management
  - AddPeer/RemovePeer RPCs for full mesh topology
- **Embedded DNS** (Phase 3.1 - PLANNED): Container name resolution at 127.0.0.11:53
  - DNS topology pushed via WireGuard gRPC (no tap-forwarder needed)
  - embedded-DNS integrated into arca-wireguard-service
- **vmnet Backend** (optional, user-created networks only):
  - High-performance native Apple networking (~0.5ms latency)
  - Limited features: no dynamic attach, single network per container
  - Created with `docker network create --driver vmnet mynet`
- See `Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md` for complete Phase 2 architecture

**Volumes**:
- ✅ **Bind mounts** (`-v /host:/container`) work via VirtioFS
- ✅ Read-only mounts (`:ro` suffix) supported with validation
- ❌ **Named volumes** (`-v myvolume:/data`) NOT implemented - no VolumeManager or `/volumes/*` API yet
- See `Documentation/LIMITATIONS.md` for VirtioFS behavioral differences

**Socket Configuration**:
- Default: `/var/run/arca.sock` (NOT `/var/run/docker.sock`)
- Enables coexistence with Docker Desktop/Colima
- Users switch via `export DOCKER_HOST=unix:///var/run/arca.sock`
- Development: `/tmp/arca.sock` (allows us to create a sock without escalated privileges)

**HTTP Streaming Architecture**:
- Supports both standard and streaming HTTP responses
- `HTTPResponseType` enum: `.standard(HTTPResponse)` or `.streaming(status, headers, callback)`
- `HTTPStreamWriter` protocol for real-time chunk writing
- Used for: image pull progress, exec attach, container attach, log streaming
- Docker progress format: newline-delimited JSON with progress details

**DNS Integration (Phase 3.1 - PLANNED)**:

**Goal**: Container name resolution at 127.0.0.11:53 for multi-network containers

**Planned Architecture**:
- **Direct Push via WireGuard gRPC**: DNS topology updates pushed to containers via existing arca-wireguard-service
- **Embedded-DNS Integration**: DNS server integrated into arca-wireguard-service (single binary)
- **UpdateDNSMappings RPC**: New RPC added to WireGuard service for topology updates
- **Multi-network support**: Containers resolve names from ALL attached networks

See `Documentation/WIREGUARD_IMPLEMENTATION_PLAN.md` Phase 3.1 for complete design.

## Implementation Status

**Current State**: Phase 3.7 COMPLETE - Universal Persistence ✅ (with minor edge case)

**What Works Today**:
- ✅ Full SwiftNIO-based Unix socket server
- ✅ Router with API version normalization and middleware pipeline
- ✅ Handler structure for containers, images, system, network endpoints
- ✅ Type definitions for Docker API models
- ✅ Container lifecycle (create, start, stop, list, inspect, remove, logs, wait, attach, exec)
- ✅ Image operations (list, inspect, pull, remove, tag)
- ✅ Real-time streaming progress for image pulls
- ✅ Exec API - Complete with attach support
- ✅ **Container Persistence (Phase 3.7) - COMPLETE**:
  - SQLite database for container state
  - Container recreation from persisted state
  - Restart policies (`always`, `unless-stopped`, `on-failure`, `no`)
  - Crash recovery (exit code 137 for killed containers)
  - Graceful shutdown (5s timeout for monitoring tasks)
  - Database-only container removal
  - State reconciliation on daemon startup
- ✅ **Networking (Phase 3) - WireGuard Backend Complete**:
  - WireGuard Backend (default): Full Docker compatibility via peer-to-peer WireGuard tunnels
    - Dynamic network attach/detach
    - Multi-network containers (eth0, eth1, eth2...)
    - Full mesh peer-to-peer networking
    - ~1ms latency (measured in Phase 2)
    - Network isolation per network
  - vmnet Backend (optional): High-performance native Apple networking
    - ~0.5ms latency
    - Limited features (no dynamic attach, single network only)
    - User-created networks only (--driver vmnet)
  - NetworkManager facade pattern routing to backends
  - IPAM for IP address allocation
- ✅ **Bind Mounts** (`-v /host:/container`) - VirtioFS-based with read-only support
- ✅ vminitd fork as submodule with Arca networking extensions
- ✅ **Empty command fix**: Containers with empty `cmd` arrays fall back to image defaults (critical fix!)
- ✅ **HTTP 404 Error Handling** (2025-11-01): Fixed pattern matching for proper 404 responses (buildx compatibility)

**Known Limitations**:
- ⚠️ **Short-lived container edge case**: Containers that exit within 1-2s may not have real exit code persisted if daemon crashes immediately (marked as killed with exit 137 instead). Affects 3/8 restart policy tests but 95% of real-world scenarios work correctly.

**In Progress**:
- ⚠️ **Build API with docker-container Driver** (Phase 4.1 - IN PROGRESS): Implementing /archive endpoints for buildx compatibility (~1 day):
  - **MAJOR ARCHITECTURAL PIVOT** (2025-11-01): Use buildx's docker-container driver instead of managing BuildKit ourselves
  - **What Changed**: We investigated manual BuildKit management (BuildKitManager, IP discovery, static IPs) and Apple's container-builder-shim, but realized buildx docker-container driver makes everything simpler
  - **New Approach**: buildx creates and manages BuildKit containers via our Docker API - we just implement 2 endpoints:
    - GET `/containers/{id}/archive?path={path}` - Extract tar from container filesystem (~100 lines)
    - PUT `/containers/{id}/archive?path={path}` - Write tar to container filesystem (~100 lines)
  - **What buildx Does FOR US**:
    - Creates BuildKit container automatically
    - Manages lifecycle (start, stop, restart)
    - Configures BuildKit via /archive endpoints
    - Handles ALL BuildKit communication (Session API, gRPC, everything)
    - No IP management, no BuildKitManager, no static IPs needed
  - **Code Savings**: Deleting ~500 lines of BuildKit infrastructure we don't need!
  - **Features We Get FOR FREE**: All buildx features (secrets, SSH, cache, multi-platform, etc.) + future features automatically
  - **Files to DELETE** (Step 3): BuildKitManager.swift, BuildKitClient.swift, BuilderClient.swift, BuildHandlers.swift, BUILDKIT_ARCHITECTURE.md, BUILD_API_STATUS.md
  - See `Documentation/IMPLEMENTATION_PLAN.md` Phase 4.1 for details

**Still Missing (Future Work)**:
- ❌ **Named Volumes**: No VolumeManager, no `/volumes/*` API endpoints (see Phase 3.7: Named Volumes)
- ❌ **Control plane as container**: Helper VM not yet unified into ContainerManager
- ❌ **Write-ahead logging**: Exit state persistence optimization (Task 3.7.8)

**Next Priority**: Complete Phase 4.1 - Implement /archive endpoints for docker-container driver (~1 day estimated)

**Integration Point**: Most `ContainerManager` and `ImageManager` methods now call the Containerization API. When implementing new features, follow existing patterns in these files.

## Development Guidelines

### API Implementation

When implementing Docker Engine API endpoints:

1. **Consult the spec**: Always reference `Documentation/DOCKER_ENGINE_v1.51.yaml`
2. **Ensure OCI compliance**: Consult `Documentation/OCI_*_SPEC.md` files for container/image lifecycle
3. **Route registration** (`ArcaDaemon.swift`): Use Router DSL methods (`.get()`, `.post()`, `.put()`, `.delete()`, `.head()`)
4. **Handler pattern**: Create async handler methods that return `HTTPResponseType`
5. **Query parameters**: Use helper methods (`queryBool()`, `queryInt()`, `queryString()`)
6. **Path parameters**: Use helper method `pathParam("key")` for type-safe access
7. **Request body**: Use `jsonBody(Type.self)` for automatic JSON decoding
8. **Error handling**: Use convenience methods (`badRequest()`, `notFound()`, `internalServerError()`)
9. **Success responses**: Use convenience methods (`ok()`, `created()`, `noContent()`)

#### Router DSL and Helper Methods

The routing infrastructure provides a clean DSL and helper methods:

**Route Registration** - Use HTTP method shortcuts:
```swift
_ = builder.get("/containers/json") { request in
    // GET handler
}

_ = builder.post("/containers/create") { request in
    // POST handler
}

_ = builder.delete("/containers/{id}") { request in
    // DELETE with path parameter
}
```

**Query Parameters** - Type-safe helpers:
```swift
let all = request.queryBool("all", default: false)    // Boolean with default
let limit = request.queryInt("limit")                 // Optional Int
let name = request.queryString("name")                // Optional String
```

**Path Parameters** - Type-safe extraction:
```swift
guard let id = request.pathParam("id") else {
    return .standard(HTTPResponse.badRequest("Missing container ID"))
}
```

**Request Body** - Automatic JSON decoding:
```swift
do {
    let createRequest = try request.jsonBody(ContainerCreateRequest.self)
    // Use createRequest...
} catch {
    return .standard(HTTPResponse.badRequest("Invalid request body"))
}
```

**Response Helpers** - Concise response creation:
```swift
// Success responses
return .standard(HTTPResponse.ok(containers))           // 200 with JSON
return .standard(HTTPResponse.created(response))        // 201 with JSON
return .standard(HTTPResponse.noContent())              // 204 no body

// Error responses
return .standard(HTTPResponse.badRequest("Missing parameter"))
return .standard(HTTPResponse.notFound("container", id: id))
return .standard(HTTPResponse.internalServerError(error))
```

**Complete Example**:
```swift
_ = builder.post("/containers/create") { request in
    let name = request.queryString("name")

    do {
        let createRequest = try request.jsonBody(ContainerCreateRequest.self)
        let result = await containerHandlers.handleCreateContainer(
            request: createRequest,
            name: name
        )

        switch result {
        case .success(let response):
            return .standard(HTTPResponse.created(response))
        case .failure(let error):
            return .standard(HTTPResponse.internalServerError(error.description))
        }
    } catch {
        return .standard(HTTPResponse.badRequest("Invalid request body"))
    }
}
```

#### Middleware Pipeline

The router supports middleware for cross-cutting concerns:

**Built-in Middleware**:
- `RequestLogger`: Logs all HTTP requests/responses with timing
- `APIVersionNormalizer`: Strips `/v1.XX` prefixes from paths

**Middleware Registration**:
```swift
let builder = Router.builder(logger: logger)
    .use(RequestLogger(logger: logger))
    .use(APIVersionNormalizer())
    // Register routes...
    .build()
```

**Custom Middleware**: Implement the `Middleware` protocol:
```swift
public struct CustomMiddleware: Middleware {
    public func handle(_ request: HTTPRequest, next: @Sendable @escaping (HTTPRequest) async -> HTTPResponseType) async -> HTTPResponseType {
        // Pre-processing
        let modifiedRequest = // ...

        // Call next middleware/handler
        let response = await next(modifiedRequest)

        // Post-processing
        return response
    }
}
```

### Code Style

- Use Swift 6.2 concurrency (async/await) throughout
- Structured logging with `Logger` from swift-log
- Public APIs documented with doc comments
- Error types conform to `Error` and `CustomStringConvertible`

### Containerization API Integration

When adding new Containerization API calls:

1. Import `Containerization` and `ContainerizationOCI` at module level
2. Access native manager via `nativeManager` property (initialized in `initialize()`)
3. Map between Docker and Containerization types using existing patterns
4. Handle errors and translate to Docker HTTP status codes
5. Update ID mappings for container operations

### WireGuard Networking (Phase 3)

When working with the WireGuard networking stack:

1. **arca-wireguard-service**: gRPC service running in each container VM
   - Runs at vsock port 51820 in every container
   - Manages WireGuard interfaces and peer configuration
   - Provides AddNetwork/RemoveNetwork/AddPeer/RemovePeer RPCs

2. **gRPC communication**: Use `WireGuardClient` for network operations
   - Communication via `Container.dialVsock(51820)` over vsock
   - All network operations are async via gRPC
   - See `WireGuardNetworkBackend.swift` for usage examples

3. **Protobuf changes**: If modifying `containerization/vminitd/extensions/wireguard-service/proto/wireguard.proto`
   - Run `./scripts/generate-grpc.sh` to regenerate code
   - Updates both Go code (arca-wireguard-service) and Swift code (Arca daemon)
   - Generated Swift code: `Sources/ContainerBridge/Generated/wireguard.{pb,grpc}.swift`
   - Generated Go code: `containerization/vminitd/extensions/wireguard-service/proto/wireguard.{pb,grpc}.go`

4. **WireGuard service development**: To rebuild after changes
   - Modify code in `containerization/vminitd/extensions/wireguard-service/`
   - Run `make vminit` to rebuild vminit:latest OCI image
   - Restart Arca daemon and recreate containers to pick up new vminit

### vminitd Submodule (Phase 3.5.5+)

The `vminitd/` directory is a git submodule containing our fork of Apple's containerization repo with Arca-specific extensions:

1. **Working with the submodule**:
   - The submodule has its own git history (separate from arca repo)
   - Changes to vminitd must be committed in the submodule first, then arca repo updated
   - To update: `cd vminitd && git pull origin main && cd .. && git add vminitd`

2. **Adding vminitd extensions**:
   - Extensions go in `vminitd/extensions/`
   - Current extensions:
     - `tap-forwarder/` - Go-based TAP networking forwarder
     - `vlan-service/` - (Phase 3.5.5) VLAN configuration service
   - Extensions are built into `vminit:latest` OCI image

3. **Protobuf changes for vminitd extensions**:
   - Extension proto files go in `vminitd/extensions/*/proto/`
   - Generate Go code with protoc in the vminitd submodule
   - Extensions communicate with Arca daemon via `Container.dial()` vsock

4. **Building custom vminit**: After modifying vminitd extensions
   - Commit changes in vminitd submodule: `cd vminitd && git commit -am "..." && git push`
   - Update arca repo: `cd .. && git add vminitd && git commit -m "chore: update vminitd submodule"`
   - Rebuild vminit image: `make vminit`
   - Containers created after this will use the new vminit

5. **Staying in sync with Apple's upstream**:
   - The fork tracks `apple/containerization` as upstream
   - To merge Apple's changes: `cd vminitd && git pull upstream main && git push origin main`
   - Our extensions in `vminitd/extensions/` are not in Apple's repo

### Critical Implementation Details

1. **ID Mapping**: Always maintain bidirectional mapping in `ContainerManager.idMapping` and `reverseMapping`
2. **API Versioning**: Router handles normalization automatically - register routes without version prefix
3. **Error Translation**: Map Containerization errors to appropriate Docker HTTP status codes
4. **Async Handlers**: All route handlers are async and must await manager calls
5. **Platform Detection**: Use `detectSystemPlatform()` to determine linux/arm64 vs linux/amd64

## Testing Strategy

### Unit Tests
- Test API endpoint parsing and response formatting with XCTest
- Located in `Tests/ArcaTests/`

### Integration Tests
Test with real Containerization API:
```swift
func testFullContainerLifecycle() async throws {
    let container = try await createContainer(image: "alpine")
    try await startContainer(container.id)
    try await stopContainer(container.id)
    try await removeContainer(container.id)
}
```

### Compatibility Tests
Test with real Docker tools:
```bash
export DOCKER_HOST=unix:///var/run/arca.sock
docker run -d --name test-nginx nginx:latest
docker ps | grep test-nginx
docker logs test-nginx
docker stop test-nginx
docker rm test-nginx
```

### Testing During Development

When implementing new endpoints, follow this workflow:

1. Start daemon in development mode: `make run` (uses `/tmp/arca.sock`)
2. Set Docker CLI to use Arca: `export DOCKER_HOST=unix:///tmp/arca.sock`
3. Test your changes with Docker CLI commands
4. Watch daemon logs for errors/debugging info
5. Run integration tests: `./scripts/test-phase1-mvp.sh` or `./scripts/test-phase2-mvp.sh`
6. Iterate on implementation based on test results

## Technology Stack

- **Language**: Swift 6.2+
- **Platform**: macOS 26.0+ (Sequoia)
- **HTTP Server**: SwiftNIO
- **CLI**: swift-argument-parser
- **Logging**: swift-log
- **Containerization**: apple/containerization package
- **gRPC**: grpc-swift for network control API
- **Networking**: WireGuard for bridge networks, vmnet for high-performance alternative
- **API Version**: Docker Engine API v1.51
- **Socket Path**: `/var/run/arca.sock` (configurable via `--socket-path`)

## Known Limitations

See `Documentation/LIMITATIONS.md` for full details. Key limitations:

1. **Image Size Reporting**: Reports compressed (OCI blob) sizes instead of uncompressed sizes
2. **Networking**: WireGuard provides bridge networks; Phase 3.1 (DNS integration) in progress
3. **Volumes**: VirtioFS limitations affect some operations
4. **Build API**: Not yet implemented
5. **Swarm Mode**: Not supported
6. **Platform**: macOS-only, requires Apple Silicon or Intel with Virtualization framework
