# Implementation Plan: Docker Engine API for Apple Containerization

## Project Overview

**Core Goal**: Implement the Docker Engine API (Moby API) as a daemon that translates Docker API calls to Apple's Containerization Swift API, enabling the entire Docker ecosystem (CLI, Compose, plugins) to work with Apple Containers.

## API Specification

**Source of Truth**: The complete Docker Engine API v1.51 specification is located at
`Documentation/DockerEngineAPIv1.51.yaml`. All endpoint implementations, request/response
models, and behaviors should reference this OpenAPI specification.

This plan provides a roadmap for implementation priority, but the OpenAPI spec is the
definitive reference for:
- Exact endpoint paths and HTTP methods
- Request/response schemas and field names
- Query parameters and their types
- Error response formats
- API versioning behavior

---

## Phase 0: Project Setup & Architecture

### Repository Structure

```
container-engine/
├── Sources/
│   ├── ContainerEngineDaemon/      # Main daemon process
│   │   ├── main.swift               # Entry point
│   │   ├── APIServer.swift          # HTTP/Unix socket server
│   │   └── Router.swift             # Route definitions
│   ├── DockerAPI/                   # API models & handlers
│   │   ├── Models/                  # Request/Response types
│   │   │   ├── Container.swift
│   │   │   ├── Image.swift
│   │   │   ├── Network.swift
│   │   │   └── Volume.swift
│   │   └── Handlers/                # Endpoint implementations
│   │       ├── ContainerHandlers.swift
│   │       ├── ImageHandlers.swift
│   │       ├── NetworkHandlers.swift
│   │       └── SystemHandlers.swift
│   ├── ContainerBridge/             # Containerization API wrapper
│   │   ├── ContainerManager.swift
│   │   ├── ImageManager.swift
│   │   └── NetworkManager.swift
│   └── Utilities/
│       ├── Logger.swift
│       ├── Config.swift
│       └── APIVersioning.swift
├── Tests/
│   ├── APITests/
│   ├── IntegrationTests/
│   └── CompatibilityTests/         # Test with real Docker tools
├── Documentation/
│   ├── API_COVERAGE.md             # Which endpoints are implemented
│   ├── LIMITATIONS.md              # Known incompatibilities
│   └── MIGRATION.md                # Moving from Docker Desktop
├── scripts/
│   ├── install.sh
│   ├── uninstall.sh
│   └── test-compatibility.sh       # Test with docker/compose
├── config/
│   └── daemon.json                 # Daemon configuration
├── Package.swift
└── README.md
```

### Key Technology Decisions

1. **HTTP Server**: Use SwiftNIO or Vapor for the HTTP/Unix socket server
2. **API Version**: Implement Docker Engine API v1.51 (using OpenAPI spec at Documentation/DockerEngineAPIv1.51.yaml)
4. **Socket Path**: `/var/run/container-engine.sock` (symlink option to `/var/run/docker.sock`)
5. **Logging**: Structured logging with levels
6. **Configuration**: JSON config file + command-line flags

---

## Phase 1: MVP - Core Container Lifecycle (Weeks 1-3)

### Goal: Run basic containers with Docker CLI

### API Endpoints to Implement

Reference the OpenAPI specification at `Documentation/DockerEngineAPIv1.51.yaml` for
complete endpoint details, schemas, and parameters.

#### System/Info (Foundation)
- `GET /version` - Return API version info
- `GET /info` - System information
- `GET /_ping` - Health check

#### Container Lifecycle (Priority)
- `POST /containers/create` - Create container (see spec for ContainerConfig schema)
- `POST /containers/{id}/start` - Start container
- `POST /containers/{id}/stop` - Stop container (with optional timeout)
- `GET /containers/json` - List containers (with filter support)
- `GET /containers/{id}/json` - Inspect container
- `DELETE /containers/{id}` - Remove container (with force/volumes options)
- `POST /containers/{id}/wait` - Wait for container to stop
- `GET /containers/{id}/logs` - Get container logs (with stdout/stderr/timestamps options)

#### Image Management (Essential)
- `GET /images/json` - List images (with filters)
- `GET /images/{name}/json` - Inspect image
- `POST /images/create` - Pull image from registry (with auth support)
- `DELETE /images/{name}` - Remove image (with force option)

**Implementation Note**: For each endpoint, consult the OpenAPI spec for:
- Complete request body schemas
- All query parameters and their types
- Response formats and status codes
- Error responses

### Success Criteria
```bash
# These should work:
docker ps
docker run -d nginx:latest
docker logs <container-id>
docker stop <container-id>
docker rm <container-id>
docker images
docker pull alpine:latest
docker rmi alpine:latest
```

