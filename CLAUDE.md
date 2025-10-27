# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🚨 CRITICAL: Phase 3.7 Blocker - Universal Persistence

**DO NOT IMPLEMENT ANY NEW FEATURES UNTIL PHASE 3.7 IS COMPLETE**

**Problem**: Arca currently has NO persistence. Daemon restart = total amnesia:
- All containers lost
- All networks lost
- Control plane deleted and recreated (OVN databases destroyed)
- Subnet allocation resets (causes collisions)

**Solution**: Phase 3.7 implements universal persistence with unified container management:
1. Container state files (`~/.arca/containers/{id}/config.json`)
2. Network state file (`~/.arca/networks.json`)
3. Control plane as regular container (not special-cased)
4. Restart policies (`--restart always/unless-stopped/on-failure`)
5. Volume mounts (VirtioFS)

**See**: `Documentation/IMPLEMENTATION_PLAN.md:1949-2305` for complete implementation plan

**Architecture Change**: Control plane (formerly "helper VM") is now a regular container managed by `ContainerManager` with:
- Label: `com.arca.internal=true` (hidden from docker ps)
- Restart policy: `always` (auto-starts on daemon startup)
- Volume: `~/.arca/control-plane/ovn-data` → `/etc/ovn` (OVN database persistence)

This eliminates ~500 lines of duplicate `NetworkHelperVM` lifecycle code.

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

### One-Time Setup: Building Kernel with TUN Support

**Critical prerequisite**: Arca's helper VM requires a Linux kernel with TUN/TAP support (`CONFIG_TUN=y`) for OVS userspace networking. Pre-built kernels may not have this enabled.

```bash
# Build custom kernel with TUN support (takes 10-15 minutes)
make kernel
```

This downloads Apple's kernel config, builds a kernel with TUN enabled, and installs it to `~/.arca/vmlinux`.

**Why this is needed**:
- OVS userspace datapath requires `/dev/net/tun` device
- Without TUN support, bridge creation fails with "No such device"
- See `Documentation/KERNEL_BUILD.md` for detailed information

**Verification**:
```bash
# After building kernel, rebuild helper VM and test
make helpervm
make test-helper
```

### Building Helper VM (Phase 3 - Networking)

**Context**: Phase 3 introduces a lightweight Linux VM running OVN/OVS for Docker-compatible networking. This helper VM provides bridge networks, network isolation, and full Docker Network API compatibility.

```bash
# Build the network helper VM OCI image
make helpervm                  # Builds arca-network-helper:latest

# Manual build (if needed)
./scripts/build-helper-vm.sh
```

This creates an OCI image at `~/.arca/helpervm/oci-layout/` containing:
- Open vSwitch (OVS) v3.6.0
- Open Virtual Network (OVN) v25.09
- gRPC control API server (Go)
- Alpine Linux base (~50-100MB)

**Architecture**: See `Documentation/NETWORK_ARCHITECTURE.md` for detailed networking design.

**Prerequisites**:
- Docker or Podman (for building the image)
- protoc compiler with protoc-gen-go and protoc-gen-go-grpc plugins

**gRPC code generation**: If you modify `helpervm/proto/network.proto`:
```bash
./scripts/generate-grpc.sh     # Regenerate Go and Swift gRPC code
```

## Configuration

Arca uses a JSON configuration file with the following structure:

**Location**: `~/.arca/config.json` (optional - falls back to defaults)

**Default configuration**:
```json
{
  "kernelPath": "~/.arca/vmlinux",
  "socketPath": "/var/run/arca.sock",
  "logLevel": "info",
  "networkBackend": "ovs"
}
```

