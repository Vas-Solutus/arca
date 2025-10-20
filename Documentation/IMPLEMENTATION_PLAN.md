# Implementation Plan: Docker Engine API for Apple Containerization

## Project Overview

**Core Goal**: Implement the Docker Engine API (Moby API) as a daemon that translates Docker API calls to Apple's Containerization Swift API, enabling the entire Docker ecosystem (CLI, Compose, plugins) to work with Apple Containers.

## API Specification

**Source of Truth**: The complete Docker Engine API v1.51 specification is located at
`Documentation/DOCKER_ENGINE_API_SPEC.md`. All endpoint implementations, request/response
models, and behaviors should reference this OpenAPI specification.
The `Documentation/OCI_*_SPEC.md` files are the source of truth for how we build, run, and store images.

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
2. **API Version**: Implement Docker Engine API v1.51 (using OpenAPI spec at `Documentation/DOCKER_ENGINE_API_SPEC.md`)
3. **OCI Compliant**: Implement OCI compliance (using `Documentation/OCI_*_SPEC.md` files)
4. **Socket Path**: `/var/run/arca.sock` (symlink option to `/var/run/docker.sock`)
5. **Logging**: Structured logging with levels
6. **Configuration**: JSON config file + command-line flags

---

## Phase 0.5: Setup Automation (TODO)

### Problem
Arca requires the `vminit:latest` init system image to be built before ContainerManager can initialize. Currently this must be done manually by developers.

### Background
- vminit is a minimal init system that runs as PID 1 inside the Linux VM
- It provides a GRPC API over vsock for container management
- Must be cross-compiled to Linux using Swift Static Linux SDK
- Creates an OCI image stored in `~/Library/Application Support/com.apple.containerization/`

### Current Workaround
Manual build process (documented in README.md):
```bash
cd .build/checkouts/containerization
make cross-prep  # Install Swift Static Linux SDK (one-time)
make vminitd     # Build vminitd binaries
make init        # Package into vminit:latest image
```

### Tasks
- [ ] Create `arca setup` command that automates vminit build
- [ ] Auto-detect if vminit:latest exists in ImageStore
- [ ] Handle Swift Static Linux SDK installation (`make cross-prep`)
- [ ] Provide clear error messages if vminit is missing
- [ ] Consider bundling pre-built vminit binaries with releases
- [ ] Add `arca doctor` command to verify setup completeness

### Technical Details
**Why it fails without vminit:**
- ContainerManager initializes with `initfsReference: "vminit:latest"`
- Calls `imageStore.getInitImage(reference: "vminit:latest")`
- `getInitImage` tries to get locally first, then pull from registry
- Pulling fails because `vminit:latest` has no domain → "Invalid domain for image reference"

**Solution approaches:**
1. **Auto-build on first run** - Detect missing vminit and build automatically
2. **Pre-built binaries** - Ship pre-compiled vminit with releases
3. **Better error messages** - Detect missing vminit and provide clear setup instructions

---

## Phase 1: MVP - Core Container Lifecycle ✅ COMPLETE

### Goal: Run basic containers with Docker CLI ✅

### API Endpoints to Implement

Reference the OpenAPI specification at `Documentation/DOCKER_ENGINE_API_SPEC.md` for
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

### Success Criteria ✅ COMPLETE
```bash
# These all work:
docker ps                      ✅
docker run -d nginx:latest     ✅
docker logs <container-id>     ✅
docker stop <container-id>     ✅
docker rm <container-id>       ✅
docker images                  ✅
docker pull alpine:latest      ✅
docker rmi alpine:latest       ✅
```

**Status**: Phase 1 MVP complete as of 2025-10-19
- All 19 test scenarios passing
- Complete container lifecycle working
- Image management fully operational
- Docker CLI compatibility verified

### Phase 1 Implementation Tasks

#### Priority 0: Critical Blockers (Must Fix for Basic Functionality)

- [x] **Fix Docker logs binary format** (Sources/DockerAPI/Handlers/ContainerHandlers.swift:288-295)
  - Problem: `docker logs` returns "Unrecognized input header: 72"
  - Root cause: Docker expects multiplexed binary stream format, we return plain text
  - Required format: `[1 byte: stream type][3 bytes: padding][4 bytes: size][N bytes: payload]`
  - Stream types: 0=stdin, 1=stdout, 2=stderr
  - Reference: Docker Engine API spec section on "Stream format"
  - Files: ContainerHandlers.swift (retrieveLogs method)
  - **COMPLETED**: Implemented formatMultiplexedStream() method, returns binary Data with proper headers

