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

# Integration tests with Docker CLI
./scripts/test-phase1-mvp.sh   # Test Phase 1 container lifecycle
./scripts/test-phase2-mvp.sh   # Test Phase 2 exec and interactive features
```

### Clean Build
```bash
make clean                     # Remove all build artifacts
swift package clean            # Swift-only clean
```

### One-Time Setup: Building vminit

**Critical prerequisite**: Arca requires the `vminit:latest` init system image before ContainerManager can initialize containers. This is a one-time setup.

```bash
# Navigate to containerization package
cd .build/checkouts/containerization

# Install Swift Static Linux SDK (one-time, ~5 minutes)
make cross-prep

# Build vminitd binaries (cross-compiled to Linux)
make vminitd

# Package into vminit:latest OCI image
make init
```

This creates `vminit:latest` in `~/Library/Application Support/com.apple.containerization/`.

**Why this is needed**:
- vminit runs as PID 1 inside each container's Linux VM
- Provides gRPC API over vsock for container management
- Must be cross-compiled to Linux using Swift Static Linux SDK

**Future improvement**: This will be automated via `arca setup` command (see `Documentation/IMPLEMENTATION_PLAN.md` Phase 0.5).

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
   - `StreamingWriter.swift` - Streaming output for attach/exec
   - `Config.swift` - Configuration management
   - `Types.swift`, `ImageTypes.swift` - Bridging types

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

## Implementation Status

**Current State**: Phase 2 In Progress - Exec API implementation

The codebase contains:
- ✅ Full SwiftNIO-based Unix socket server
- ✅ Router with API version normalization
- ✅ Handler structure for containers, images, system endpoints
- ✅ Type definitions for Docker API models
- ✅ Basic container lifecycle (create, start, stop, list, inspect, remove, logs, wait)
- ✅ Image operations (list, inspect, pull, remove, tag)
- ✅ Real-time streaming progress for image pulls
- 🚧 Exec API (Phase 2) - ExecManager and models implemented
- 🚧 Networks and Volumes (Phase 3)
- 🚧 Build API (Phase 4)

**Integration Point**: Most `ContainerManager` and `ImageManager` methods now call the Containerization API. When implementing new features, follow existing patterns in these files.

## Development Guidelines

### API Implementation

When implementing Docker Engine API endpoints:

1. **Consult the spec**: Always reference `Documentation/DOCKER_ENGINE_v1.51.yaml`
2. **Ensure OCI compliance**: Consult `Documentation/OCI_*_SPEC.md` files for container/image lifecycle
3. **Route registration** (`ArcaDaemon.swift`): Register routes WITHOUT version prefix
4. **Handler pattern**: Create async handler methods that return `HTTPResponse`
5. **Query parameters**: Parse from `request.queryParameters` dictionary
6. **Path parameters**: Access from `request.pathParameters` (populated by Router)
7. **Error handling**: Return `HTTPResponse.error(message, status: .statusCode)`
8. **JSON responses**: Use `HTTPResponse.json(codableObject)`

Example handler registration:
```swift
router.register(method: .GET, pattern: "/containers/json") { request in
    let all = request.queryParameters["all"] == "true"
    let response = await containerHandlers.handleListContainers(all: all)
    return HTTPResponse.json(response.containers)
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
- **API Version**: Docker Engine API v1.51
- **Socket Path**: `/var/run/arca.sock` (configurable via `--socket-path`)

## Known Limitations

See `Documentation/LIMITATIONS.md` for full details. Key limitations:

1. **Image Size Reporting**: Reports compressed (OCI blob) sizes instead of uncompressed sizes
2. **Networking**: DNS-based networking instead of bridge networks
3. **Volumes**: VirtioFS limitations affect some operations
4. **Build API**: Not yet implemented
5. **Swarm Mode**: Not supported
6. **Platform**: macOS-only, requires Apple Silicon or Intel with Virtualization framework