**Configuration options**:
- `kernelPath`: Path to custom Linux kernel (required for helper VM)
- `socketPath`: Docker API socket path (default: `/var/run/arca.sock`)
- `logLevel`: Logging verbosity (debug, info, warning, error)
- `networkBackend`: Network backend to use (default: `ovs`)
  - **`ovs`** - Full Docker compatibility via OVS/OVN helper VM (default)
    - ✅ Dynamic network attach/detach (`docker network connect/disconnect`)
    - ✅ Multi-network containers (eth0, eth1, eth2...)
    - ✅ Port mapping (`-p` flag)
    - ✅ DNS resolution by container name
    - ✅ Network isolation
    - ⚠️ ~4-7ms latency (4 vsock hops + OVS switching)
  - **`vmnet`** - High-performance native Apple networking
    - ✅ ~0.5ms latency (10x faster than OVS)
    - ✅ Simple architecture (no helper VM)
    - ❌ Must specify `--network` at `docker run` time (no dynamic attach)
    - ❌ Single network per container only
    - ❌ No port mapping
    - ❌ No overlay networks

**Kernel setup**: The `vmlinux` kernel must exist at the configured path. Without it, Arca will fail to start with `ConfigError.kernelNotFound`.

**Network backend selection**: See `Documentation/NETWORK_ARCHITECTURE.md` for detailed comparison and migration guide between OVS and vmnet backends.

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
   - **Networking (Dual Backend)**:
     - `NetworkManager.swift` - Facade routing to backend implementations
     - `OVSNetworkBackend.swift` - Full Docker compatibility via OVS/OVN (default)
     - `VmnetNetworkBackend.swift` - High-performance native vmnet
     - `NetworkHelperVM.swift` - Helper VM lifecycle for OVS backend
     - `OVNClient.swift` - gRPC client for OVS network control API
     - `NetworkBridge.swift` - vsock packet relay for TAP-over-vsock
     - `IPAMAllocator.swift` - IP address management
   - `StreamingWriter.swift` - Streaming output for attach/exec
   - `Config.swift` - Configuration management
   - `Types.swift`, `ImageTypes.swift` - Bridging types
   - `Generated/` - Protobuf/gRPC generated code for network API

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

**Networking Architecture** (Phase 3 - OVS Backend):
- **Control Plane Container**: Lightweight Linux VM running OVN/OVS (named `arca-control-plane`)
- **Unified Management**: Control plane is a regular container with special labels:
  - `com.arca.internal=true` - Hidden from `docker ps` (unless showing internal containers)
  - `com.arca.role=control-plane` - Identifies role for internal use
  - `--restart always` - Auto-restarts on daemon startup and crashes
  - Volume mount for OVN data: `~/.arca/control-plane/ovn-data` → `/etc/ovn` (persistent across restarts)
- **TAP-over-vsock**: Container VMs connect to OVS bridges via virtio-vsock packet relay
- **MQTT Pub/Sub**: MQTT 5.0 broker in Arca daemon distributes network topology updates via vsock
- **Embedded DNS**: Each container runs embedded-DNS at 127.0.0.11:53 for multi-network name resolution
- **Security**: Control plane isolated via vsock (CID 2) - not accessible from container networks
- See `Documentation/NETWORK_ARCHITECTURE.md` and `Documentation/MQTT_PUBSUB_ARCHITECTURE.md` for complete design

**Unified Container Management** (Phase 3.7 - IN PROGRESS):
- **Everything is a container**: User containers AND control plane use the same lifecycle
- **No special cases**: Control plane managed via `ContainerManager` like any other container
- **Code reuse**: Persistence, restart policies, volumes work for all containers
- **Benefits**:
  - ~500 lines of `NetworkHelperVM` actor code deleted
  - Control plane gets restart policies for free
  - OVN databases persist via volume mount
  - Simpler mental model: "container with special label"

**Volumes**:
- Docker named volumes map to Apple container volume paths
- VirtioFS limitations require read-only mount workarounds
- See `Documentation/LIMITATIONS.md` for known issues

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

**Networking Architecture (Phase 3 - OVS + Direct Push DNS)**:

**Current State**: OVS backend with custom IPAM, dnsmasq for single-network DNS, and TAP-over-vsock for packet forwarding.

**Multi-Network DNS Challenge**:
- dnsmasq in helper VM only works for single-network containers
- Containers on multiple networks need to resolve names from ALL attached networks
- Cannot use TCP to query helper VM (security risk - exposes control plane to containers)
- vsock constraint: Only host can dial containers (containers cannot dial host or each other)