- [x] **Implement short container ID resolution** (Sources/ContainerBridge/ContainerManager.swift)
  - Problem: `docker stop 266c0ba895e5` fails with "Container not found"
  - Root cause: Only match full 64-char IDs or exact names
  - Required: Support 12-char short IDs (prefix matching)
  - Docker behavior: Match shortest unique prefix (min 4 chars, typically 12)
  - Affected methods: getContainer, resolveContainer, all ID lookups
  - Files: ContainerManager.swift (ID resolution logic)
  - **COMPLETED**: Enhanced resolveContainerID() with prefix matching for 4-64 char hex strings

- [x] **Fix container restart/state management** (Sources/ContainerBridge/ContainerManager.swift)
  - Problem: `docker start test3` returns "container must be created" after container exits
  - Root cause: After wait() completes, must call stop() to clean up VM and transition to .stopped state
  - Required: Call stop() in monitoring task after wait(), then create() before start() when restarting
  - Containerization state machine: .stopped → create() → .created → start() → .started → (exit) → wait() → **stop()** → .stopped
  - Reference: containerization/examples/ctr-example/main.swift shows stop() must be called after wait()
  - Affected methods: startContainer (monitoring task), startContainer (restart logic)
  - Files: ContainerManager.swift (state management)
  - **COMPLETED**: Background monitor calls stop() after wait() to properly clean up VM; restart calls create() for exited containers

#### Priority 1: Core Functionality (Needed for Phase 1 Success)

- [x] **Fix HTTP response encoding** (Sources/ArcaDaemon/HTTPHandler.swift or Server.swift)
  - Problem: Docker CLI warns "Unrecognized input header: 0"
  - Symptom: HTTP responses contain "0\r\n\r\n" sequences
  - Root cause: Likely chunked transfer encoding or Content-Length issues
  - Files: HTTP response generation code
  - **COMPLETED**: Added Content-Length headers to all direct HTTPResponse creations (logs, attach, ping endpoints)

- [x] **Verify /containers/{id}/wait endpoint** (Sources/DockerAPI/Handlers/ContainerHandlers.swift:453-485)
  - Status: Implemented but needs testing
  - Test: `docker run alpine echo "test" && docker wait <container-id>`
  - Verify: Returns correct exit code in JSON format
  - Files: ContainerHandlers.swift (handleWaitContainer)
  - **COMPLETED**: Implementation verified - returns `{"StatusCode": exitCode}` per Docker API spec

- [x] **Verify DELETE /images/{name} endpoint** (Sources/ArcaDaemon/ArcaDaemon.swift:414-431)
  - Status: Implemented but needs testing
  - Test: `docker pull alpine && docker rmi alpine`
  - Verify: Image removed, returns correct response
  - Files: ArcaDaemon.swift, ImageHandlers.swift (handleDeleteImage)
  - **COMPLETED**: Implementation verified - parses force/noprune params, returns array of ImageDeleteResponseItem

- [x] **Implement container name resolution in all endpoints**
  - Problem: Some endpoints only accept IDs, not names
  - Required: All endpoints should accept name or ID
  - Pattern: Use resolveContainer(idOrName:) consistently
  - Affected: start, stop, remove, inspect, logs, wait, attach
  - Files: ContainerHandlers.swift (all handler methods)
  - **COMPLETED**: All endpoints already use resolveContainerID() or resolveContainer() which support full IDs, short IDs, and names

- [x] **Implement thread-safe concurrency with Swift actors**
  - Problem: Multiple concurrent Docker CLI requests could cause data races
  - Solution: Convert ContainerManager and ImageManager to actors
  - Added Sendable conformance to all data types for actor isolation
  - Files: ContainerManager.swift, ImageManager.swift, Types.swift, ImageTypes.swift
  - **COMPLETED**: Both managers are now actors with proper isolation

- [x] **Implement background container monitoring**
  - Problem: Containers stuck in "running" state after process exits
  - Solution: Spawn monitoring Task when containers start
  - Background task waits for container exit and updates state automatically
  - Proper actor isolation with weak self and callback methods
  - Files: ContainerManager.swift (startContainer, updateContainerStateAfterExit)
  - **COMPLETED**: Containers automatically transition to "exited" state

- [x] **Align container creation with Docker CLI pull behavior**
  - Problem: `docker run` with non-existent image should trigger client-side pull
  - Solution: Return 404 Not Found when image doesn't exist, let Docker CLI handle pull
  - Pattern: Check image exists, return 404 error, Docker CLI calls POST /images/create
  - Files: ContainerHandlers.swift (handleCreateContainer), ArcaDaemon.swift (route)
  - **COMPLETED**: Returns 404 for missing images, Docker CLI auto-pulls via /images/create