---

## Phase 2: Interactive & Execution (Weeks 4-5)

### API Endpoints to Implement

#### Exec API
- `POST /containers/{id}/exec` - Create exec instance
- `POST /exec/{id}/start` - Start exec instance
- `GET /exec/{id}/json` - Inspect exec instance

#### Attach/Streams
- `POST /containers/{id}/attach` - Attach to container
- `GET /containers/{id}/logs` (enhancement) - Stream logs with websocket

### Success Criteria
```bash
# These should work:
docker run -it alpine sh
docker exec -it <container-id> sh
docker attach <container-id>
docker logs -f <container-id>
```

---

## Phase 3: Docker Compose Support (Weeks 6-8)

### API Endpoints to Implement

#### Networking
- `GET /networks` - List networks
- `GET /networks/{id}` - Inspect network
- `POST /networks/create` - Create network
- `DELETE /networks/{id}` - Remove network
- `POST /networks/{id}/connect` - Connect container to network
- `POST /networks/{id}/disconnect` - Disconnect container

#### Volumes
- `GET /volumes` - List volumes
- `GET /volumes/{name}` - Inspect volume
- `POST /volumes/create` - Create volume
- `DELETE /volumes/{name}` - Remove volume

### Architectural Mapping

**Docker Networks → Apple Container DNS:**
```swift
// Translate Docker bridge network to Apple's DNS
// containers on "my-network" become:
// container-name.my-network.container.internal
```

**Docker Volumes → Apple Container Volumes:**
```swift
// Map Docker named volumes to container volume paths
// Handle VirtioFS limitations with read-only mounts where needed
```

### Success Criteria
```bash
# This should work:
docker compose up -d
docker compose ps
docker compose logs
docker compose down
```

Test with sample compose files:
- WordPress + MySQL
- Simple web app + Redis
- Multi-service app with dependencies

---

## Phase 4: Build & Advanced Features (Weeks 9-12)

### API Endpoints to Implement

#### Build API
- `POST /build` - Build image from Dockerfile
- `GET /images/{name}/history` - Image history

#### Container Operations
- `POST /containers/{id}/restart` - Restart container
- `POST /containers/{id}/pause` - Pause container
- `POST /containers/{id}/unpause` - Unpause container
- `POST /containers/{id}/rename` - Rename container
- `GET /containers/{id}/stats` - Container stats (CPU, memory)
- `GET /containers/{id}/top` - List processes

#### System Operations
- `GET /events` - System events stream
- `POST /containers/prune` - Prune unused containers
- `POST /images/prune` - Prune unused images

### Success Criteria
```bash
# These should work:
docker build -t myapp:latest .
docker stats
docker events
docker system prune
```

---

## Critical Implementation Details

### 1. API Version Negotiation

```swift
// Support API version in URL path
// /v1.51/containers/json
// /v1.28/containers/json

struct APIVersion {
    static let current = "1.51"
    static let minimum = "1.28"

    func isSupported(_ version: String) -> Bool {
        // Check if requested version is in supported range
    }
}
```

### 2. Container ID Management

```swift
// Docker uses 64-char hex IDs, Apple container uses UUIDs
class ContainerIDMapper {
    // Bidirectional mapping between Docker-style IDs and Apple container IDs
    func dockerID(for containerID: UUID) -> String
    func containerID(for dockerID: String) -> UUID?
}
```

### 3. Networking Translation

```swift
class NetworkBridge {
    // Translate Docker networking concepts to Apple's DNS model
    func createNetwork(name: String, config: NetworkConfig) throws
    func getDNSName(container: String, network: String) -> String
    // Returns: "container-name.network-name.container.internal"
}
```

### 4. Volume Handling

```swift
class VolumeManager {
    // Handle VirtioFS limitations
    func createVolume(name: String, options: VolumeOptions) throws
    func handleReadOnlyMount(_ path: String) // Workaround for chmod issues
}
```

---

## Testing Strategy

### Unit Tests
```swift
// Test API endpoint parsing, response formatting
func testContainerCreateRequest() {
    let json = """
    {"Image": "nginx:latest", "Cmd": ["nginx"]}
    """
    // Parse and validate
}
```

### Integration Tests
```swift
// Test with real Containerization API
func testFullContainerLifecycle() async throws {
    let container = try await createContainer(image: "alpine")
    try await startContainer(container.id)
    try await stopContainer(container.id)
    try await removeContainer(container.id)
}
```