**Solution: Direct Push via tap-forwarder gRPC**:
- **Reuse existing infrastructure**: tap-forwarder gRPC server already runs on vsock port 5555 for TAP device management
- **Add one RPC**: UpdateDNSMappings extends existing tap-forwarder service
- **Embedded-DNS**: Runs in each container at 127.0.0.11:53 with local DNS mappings
- **Direct push**: Daemon dials containers via Container.dialVsock(5555) and pushes topology updates
- **Relay**: tap-forwarder forwards updates to embedded-DNS via Unix socket
- **Security**: vsock isolates control plane, only host→container communication allowed

**Key Components**:
1. **tap-forwarder**: Extended gRPC service with UpdateDNSMappings RPC (vsock port 5555)
2. **Embedded-DNS**: DNS server + control server on Unix socket + local in-memory mappings
3. **Topology Publisher**: ContainerManager pushes updates on lifecycle changes via TAPForwarderClient
4. **TAP-over-vsock**: Unchanged - handles packet forwarding for network traffic

**Data Flow**:
```
ContainerManager (detect topology change)
  → TAPForwarderClient.updateDNSMappings() (Swift gRPC)
  → Container.dialVsock(5555) (host→container)
  → tap-forwarder UpdateDNSMappings handler (Go gRPC)
  → Unix socket /tmp/arca-dns-control.sock (JSON)
  → embedded-DNS control server (Go)
  → Update local DNSMappings (atomic)
  → Resolve container names to IPs
```

**Benefits**:
- **Simple**: No broker needed, direct host→container push
- **Secure**: vsock isolates control plane from container networks
- **Reuses infrastructure**: tap-forwarder already exists and runs on vsock port 5555
- **Complete snapshots**: Full topology sent on each update (idempotent, no deltas)
- **Best-effort**: DNS updates don't block container operations

See `Documentation/DNS_PUSH_ARCHITECTURE.md` for complete design and `Documentation/NETWORK_ARCHITECTURE.md` for overall networking architecture.

## Implementation Status

**Current State**: Phase 3.7 IN PROGRESS - Universal Persistence (CRITICAL BLOCKER)

🚨 **BLOCKER**: Phase 3.7 must be completed before any other work. No persistence = not Docker-compatible.

**What Works Today**:
- ✅ Full SwiftNIO-based Unix socket server
- ✅ Router with API version normalization and middleware pipeline
- ✅ Handler structure for containers, images, system, network endpoints
- ✅ Type definitions for Docker API models
- ✅ Container lifecycle (create, start, stop, list, inspect, remove, logs, wait, attach, exec)
- ✅ Image operations (list, inspect, pull, remove, tag)
- ✅ Real-time streaming progress for image pulls
- ✅ Exec API - Complete with attach support
- ✅ **Networking (Phase 3) - Dual Backend Complete**:
  - OVS Backend (default): Full Docker compatibility via TAP-over-vsock + OVS helper VM
    - Dynamic network attach/detach
    - Multi-network containers
    - DNS resolution by container name
    - Network isolation
  - vmnet Backend (optional): High-performance native Apple networking
    - 10x lower latency than OVS
    - Limited features (no dynamic attach, single network only)
  - NetworkManager facade pattern routing to backends
  - Helper VM with OVS/OVN + dnsmasq
  - TAP-over-vsock packet relay
  - IPAM for IP address allocation
- ✅ Volume API - Basic volume operations
- ✅ vminitd fork as submodule with Arca networking extensions

**Critical Missing (Phase 3.7 - IN PROGRESS)**:
- ❌ **Container persistence**: All state lost on daemon restart
- ❌ **Network persistence**: Networks vanish on daemon restart
- ❌ **Restart policies**: No `--restart always/unless-stopped/on-failure`
- ❌ **Control plane persistence**: Helper VM deleted on every startup
- ❌ **Volume mounts**: No VirtioFS volume support yet