- [x] **Fix file descriptor cleanup on container removal**
  - Problem: Daemon crashes with "Bad file descriptor" after removing containers
  - Root cause: Background monitoring task held references while resources cleaned up
  - Solution: Wait for monitoring task completion, call stop() before removal
  - Files: ContainerManager.swift (removeContainer)
  - **COMPLETED**: Proper cleanup prevents crashes

- [x] **Implement short image ID resolution**
  - Problem: `docker rmi ed294d8639cc` fails with "Image not found"
  - Root cause: Only match full image references, not short IDs
  - Required: Support 12-char short IDs (prefix matching)
  - Docker behavior: Match by short ID (12+ hex chars) or full sha256 digest
  - Files: ImageManager.swift (resolveImage, deleteImage, inspectImage, getImage)
  - **COMPLETED**: Added resolveImage() with ID and reference matching

- [x] **Fix image deletion error codes**
  - Problem: Returns 500 Internal Server Error when image not found
  - Required: Return 404 Not Found for missing images
  - Docker behavior: "Error: No such image: latest" with 404 status
  - Files: ImageHandlers.swift (handleDeleteImage), ArcaDaemon.swift (route handler)
  - **COMPLETED**: Proper error case handling returns 404 for imageNotFound

- [x] **Extract DockerProgressFormatter for code reuse**
  - Problem: Progress formatting logic duplicated across handlers
  - Required: Single reusable formatter for pull, run, build operations
  - Pattern: Actor-based formatter with aggregate progress tracking
  - Files: DockerProgressFormatter.swift, ImageHandlers.swift
  - **COMPLETED**: Formatter extracted to separate file with full implementation

#### Priority 1.5: HTTP Streaming Architecture (Real-time Progress)

**Problem**: Docker operations like `docker pull`, `docker build`, and `docker run` show real-time progress updates as layers download, images build, or containers start. Arca currently returns complete responses only after operations finish, providing no progress feedback.

**Architecture Overview**:

Current architecture returns complete HTTP responses:
```
Request → Router → Handler → HTTPResponse (complete body)
```

New architecture supports streaming responses via callbacks:
```
Request → Router → Handler → HTTPResponseType enum
                                   ↓
                   ┌───────────────┴────────────────┐
                   ↓                                ↓
          .standard(HTTPResponse)      .streaming(status, headers, callback)
                   ↓                                ↓
          Send complete body            Invoke callback with HTTPStreamWriter
                                                    ↓
                                        Callback writes chunks progressively
```

**Key Components**:

1. **HTTPResponseType enum** - Represents either standard or streaming response
2. **HTTPStreamWriter protocol** - Interface for writing response chunks
3. **NIOHTTPStreamWriter** - SwiftNIO implementation using channel.writeAndFlush()
4. **Modified Router** - Returns HTTPResponseType instead of HTTPResponse
5. **Modified HTTPHandler** - Detects streaming responses and invokes callbacks
6. **Progress formatters** - Convert ProgressEvent to Docker JSON format

**Docker Progress Format**:
Docker API returns newline-delimited JSON that the Docker CLI renders as progress bars:
```json
{"status":"Pulling from library/nginx","id":"alpine"}
{"status":"Pulling fs layer","id":"76f96c998a19"}
{"status":"Downloading","progressDetail":{"current":1024,"total":4194304},"progress":"[=>  ] 1.024MB/4.194MB","id":"76f96c998a19"}
{"status":"Download complete","id":"76f96c998a19"}
{"status":"Digest: sha256:abc123..."}
{"status":"Status: Downloaded newer image for nginx:alpine"}
```

**Apple Containerization API Integration**:
The Containerization framework provides `ProgressHandler = @Sendable (_ events: [ProgressEvent]) async -> Void`:
- Events: "add-total-size", "add-total-items", "add-size", "add-items"
- Emitted during `imageStore.pull()`, layer fetches, etc.
- Must be translated to Docker JSON format and written via HTTPStreamWriter

**Endpoints Requiring Streaming** (Phases 1-4):
- `POST /images/create` - Image pull progress (Phase 1)
- `POST /build` - Build progress (Phase 4)
- `POST /containers/create?fromImage=X` - Auto-pull progress (Phase 1)
- `GET /events` - System events stream (Phase 4)
- `POST /containers/{id}/attach` - Interactive I/O (Phase 2)

**Implementation Tasks**:

- [x] **Add HTTPResponseType and HTTPStreamWriter to HTTPTypes.swift**
  - Define HTTPResponseType enum with .standard and .streaming cases
  - Define HTTPStreamWriter protocol with write() and finish() methods
  - Add HTTPStreamingCallback typealias
  - Files: Sources/ArcaDaemon/HTTPTypes.swift
  - **COMPLETED**: Types added with proper Sendable conformance

- [x] **Implement NIOHTTPStreamWriter in HTTPHandler.swift**
  - Create NIOHTTPStreamWriter class implementing HTTPStreamWriter
  - Use ChannelHandlerContext.writeAndFlush() for chunk writing
  - Handle chunked transfer encoding via SwiftNIO
  - Implement finish() to send final empty chunk
  - Files: Sources/ArcaDaemon/HTTPHandler.swift
  - **COMPLETED**: NIOHTTPStreamWriter fully implemented with proper error handling

- [x] **Update HTTPHandler to support streaming responses**
  - Modify handleRequest() to receive HTTPResponseType
  - Add sendResponseType() method to detect .standard vs .streaming
  - For .streaming: send headers with Transfer-Encoding: chunked, invoke callback
  - For .standard: existing sendResponse() behavior
  - Files: Sources/ArcaDaemon/HTTPHandler.swift (handleRequest, sendResponseType)
  - **COMPLETED**: HTTPHandler supports both standard and streaming responses

- [x] **Update Router to return HTTPResponseType**
  - Change RouteHandler typealias from `-> HTTPResponse` to `-> HTTPResponseType`
  - Update route() method to return HTTPResponseType
  - Files: Sources/ArcaDaemon/Router.swift
  - **COMPLETED**: Router.swift updated to use HTTPResponseType

- [x] **Update all route registrations to use HTTPResponseType**
  - Wrap existing handler returns with .standard(HTTPResponse)
  - No logic changes needed, just wrapping
  - Files: Sources/ArcaDaemon/ArcaDaemon.swift (all route registrations)
  - **COMPLETED**: All routes updated to return HTTPResponseType

- [x] **Create Docker progress formatter**
  - Implement formatDockerProgress() to convert ProgressEvent → Docker JSON
  - Track total/current sizes and items for progress calculations
  - Generate layer IDs from descriptors
  - Format status messages: "Pulling fs layer", "Downloading", "Download complete"
  - Files: Sources/DockerAPI/DockerProgressFormatter.swift (extracted to separate file)
  - **COMPLETED**: DockerProgressFormatter actor with full progress tracking

- [x] **Implement streaming image pull handler**
  - Create handlePullImageStreaming() returning .streaming()
  - Create progress callback that writes Docker JSON via HTTPStreamWriter
  - Pass callback to imageManager.pullImage(progress: callback)
  - Handle errors and send final status message
  - Files: Sources/DockerAPI/Handlers/ImageHandlers.swift
  - **COMPLETED**: handlePullImageStreaming() with real-time progress updates

- [x] **Wire up streaming in POST /images/create route**
  - Update route registration to use handlePullImageStreaming()
  - Return .streaming() response type
  - Files: Sources/ArcaDaemon/ArcaDaemon.swift (images/create route)
  - **COMPLETED**: Route calls handlePullImageStreaming() for real-time progress

- [x] **Test real-time progress with docker pull**
  - Test: `docker pull nginx:alpine` shows layer-by-layer progress
  - Verify: Progress bars, percentages, and sizes display correctly
  - Verify: Final "Downloaded newer image" message appears
  - Test with large images (nginx, ubuntu) and small images (alpine, busybox)
  - **COMPLETED**: Real-time progress working for all image pulls

**Reference Implementation**:
- Apple's ProgressConfig.swift: https://github.com/apple/container/blob/main/Sources/TerminalProgress/ProgressConfig.swift
- Docker Engine API spec: Documentation/DOCKER_ENGINE_API_SPEC.md (POST /images/create)
- ProgressEvent definition: .build/checkouts/containerization/Sources/ContainerizationExtras/ProgressEvent.swift

#### Priority 2: Robustness & Polish