### Compatibility Tests
```bash
#!/bin/bash
# Test with real Docker tools

export DOCKER_HOST=unix:///var/run/container-engine.sock

# Test Docker CLI
docker run -d --name test-nginx nginx:latest
docker ps | grep test-nginx
docker logs test-nginx
docker stop test-nginx
docker rm test-nginx

# Test Docker Compose
cd tests/compose-samples/wordpress
docker compose up -d
docker compose ps
docker compose down
```

---

## What to Tell Claude Code

Once you've set up the repo, here's what you can delegate to Claude Code:

### Initial Setup Phase

```
I'm building a Docker Engine API implementation backed by Apple's
Containerization framework in Swift.

Please help me:
1. Create the basic project structure with SwiftNIO HTTP server
2. Set up the Package.swift with dependencies:
   - swift-nio for networking
   - Containerization (github.com/apple/containerization)
3. Create a basic APIServer.swift that listens on a Unix socket
4. Implement the router that dispatches to handler functions
5. Add structured logging
```

### API Models Phase

```
Implement the Docker API models for the Container API based on the
Docker Engine API spec. Create Swift Codable structs for:

1. ContainerCreateRequest (with all the Docker create options)
2. ContainerResponse (inspect response)
3. ContainerListResponse
4. ContainerCreateResponse

Reference: https://docs.docker.com/engine/api/v1.51/#tag/Container

Use proper Swift naming conventions (camelCase) and handle the
JSON key mapping with CodingKeys.
```

### Handler Implementation Phase

```
Implement the container lifecycle handlers in ContainerHandlers.swift:

1. POST /containers/create - Parse request, call Containerization API
2. POST /containers/{id}/start - Start container
3. GET /containers/json - List all containers
4. GET /containers/{id}/json - Inspect container

For each handler:
- Parse the request body/parameters
- Call the corresponding Containerization API
- Map the response to Docker API format
- Handle errors appropriately

The Containerization API is available - show me how to call it.
```

### Networking Bridge Phase

```
Create a NetworkBridge class that translates Docker networking concepts
to Apple Container's DNS-based networking:

- Map Docker network names to DNS domains
- Generate DNS names for containers: {container}.{network}.container.internal
- Store network metadata (which containers are on which networks)
- Handle the fact that Apple containers already have IPs and DNS

Document the limitations compared to Docker's bridge networks.
```

### Testing Phase

```
Create integration tests for the container lifecycle:

1. Test creating a container from an image
2. Test starting and stopping containers
3. Test listing containers with filters
4. Test removing containers

Use XCTest and make the tests async/await compatible.
Mock the Containerization API for unit tests, but also have
integration tests that use the real API.
```

---

## What NOT to Delegate (Human Oversight Required)

1. **Architectural decisions** about networking/volume translation
2. **API version compatibility strategy**
3. **Error handling patterns** for Containerization → Docker API mapping
4. **Security considerations** (socket permissions, API authentication)
5. **Performance optimization** decisions
6. **Final testing with real Docker Compose** files

---

## Recommended Development Order

### Week 1: Foundation
- [ ] Project setup with SwiftNIO
- [ ] Unix socket server
- [ ] Basic routing
- [ ] Version and ping endpoints

### Week 2: Container Basics
- [ ] Container create/start/stop
- [ ] Container list/inspect
- [ ] Container remove
- [ ] ID mapping system

### Week 3: Images & Polish
- [ ] Image list/inspect
- [ ] Image pull (registry integration)
- [ ] Image remove
- [ ] Container logs endpoint
- [ ] Test with Docker CLI

### Week 4-5: Exec & Interaction
- [ ] Exec API implementation
- [ ] Attach support
- [ ] Streaming logs
- [ ] Interactive container support

### Week 6-7: Networking
- [ ] Network CRUD operations
- [ ] DNS name generation
- [ ] Network connect/disconnect
- [ ] Documentation of limitations

### Week 8: Volumes & Compose
- [ ] Volume CRUD operations
- [ ] VirtioFS workarounds
- [ ] Test with Docker Compose
- [ ] Fix compatibility issues

### Weeks 9-12: Build & Advanced
- [ ] Build API
- [ ] Stats and monitoring
- [ ] Events stream
- [ ] Prune operations
- [ ] Performance optimization

---

## Success Metrics

### MVP (Phase 1)
- ✅ Docker CLI basic commands work
- ✅ Can pull and run standard images
- ✅ Logs work correctly

### Compose Support (Phase 3)
- ✅ Docker Compose up/down works
- ✅ Multi-container apps with dependencies work
- ✅ WordPress + MySQL compose file works

### Production Ready (Phase 4)
- ✅ All common Docker CLI commands work
- ✅ Docker Compose covers 80% of use cases
- ✅ Clear documentation of limitations
- ✅ Performance benchmarks documented