**Impact of Missing Persistence**:
- Daemon restart = total amnesia (containers, networks, everything gone)
- Cannot implement `docker run --restart always`
- Cannot survive daemon crashes
- Not Docker-compatible in any real sense

**Next Priority**: Complete Phase 3.7 (Universal Persistence) - see `Documentation/IMPLEMENTATION_PLAN.md:1949-2305`

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

### Helper VM and Networking (Phase 3)

When working with the helper VM networking stack:

1. **Helper VM lifecycle**: Managed by `NetworkHelperVM` class
   - Launches as a Container using the Containerization framework
   - Runs the `arca-network-helper:latest` OCI image
   - Starts OVS/OVN processes and gRPC control API server

2. **gRPC communication**: Use `OVNClient` for network operations
   - Communication via `Container.dial()` over vsock (port 9999 → TCP in VM)
   - Auto-connects when `NetworkHelperVM.ensureRunning()` succeeds
   - All network operations are async via gRPC

3. **Protobuf changes**: If modifying `helpervm/proto/network.proto`
   - Run `./scripts/generate-grpc.sh` to regenerate code
   - Updates both Go code (helper VM) and Swift code (Arca daemon)
   - Generated Swift code: `Sources/ContainerBridge/Generated/network.{pb,grpc}.swift`
   - Generated Go code: `helpervm/control-api/proto/network.{pb,grpc}.go`

4. **Helper VM development**: To rebuild after changes to helper VM code
   - Modify code in `helpervm/control-api/`, `helpervm/scripts/`, or `helpervm/config/`
   - Run `make helpervm` to rebuild OCI image
   - Restart Arca daemon to pick up new image

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
- **Networking**: Open vSwitch (OVS) v3.6.0 + Open Virtual Network (OVN) v25.09
- **Helper VM**: Alpine Linux 3.22 with Go control API server
- **API Version**: Docker Engine API v1.51
- **Socket Path**: `/var/run/arca.sock` (configurable via `--socket-path`)

## Helper VM Directory Structure (Phase 3)

The `helpervm/` directory contains everything needed for the networking helper VM:

```
helpervm/
├── Dockerfile                  # Multi-stage build: OVS/OVN + Router + Go control API
├── proto/
│   ├── network.proto          # gRPC API definition for OVS (overlay networks)
│   └── router.proto           # gRPC API definition for VLAN router (bridge networks)
├── control-api/               # Go gRPC server (OVS management)
│   ├── main.go                # Control API entry point
│   ├── server.go              # OVS bridge/port operations
│   ├── tap_relay.go           # TAP-over-vsock relay for overlay networks
│   └── proto/                 # Generated Go code
├── router-service/            # Go gRPC server (VLAN routing - Phase 3.5.5+)
│   ├── main.go                # Router service entry point
│   ├── router.go              # VLAN interface management via netlink
│   └── proto/                 # Generated Go code
├── scripts/
│   ├── startup.sh             # VM entrypoint: starts OVS/OVN + Router + APIs
│   ├── ovs-init.sh            # OVS/OVN initialization
│   └── router-init.sh         # Router initialization (iptables, IP forwarding)
└── config/
    └── dnsmasq.conf           # DHCP/DNS configuration for container networks
```

**Build output**: `~/.arca/helpervm/oci-layout/` - OCI image layout compatible with Containerization framework

**Dual Architecture**:
- **Bridge networks**: Use router-service with VLAN tagging (simple, fast)
- **Overlay networks**: Use control-api with OVS/OVN (complex, multi-host capable)

## Known Limitations

See `Documentation/LIMITATIONS.md` for full details. Key limitations:

1. **Image Size Reporting**: Reports compressed (OCI blob) sizes instead of uncompressed sizes
2. **Networking**: Phase 3 (in progress) - OVN/OVS helper VM provides bridge networks
3. **Volumes**: VirtioFS limitations affect some operations
4. **Build API**: Not yet implemented
5. **Swarm Mode**: Not supported
6. **Platform**: macOS-only, requires Apple Silicon or Intel with Virtualization framework