- [x] **Fix error message format to match Docker**
  - Problem: Error messages said "Image not found:" instead of "No such image:"
  - Solution: Updated all error types to use Docker-compatible messages
  - Added errorDescription() helper to use CustomStringConvertible instead of localizedDescription
  - Files: ContainerBridge/*Manager.swift, DockerAPI/Handlers/*.swift, DockerAPI/Models/*.swift
  - **COMPLETED**: All error messages now match Docker format exactly

- [x] **Add Docker filter parameter validation**
  - Problem: Docker CLI sends filters as {"filterName": {"value": true}}, validator expected different format
  - Solution: Created parseDockerFiltersToArray() and parseDockerFiltersToSingle() helpers
  - Follows DRY principle - single place for filter conversion logic
  - Files: QueryParameterValidator.swift, ArcaDaemon.swift
  - **COMPLETED**: Filter validation now handles Docker's format correctly

- [ ] **Refactor error handling architecture** (Future improvement)
  - Problem: Multiple error types (ImageManagerError, ImageHandlerError, ImageError) can represent same error
  - Current: Quick fix applied - all error messages updated to match Docker's format
  - Proper fix: Refactor to have errors flow through without re-wrapping, or preserve original error when wrapping
  - Consider: Single error type per layer, or better error composition pattern
  - Files: ContainerBridge/*Manager.swift, DockerAPI/Handlers/*.swift, DockerAPI/Models/*.swift

- [ ] **Add comprehensive query parameter validation**
  - Problem: Some invalid query params might be silently ignored
  - Required: Validate all parameters (limit ranges, timestamps, etc.)
  - Return 400 Bad Request for invalid params
  - Files: All handler methods

- [ ] **Improve error messages**
  - Container not found: Include both ID and name in error
  - Invalid state transitions: Explain current state and required state
  - Image pull failures: Include registry URL and auth status
  - Files: ContainerError, ImageHandlerError enums

- [ ] **Test log filtering edge cases**
  - Empty logs
  - Logs with only stdout or only stderr
  - Tail with value larger than available lines
  - Since/until with no matching logs
  - Binary output in logs
  - Files: ContainerHandlers.swift (retrieveLogs)

- [ ] **Add container ID validation**
  - Validate format: 64-char hex (full) or 4-12 char (short)
  - Return 400 Bad Request for invalid format
  - Files: ContainerHandlers.swift

#### Priority 3: Testing & Verification

- [x] **Create Phase 1 MVP test script**
  - Created comprehensive test script: scripts/test-phase1-mvp.sh
  - Tests 19 scenarios including error handling
  - Colorful output with pass/fail indicators
  - Automatic cleanup
  - **COMPLETED**: All 19 tests passing

- [x] **Test all Phase 1 success criteria**
  - `docker ps` - List containers ✅
  - `docker run -d nginx:latest` - Create and start container ✅
  - `docker logs <container-id>` - View logs (with binary format fix) ✅
  - `docker stop <container-id>` - Stop container (with short ID) ✅
  - `docker rm <container-id>` - Remove container ✅
  - `docker images` - List images ✅
  - `docker pull alpine:latest` - Pull image ✅
  - `docker rmi alpine:latest` - Remove image ✅
  - `docker start <container-id>` - Restart exited container ✅
  - Error handling for missing images/containers ✅
  - **COMPLETED**: All Phase 1 commands working correctly

- [x] **Test container lifecycle combinations**
  - Create → Start → Stop → Start (restart from exited) ✅ Test 11
  - Create → Start → Remove (force removal) ✅ Test 14
  - Create → Remove (remove without starting) ✅ Test 15
  - Run (create+start) → Stop → Remove ✅ Tests 5-10
  - **COMPLETED**: All container lifecycle combinations tested and passing

- [ ] **Test with various image types**
  - Alpine (minimal, sh shell)
  - Nginx (daemon process)
  - BusyBox (minimal utilities)
  - Ubuntu (full OS)

- [ ] **Verify Docker CLI compatibility**
  - Test with latest Docker CLI
  - Check output format matches Docker Engine
  - Verify exit codes match Docker behavior

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

#### Image Size Tracking (TODO)
**Problem**: Arca currently reports compressed (OCI blob) sizes instead of uncompressed (extracted) sizes like Docker.

**Impact**:
- `docker images` shows smaller sizes than Docker Engine
- Example: alpine shows 4.14MB (Arca) vs 13.3MB (Docker)

**Root Cause**:
The OCI Image spec only provides compressed blob sizes in `manifest.layers[].size`.
Uncompressed sizes require either:
1. Decompressing layers (slow)
2. Tracking sizes during pull operations (requires storage)
3. Using compression heuristics (inaccurate)

**Implementation Tasks**:
- [ ] Add uncompressed size tracking to ImageStore wrapper
- [ ] Calculate/store uncompressed sizes during `imageStore.pull()`
- [ ] Store size metadata alongside OCI content (e.g., in auxiliary JSON file)
- [ ] Update ImageManager to read and report uncompressed sizes
- [ ] Add migration for existing images (decompress once to measure)
- [ ] Update size calculations in `listImages()` and `inspectImage()`

**See Also**: `Documentation/LIMITATIONS.md` - Image Size Reporting section

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