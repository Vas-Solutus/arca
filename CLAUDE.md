# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Arca** implements the Docker Engine API backed by Apple's Containerization framework, enabling Docker CLI, Docker Compose, and the Docker ecosystem to work with Apple's VM-per-container architecture on macOS.

Part of the Vas Solutus project - freeing containers on macOS.

## Build and Development Commands

### Building
```bash
swift build
```

### Running
```bash
swift run Arca
```

### Testing
```bash
swift test
```

### Clean Build
```bash
swift package clean
```

## Architecture

### Core Architecture
The project translates Docker Engine API calls to Apple's Containerization Swift API. This enables:
- Docker CLI compatibility with Apple containers
- Docker Compose support (with networking/volume limitations)
- Native Apple Silicon performance
- OCI-compliant image support

### API Reference
The **source of truth** for all API implementations is `Documentation/DockerEngineAPIv1.51.yaml`. All endpoint implementations, request/response models, and behaviors must reference this OpenAPI specification for:
- Exact endpoint paths and HTTP methods
- Request/response schemas and field names
- Query parameters and their types
- Error response formats
- API versioning behavior

### Planned Directory Structure
```
Sources/
├── ContainerEngineDaemon/      # Main daemon process
│   ├── main.swift               # Entry point
│   ├── APIServer.swift          # HTTP/Unix socket server
│   └── Router.swift             # Route definitions
├── DockerAPI/                   # API models & handlers
│   ├── Models/                  # Request/Response types
│   │   ├── Container.swift
│   │   ├── Image.swift
│   │   ├── Network.swift
│   │   └── Volume.swift
│   └── Handlers/                # Endpoint implementations
│       ├── ContainerHandlers.swift
│       ├── ImageHandlers.swift
│       ├── NetworkHandlers.swift
│       └── SystemHandlers.swift
├── ContainerBridge/             # Containerization API wrapper
│   ├── ContainerManager.swift
│   ├── ImageManager.swift
│   └── NetworkManager.swift
└── Utilities/
    ├── Logger.swift
    ├── Config.swift
    └── APIVersioning.swift
```

### Key Architectural Mappings

**Container IDs:**
- Docker uses 64-character hex IDs
- Apple Containerization uses UUIDs
- Bidirectional mapping required between formats

**Networking:**
- Docker uses bridge networks with virtual interfaces
- Apple uses DNS-based networking
- Translation: containers on "my-network" become `container-name.my-network.container.internal`

**Volumes:**
- Docker named volumes map to Apple container volume paths
- VirtioFS limitations require read-only mount workarounds in some cases

### API Version Support
- Current implementation target: Docker Engine API v1.51
- Minimum supported version: v1.28
- API version appears in URL path: `/v1.51/containers/json`

## Implementation Phases

### Phase 1: MVP - Core Container Lifecycle
Priority endpoints:
- System: `GET /version`, `GET /info`, `GET /_ping`
- Containers: create, start, stop, list, inspect, remove, wait, logs
- Images: list, inspect, pull, remove

Target: Basic `docker run`, `docker ps`, `docker logs`, `docker stop` functionality

### Phase 2: Interactive & Execution
- Exec API: create exec, start exec, inspect exec
- Attach/Streams: attach to containers, streaming logs
- Target: `docker exec -it`, `docker attach` functionality

### Phase 3: Docker Compose Support
- Networks: CRUD operations, connect/disconnect
- Volumes: CRUD operations
- Target: `docker compose up/down` functionality

### Phase 4: Build & Advanced Features
- Build API: build images from Dockerfile
- Container operations: restart, pause, rename, stats, top
- System operations: events stream, prune commands

## Key Limitations

Arca differs from Docker in these areas:
- **Networking**: DNS-based instead of bridge networks
- **Volumes**: Some VirtioFS limitations affect volume operations
- See `Documentation/LIMITATIONS.md` for complete details

## Testing Strategy

### Unit Tests
Test API endpoint parsing and response formatting with XCTest

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
export DOCKER_HOST=unix:///var/run/container-engine.sock
docker run -d --name test-nginx nginx:latest
docker ps | grep test-nginx
docker logs test-nginx
docker stop test-nginx
docker rm test-nginx
```

## Technology Stack

- **Language**: Swift 6.2+
- **HTTP Server**: SwiftNIO or Vapor (to be implemented)
- **API Version**: Docker Engine API v1.51
- **Socket Path**: `/var/run/container-engine.sock` (with symlink option to `/var/run/docker.sock`)
- **Configuration**: JSON config file + command-line flags

## Development Guidelines

### API Implementation
When implementing API endpoints:
1. Always reference `Documentation/DockerEngineAPIv1.51.yaml` for the complete specification
2. Use Swift Codable structs with proper CodingKeys for JSON key mapping
3. Follow Swift naming conventions (camelCase) for internal code
4. Map Docker API responses correctly from Containerization API
5. Handle errors appropriately with proper HTTP status codes

### Code Style
- Use Swift 6.2 concurrency features (async/await)
- Structured logging with appropriate levels
- Clear error messages that help users understand Containerization vs Docker differences

### Critical Implementation Requirements
1. **ID Mapping**: Maintain bidirectional mapping between Docker hex IDs and Apple UUIDs
2. **Network Translation**: Document DNS-based networking limitations clearly
3. **Volume Handling**: Implement VirtioFS workarounds where necessary
4. **API Versioning**: Support version negotiation in URL paths
5. **Error Translation**: Map Containerization errors to appropriate Docker API errors
