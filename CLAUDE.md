# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

**Critical prerequisite**: Arca requires a custom `vminit:latest` init system image with networking support before containers can use Arca's networking features.

```bash
# Install Swift Static Linux SDK (one-time, ~5 minutes)
cd .build/checkouts/containerization/vminitd
make cross-prep
cd /Users/kiener/code/arca

# Build arca-tap-forwarder (cross-compiled to Linux)
make tap-forwarder

# Build custom vminit:latest with arca-tap-forwarder included
make vminit
```

This creates `vminit:latest` OCI image containing:
- `/sbin/vminitd` - Apple's init system (PID 1)
- `/sbin/vmexec` - Apple's exec helper
- `/sbin/arca-tap-forwarder` - Arca's TAP networking forwarder (Phase 3.4+)

**Why this is needed**:
- vminit runs as PID 1 inside each container's Linux VM
- Provides gRPC API over vsock for container management
- arca-tap-forwarder enables container networking via TAP-over-vsock
- All components must be cross-compiled to Linux using Swift Static Linux SDK

**Important**: The custom vminit is used transparently by ALL containers. The TAP forwarder runs in the init system, not in user container space.

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
  "logLevel": "info"
}
```

**Kernel setup**: The `vmlinux` kernel must exist at the configured path. Without it, Arca will fail to start with `ConfigError.kernelNotFound`.

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
   - `ExecManager.swift` - Exec instance management (Phase 2)
   - `NetworkHelperVM.swift` - Helper VM lifecycle for OVN/OVS networking (Phase 3)
   - `OVNClient.swift` - gRPC client for network control API (Phase 3)
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

**Networking Translation**:
- Docker: bridge networks with virtual interfaces
- Apple: DNS-based networking
- Translation: containers on "my-network" become `container-name.my-network.container.internal`
- See `Documentation/LIMITATIONS.md` for details

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

**Networking Architecture (Phase 3)**:
- Helper VM runs OVN/OVS for bridge network emulation
- Managed as a Container via Apple Containerization framework
- gRPC control API over vsock using `Container.dial()`
- Each Docker network = separate OVS bridge in helper VM
- Container VMs attach to bridges via virtio-net (VZFileHandleNetworkDeviceAttachment)
- See `Documentation/NETWORK_ARCHITECTURE.md` for complete design

## Implementation Status

**Current State**: Phase 3 In Progress - OVN/OVS Helper VM networking

The codebase contains:
- ✅ Full SwiftNIO-based Unix socket server
- ✅ Router with API version normalization
- ✅ Handler structure for containers, images, system endpoints
- ✅ Type definitions for Docker API models
- ✅ Basic container lifecycle (create, start, stop, list, inspect, remove, logs, wait)
- ✅ Image operations (list, inspect, pull, remove, tag)
- ✅ Real-time streaming progress for image pulls
- ✅ Exec API (Phase 2) - Complete with attach support
- 🚧 Helper VM networking (Phase 3.1) - NetworkHelperVM, OVNClient, and gRPC API implemented
- 🚧 Network and Volume APIs (Phase 3)
- 🚧 Build API (Phase 4)

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
├── Dockerfile                  # Multi-stage build: OVS/OVN + Go control API
├── proto/
│   └── network.proto          # gRPC API definition (shared with Arca daemon)
├── control-api/               # Go gRPC server
│   ├── main.go                # Control API entry point
│   └── proto/                 # Generated Go code (from network.proto)
├── scripts/
│   ├── startup.sh             # VM entrypoint: starts OVS/OVN + control API
│   └── ovs-init.sh            # OVS/OVN initialization
└── config/
    └── dnsmasq.conf           # DHCP/DNS configuration for container networks
```

**Build output**: `~/.arca/helpervm/oci-layout/` - OCI image layout compatible with Containerization framework

## Known Limitations

See `Documentation/LIMITATIONS.md` for full details. Key limitations:

1. **Image Size Reporting**: Reports compressed (OCI blob) sizes instead of uncompressed sizes
2. **Networking**: Phase 3 (in progress) - OVN/OVS helper VM provides bridge networks
3. **Volumes**: VirtioFS limitations affect some operations
4. **Build API**: Not yet implemented
5. **Swarm Mode**: Not supported
6. **Platform**: macOS-only, requires Apple Silicon or Intel with Virtualization framework
