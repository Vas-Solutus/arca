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

## Phase 3: Docker Compose Support via OVN/OVS Helper VM (Weeks 6-12)

**Architecture**: See `Documentation/NETWORK_ARCHITECTURE.md` for complete design.

This phase implements Docker-compatible networking using a lightweight Linux VM running OVN/OVS, providing full Docker Network API compatibility with enterprise-grade security.

### Phase 3.1: Helper VM Foundation (Week 1-2) ✅ COMPLETE

**Architecture**: The helper VM is managed as a **Container** using the Apple Containerization framework with a custom Linux kernel built with TUN support. This provides:
- Built-in vsock support via `Container.dialVsock()` for gRPC communication
- Custom kernel with CONFIG_TUN=y for OVS netdev datapath
- Simpler lifecycle management using ContainerManager
- Consistent with how we manage application containers

**Status**: Phase 3.1 complete as of 2025-10-22
- Helper VM successfully launches as a Container
- OVS/OVN networking stack operational
- gRPC control API working via vsock
- All 13 integration tests passing
- Bridge creation with proper name length handling (15 char limit)
- Multiple bridge support with MD5-based unique naming

#### Helper VM Image Creation

- [x] **Create Alpine Linux base image for helper VM**
  - Use Alpine 3.22 (latest stable) as base (~50MB)
  - Install OVN/OVS packages: openvswitch, openvswitch-ovn
  - Install dnsmasq for DNS resolution
  - Install Go runtime for control API server
  - Target size: <100MB total
  - Files: `scripts/build-helper-vm.sh`, `helpervm/Dockerfile`
  - **COMPLETED**: Alpine 3.22 Dockerfile with OVN/OVS stack

- [x] **Build OVN/OVS control API server in Go**
  - Define gRPC service in `helpervm/proto/network.proto`
  - Implement NetworkControl service with methods:
    - CreateBridge(networkID, subnet, gateway)
    - DeleteBridge(networkID)
    - AttachContainer(containerID, networkID, ip, mac, hostname, aliases)
    - DetachContainer(containerID, networkID)
    - ListBridges()
    - SetNetworkPolicy(networkID, rules)
    - GetHealth() - Health check endpoint
  - Use **vsock listener** on port 9999 for host-VM communication
  - Translate gRPC calls to ovs-vsctl/ovn-nbctl commands
  - Files: `helpervm/control-api/main.go`, `helpervm/control-api/server.go`
  - **COMPLETED**: Go gRPC server with vsock support and all NetworkControl methods implemented

- [x] **Create helper VM startup script**
  - Start OVS daemon (ovs-vswitchd, ovsdb-server)
  - Initialize OVN databases (ovn-nbctl init, ovn-sbctl init)
  - Start OVN controller (ovn-controller)
  - Start dnsmasq for DNS resolution
  - Start control API server
  - Files: `helpervm/scripts/startup.sh`, `helpervm/scripts/ovs-init.sh`
  - **COMPLETED**: Full VM initialization sequence with OVN/OVS startup

- [x] **Build helper VM OCI image**
  - Package Alpine + OVN/OVS + control API into OCI container image
  - Use buildah/podman to create OCI image
  - Store as standard OCI image (managed by Containerization framework's ImageStore)
  - Tag as `arca-network-helper:latest`
  - Document build process in README
  - Files: `Makefile` target for `make helpervm`, `scripts/build-helper-vm.sh`
  - **COMPLETED**: Build infrastructure ready, Makefile target created

#### Custom Kernel Build

- [x] **Build Linux kernel with TUN support**
  - Kernel version: 6.14.9 (Apple's containerization kernel)
  - Enable CONFIG_TUN=y for TAP device support (required by OVS netdev datapath)
  - Automated build using Apple's exact build process
  - Build location: `~/.arca/kernel-build/kernel/`
  - Output: `~/.arca/vmlinux` (27MB)
  - Makefile target: `make kernel`
  - Files: `scripts/build-kernel.sh`, `Documentation/KERNEL_BUILD.md`
  - **COMPLETED**: Kernel built successfully with TUN support verified in helper VM

#### NetworkHelperVM Swift Actor

- [x] **Implement NetworkHelperVM actor for Container lifecycle**
  - Launch helper VM as a LinuxContainer using Containerization framework
  - Container configuration:
    - Image: `arca-network-helper:latest`
    - Kernel: Custom kernel with TUN support (`~/.arca/vmlinux`)
    - CPU: 2 vCPU, Memory: 512MB
    - Process: `/usr/local/bin/startup.sh` (init script)
  - Monitor container state and health via OVNClient.getHealth()
  - Handle graceful shutdown via LinuxContainer.stop()
  - Files: `Sources/ContainerBridge/NetworkHelperVM.swift`
  - **COMPLETED**: NetworkHelperVM fully operational with Container lifecycle management

- [x] **Implement OVNClient to use Container.dialVsock() for gRPC**
  - Connect via `container.dialVsock(9999)` to get FileHandle
  - Create gRPC channel using NIO vsock transport
  - Implemented methods:
    - createBridge(networkID:subnet:gateway:) ✓
    - deleteBridge(networkID:) ✓
    - listBridges() ✓
    - getHealth() ✓
  - Handle connection failures with proper error handling
  - Files: `Sources/ContainerBridge/OVNClient.swift`
  - **COMPLETED**: OVNClient working with vsock communication over gRPC

- [x] **Generate Swift gRPC stubs from proto**
  - Add swift-protobuf and swift-grpc to Package.swift
  - Generate Swift code from `network.proto`
  - Add build script to regenerate on proto changes
  - Install protoc-gen-grpc-swift v1.27.0 (matches grpc-swift dependency)
  - Files: `Package.swift`, `scripts/generate-grpc.sh`, `Sources/ContainerBridge/Generated/network.pb.swift`
  - **COMPLETED**: Generated code with public visibility, Makefile target for plugin installation

- [x] **Test helper VM container launch and basic OVN operations**
  - Integration test: Launch helper VM as LinuxContainer and verify health ✓
  - Test Container.dialVsock() connectivity to gRPC API ✓
  - Test bridge creation via OVNClient ✓
  - Test bridge deletion ✓
  - Test multiple bridge creation (handled Linux IFNAMSIZ 15-char limit) ✓
  - Test vsock communication via Container.dialVsock() ✓
  - Verify OVN databases are initialized correctly ✓
  - Bridge naming: MD5 hash-based (br-{12 hex chars}) to avoid collisions ✓
  - Files: `Sources/ArcaTestHelper/main.swift`, `Makefile` (test-helper target)
  - **COMPLETED**: All 13 integration tests passing

#### Key Issues Resolved

- [x] **Fix Linux network interface name length limit**
  - Problem: Bridge names `arca-br-test-network` (20 chars) exceeded Linux IFNAMSIZ limit (15 chars)
  - Symptom: TAP devices created with truncated names, `ip link show` failed to find them
  - Solution: Use MD5 hash-based naming `br-{12 hex chars}` for unique 15-char names
  - Changed prefix from `arca-br-` to `br-` to maximize hash space (48 bits)
  - Files: `helpervm/control-api/server.go` (CreateBridge, DeleteBridge, AttachContainer)
  - **COMPLETED**: All bridges now use proper length-limited names

### Phase 3.15: Routing Infrastructure Improvements (Week 2.5)

**Rationale**: Before implementing the Network Management Layer, improve the HTTP routing infrastructure to make endpoint implementation cleaner and more maintainable. This gives us 80% of Vapor's benefits with 5% of the complexity, while maintaining our minimal-dependency philosophy.

#### Router DSL Enhancement

- [ ] **Add HTTP method convenience methods to Router**
  - Implement `.get()`, `.post()`, `.put()`, `.delete()` methods
  - Clean syntax: `router.get("/containers/json") { req in ... }`
  - Replace verbose `router.register(method: .GET, pattern: ...)` calls
  - Maintain existing route matching and path parameter extraction
  - Files: `Sources/ArcaDaemon/Router.swift`

#### Middleware Pattern

- [ ] **Design middleware protocol and pipeline**
  - Create `Middleware` protocol with `func handle(_ request: HTTPRequest, next: (HTTPRequest) async throws -> HTTPResponse) async throws -> HTTPResponse`
  - Add middleware chain to Router: `var middlewares: [Middleware]`
  - Implement `router.use(_ middleware: Middleware)` registration
  - Execute middlewares in order before route handlers
  - Files: `Sources/ArcaDaemon/Middleware.swift`, `Sources/ArcaDaemon/Router.swift`

- [ ] **Implement APIVersionNormalizer middleware**
  - Move version normalization from Router to middleware
  - Strip `/v{major}.{minor}` prefix from request path
  - Store original version in request context for response headers
  - Simplifies router logic and makes version handling explicit
  - Files: `Sources/ArcaDaemon/Middlewares/APIVersionNormalizer.swift`

- [ ] **Implement RequestLogger middleware**
  - Log incoming requests: method, path, query parameters
  - Log response: status code, duration
  - Use structured logging with Logger metadata
  - Optional: filter sensitive data (auth headers, image digests)
  - Files: `Sources/ArcaDaemon/Middlewares/RequestLogger.swift`

#### Request/Response Helpers

- [ ] **Add HTTPRequest convenience extensions**
  - `func queryBool(_ key: String, default: Bool = false) -> Bool` - Parse boolean query params
  - `func queryInt(_ key: String) -> Int?` - Parse integer query params
  - `func queryString(_ key: String) -> String?` - Get string query params
  - `func pathParam(_ key: String) -> String?` - Type-safe path parameter access
  - `func jsonBody<T: Decodable>(_ type: T.Type) throws -> T` - Decode JSON body
  - Files: `Sources/ArcaDaemon/HTTPRequest+Helpers.swift`

- [ ] **Add HTTPResponse convenience static methods**
  - `static func ok<T: Encodable>(_ value: T) -> HTTPResponse` - 200 OK with JSON
  - `static func created<T: Encodable>(_ value: T) -> HTTPResponse` - 201 Created
  - `static func noContent() -> HTTPResponse` - 204 No Content
  - `static func badRequest(_ message: String) -> HTTPResponse` - 400 with error
  - `static func notFound(_ message: String) -> HTTPResponse` - 404 with error
  - `static func conflict(_ message: String) -> HTTPResponse` - 409 with error
  - `static func internalError(_ message: String) -> HTTPResponse` - 500 with error
  - Files: `Sources/ArcaDaemon/HTTPResponse+Helpers.swift`

#### Refactor Existing Routes

- [ ] **Migrate container routes to new DSL**
  - Convert all container endpoint registrations in `ArcaDaemon.swift`
  - Use new `.get()`, `.post()`, `.delete()` methods
  - Use request helpers for query/path parameters
  - Use response helpers for consistent JSON responses
  - Example:
    ```swift
    // Old:
    router.register(method: .GET, pattern: "/containers/json") { request in
        let all = request.queryParameters["all"] == "true"
        return await containerHandlers.handleListContainers(all: all)
    }

    // New:
    router.get("/containers/json") { req in
        let all = req.queryBool("all")
        return try await containerHandlers.handleListContainers(all: all)
    }
    ```
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift`

- [ ] **Migrate image routes to new DSL**
  - Convert all image endpoint registrations
  - Use new convenience methods
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift`

- [ ] **Migrate system routes to new DSL**
  - Convert version, ping, info endpoints
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift`

#### Testing

- [ ] **Unit tests for Router DSL**
  - Test `.get()`, `.post()`, `.put()`, `.delete()` registration
  - Verify route matching with new API
  - Test middleware execution order
  - Files: `Tests/ArcaTests/RouterTests.swift`

- [ ] **Unit tests for middleware**
  - Test APIVersionNormalizer strips versions correctly
  - Test RequestLogger logs requests/responses
  - Test middleware chain execution
  - Files: `Tests/ArcaTests/MiddlewareTests.swift`

- [ ] **Unit tests for request/response helpers**
  - Test query parameter parsing (bool, int, string)
  - Test path parameter extraction
  - Test JSON body decoding
  - Test response static methods
  - Files: `Tests/ArcaTests/HTTPHelpersTests.swift`

- [ ] **Integration test with real endpoints**
  - Verify existing endpoints still work with new DSL
  - Test middleware applied to all routes
  - Test logging captures requests
  - Files: `Tests/ArcaTests/RoutingIntegrationTests.swift`

#### Documentation

- [ ] **Update CLAUDE.md with new routing patterns**
  - Document new DSL syntax for route registration
  - Provide middleware examples
  - Show request/response helper usage
  - Migration guide for converting old routes
  - Files: `CLAUDE.md`

**Expected Outcome**: Cleaner, more maintainable routing code with ~50% less boilerplate. This will make implementing the Network API endpoints in Phase 3.2 much faster and more pleasant.

### Phase 3.2: Network Management Layer (Week 3-4)

#### NetworkManager Actor

- [ ] **Implement NetworkManager actor with core state**
  - Create NetworkMetadata struct (id, name, driver, subnet, gateway, containers, created, options)
  - Maintain networks dictionary: [String: NetworkMetadata]
  - Maintain containerNetworks mapping: [String: Set<String>]
  - Initialize with reference to NetworkHelperVM
  - Add actor isolation with Sendable conformance
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

- [ ] **Implement network creation logic**
  - Generate Docker network ID (64-char hex)
  - Validate network name (alphanumeric, hyphens, underscores)
  - Parse and validate IPAM config (subnet, gateway, IP range)
  - Call helperVM.createBridge() to create OVS bridge
  - Store NetworkMetadata
  - Return Docker-compatible network response
  - Files: `Sources/ContainerBridge/NetworkManager.swift` (createNetwork method)

- [ ] **Implement network deletion logic**
  - Verify network exists
  - Check no containers are attached (or force disconnect if force=true)
  - Call helperVM.deleteBridge()
  - Remove from networks dictionary
  - Clean up IPAM state
  - Files: `Sources/ContainerBridge/NetworkManager.swift` (deleteNetwork method)

- [ ] **Implement network listing and inspection**
  - listNetworks(filters:) - Support filters: name, id, driver, type
  - inspectNetwork(id:) - Return full network details
  - Translate to Docker API format
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

#### IPAM (IP Address Management)

- [ ] **Create IPAMAllocator actor**
  - Track IP allocations per network: [networkID: Set<String>]
  - Implement allocateIP(networkID:subnet:preferredIP:)
    - Parse CIDR notation
    - Reserve .0 (network), .1 (gateway), .255 (broadcast)
    - Find next available IP or use preferredIP if specified
    - Mark IP as allocated
    - Return IP address string
  - Implement releaseIP(networkID:ip:)
  - Handle subnet exhaustion error
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift`

- [ ] **Implement default network subnet allocation**
  - Docker default: 172.17.0.0/16 for "bridge" network
  - Custom networks: Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16
  - Detect subnet conflicts
  - Support user-specified subnets
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift` (allocateSubnet method)

- [ ] **Implement persistent IPAM state**
  - Store allocations in `~/.arca/ipam.json`
  - Load on daemon startup
  - Save on every allocation/release
  - Handle corrupted state file gracefully
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift`, `Sources/ContainerBridge/Config.swift`

- [ ] **Test IPAM allocation and persistence**
  - Unit test: Allocate/release IPs
  - Test subnet exhaustion handling
  - Test persistence across restarts
  - Test conflict detection
  - Files: `Tests/ArcaTests/IPAMAllocatorTests.swift`

### Phase 3.3: Docker Network API Endpoints (Week 5-6)

#### Network API Models

- [ ] **Create Docker Network API request/response models**
  - NetworkCreateRequest (Name, Driver, IPAM, Options, Labels)
  - NetworkCreateResponse (Id, Warning)
  - Network (full network object for inspect/list)
  - NetworkConnectRequest (Container, EndpointConfig)
  - NetworkDisconnectRequest (Container, Force)
  - IPAM structs (Config, Address)
  - Files: `Sources/DockerAPI/Models/Network.swift`

- [ ] **Create NetworkHandlers**
  - Implement handler methods returning HTTPResponseType
  - Wire up NetworkManager calls
  - Handle errors and translate to HTTP status codes
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

#### Network Endpoints

- [ ] **POST /networks/create - Create network**
  - Parse NetworkCreateRequest from body
  - Validate driver (support "bridge", "overlay"; reject "host", "macvlan")
  - Extract IPAM config (subnet, gateway, IP range)
  - Call networkManager.createNetwork()
  - Return NetworkCreateResponse with ID
  - Error handling: 400 for invalid config, 409 for duplicate name, 500 for internal errors
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`, `Sources/ArcaDaemon/ArcaDaemon.swift`

- [ ] **GET /networks - List networks**
  - Parse filters query parameter (JSON object: {"name": {"my-net": true}})
  - Support filters: name, id, driver, type, label
  - Call networkManager.listNetworks(filters:)
  - Return array of Network objects
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

- [ ] **GET /networks/{id} - Inspect network**
  - Parse network ID or name from path
  - Support short ID prefix matching (12-char hex)
  - Call networkManager.inspectNetwork()
  - Return Network object with full details
  - Error handling: 404 if not found
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

- [ ] **DELETE /networks/{id} - Delete network**
  - Parse network ID or name
  - Parse force query parameter
  - Call networkManager.deleteNetwork(force:)
  - Return 204 No Content on success
  - Error handling: 404 if not found, 409 if containers attached and !force
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

- [ ] **POST /networks/{id}/connect - Connect container**
  - Parse network ID and NetworkConnectRequest body
  - Resolve container ID from name or ID
  - Extract EndpointConfig (IPv4Address, Aliases)
  - Allocate IP (use specified or auto-allocate)
  - Generate MAC address
  - Call helperVM.attachContainer()
  - Create VZVirtioNetworkDeviceConfiguration with VZFileHandleNetworkDeviceAttachment
  - Add network device to container VM config
  - If container running: restart container (or hot-plug if supported)
  - Update network and container metadata
  - Error handling: 404 if network/container not found, 409 if already connected
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`, `Sources/ContainerBridge/NetworkManager.swift`

- [ ] **POST /networks/{id}/disconnect - Disconnect container**
  - Parse network ID and NetworkDisconnectRequest body
  - Resolve container ID
  - Parse force parameter
  - Call helperVM.detachContainer()
  - Remove network device from container VM config
  - If container running: restart container
  - Update network and container metadata
  - Error handling: 404 if not found, 409 if not connected
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

- [ ] **Register network routes in ArcaDaemon**
  - POST /networks/create → handleCreateNetwork
  - GET /networks → handleListNetworks
  - GET /networks/{id} → handleInspectNetwork
  - DELETE /networks/{id} → handleDeleteNetwork
  - POST /networks/{id}/connect → handleConnectNetwork
  - POST /networks/{id}/disconnect → handleDisconnectNetwork
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift`

### Phase 3.4: TAP-over-vsock Container Network Integration (Week 7-10)

**Architecture**: Implement TAP devices in containers forwarded over vsock to helper VM for OVS bridge attachment. The arca-tap-forwarder binary is bind-mounted into containers and launched on-demand when containers connect to networks.

**Reference**: See `Documentation/NETWORK_ARCHITECTURE.md` for complete TAP-over-vsock design.

#### Task 1: Implement arca-tap-forwarder Binary (Week 7)

- [ ] **Create standalone arca-tap-forwarder Swift package**
  - Independent Swift package built for Linux (cross-compiled)
  - gRPC server for receiving network configuration
  - TAP device creation using ioctl TUNSETIFF on `/dev/net/tun`
  - Configure as `IFF_TAP | IFF_NO_PI` (TAP mode, no protocol info)
  - vsock connection to helper VM for packet forwarding
  - Bidirectional forwarding loops (TAP → vsock, vsock → TAP)
  - Use 64KB buffers for frame forwarding
  - Files: `arca-tap-forwarder/Sources/`

- [x] **Build and install arca-tap-forwarder**
  - Cross-compile with Swift Static Linux SDK (aarch64-musl)
  - Install to `~/.arca/bin/arca-tap-forwarder`
  - Build script: `scripts/build-tap-forwarder.sh`
  - Makefile target: `make tap-forwarder`

- [x] **Inject binary into containers via bind mount**
  - ContainerManager bind-mounts `~/.arca/bin/` directory → `/.arca/bin/` in container
  - Binary accessible at `/.arca/bin/arca-tap-forwarder`
  - Hidden dotfile directory minimizes user visibility
  - Read-only mount (virtiofs share with "ro" option)
  - Only mounted if directory exists
  - Files: `Sources/ContainerBridge/ContainerManager.swift:313-334`

- [x] **Launch forwarder on-demand via container.exec()**
  - NetworkBridge.ensureTAPForwarderRunning() launches binary when needed
  - Executes `/.arca/bin/arca-tap-forwarder` in container namespace
  - Uses standard container.exec() API (runs in container namespace)
  - Process tracked in runningForwarders map for lifecycle management
  - Automatic cleanup when container stops
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:62-89`

#### Task 2: Implement NetworkBridge in Arca Daemon (Week 7-8)

- [x] **Create NetworkBridge actor**
  - Track network attachments: `[containerID: [networkID: NetworkAttachment]]`
  - Track running forwarders: `[containerID: LinuxProcess]`
  - Manage port allocation via PortAllocator (base: 20000)
  - Implement `attachContainer()` to launch forwarder and configure network
  - Implement `detachContainer()` to cleanup network attachment
  - Files: `Sources/ContainerBridge/NetworkBridge.swift`

- [x] **Implement port allocation**
  - PortAllocator class for vsock port management
  - Base port 20000, allocates sequentially
  - Helper VM uses +10000 offset (containerPort 20000 → helperPort 30000)
  - Track allocated ports in PortAllocator.allocatedPorts set
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:32-58`

- [x] **Integrate NetworkBridge with NetworkManager**
  - NetworkManager uses NetworkBridge for container attachments
  - Calls `networkBridge.attachContainer()` when connecting to network
  - Passes helper VM's LinuxContainer, network/container metadata
  - Allocates vsock port for TAP-over-vsock relay
  - Sends AttachContainer gRPC request to helper VM with vsockPort
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

#### Task 3: Implement TAP Relay Server for Helper VM (Week 8-9)

- [x] **Create gRPC control API in Go**
  - NetworkControl protobuf service definition
  - Implemented in Go for Alpine Linux compatibility
  - Uses mdlayher/vsock library for vsock listener
  - Listens on vsock port 9999 for control commands
  - Files: `helpervm/proto/network.proto`, `helpervm/control-api/main.go`

- [x] **Implement TAPRelayManager for packet forwarding**
  - Manages active TAP relays: `map[uint32]*TAPRelay`
  - StartRelay() creates TAP device and starts bidirectional forwarding
  - StopRelay() cleans up TAP device and closes connections
  - Each relay listens on helperPort (containerPort + 10000)
  - Attaches TAP device to OVS bridge as internal port
  - Files: `helpervm/control-api/tap_relay.go`

- [x] **Implement TAP device creation and management**
  - Create TAP device using /dev/net/tun (IFF_TAP | IFF_NO_PI)
  - Unique device names based on network/container IDs
  - Configure as OVS internal port (created by relay, not ovs-vsctl)
  - Set MAC address for container interface
  - Bring interface up with IFF_UP | IFF_RUNNING
  - Files: `helpervm/control-api/tap_relay.go`

- [x] **Implement bidirectional packet forwarding**
  - forwardVsockToTAP(): read from vsock, write to TAP fd
  - forwardTAPToVsock(): read from TAP fd, write to vsock
  - Uses goroutines for concurrent forwarding in each direction
  - 64KB buffers for frame forwarding
  - Graceful error handling and connection cleanup
  - Files: `helpervm/control-api/tap_relay.go`

- [x] **Implement gRPC NetworkControl service**
  - CreateNetwork RPC: creates OVS bridge with ovs-vsctl
  - DeleteNetwork RPC: removes OVS bridge
  - AttachContainer RPC: starts TAP relay for container, passes bridgeName from server
  - DetachContainer RPC: stops TAP relay and removes from bridge
  - GetNetworkInfo RPC: returns bridge and container attachment info
  - Files: `helpervm/control-api/server.go`

#### Task 4: Update ContainerManager for Network Attachment (Week 9)

- [x] **Implement attachContainerToNetwork (revised implementation)**
  - Allocate IP from IPAM for specified network
  - Generate MAC address (format: `02:XX:XX:XX:XX:XX`)
  - Allocate vsock ports (containerPort, helperPort)
  - Launch arca-tap-forwarder daemon in running container via exec()
  - Send gRPC command to forwarder to create TAP device and configure network
  - Start NetworkBridge relay for packet forwarding
  - Tell helper VM to attach TAP to OVS bridge via gRPC
  - **Change from original design**: No container restart needed! Network attachment is fully dynamic
  - Files: `Sources/ContainerBridge/NetworkBridge.swift`, `NetworkManager.swift`

- [x] **Implement bidirectional packet relay with non-blocking I/O**
  - Use `Task.detached` for independent relay tasks
  - Set vsock FDs to O_NONBLOCK mode with fcntl()
  - Poll loop with EAGAIN/EWOULDBLOCK handling
  - Sleep 1ms when no data available to avoid busy-wait
  - Raw Darwin syscalls (read/write) on Int32 FDs for maximum control
  - **Critical fix**: Swift's cooperative concurrency doesn't work with blocking I/O
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:529-620`

- [x] **Implement container lifecycle with network attachments**
  - On container stop: relay tasks are cancelled automatically (Task cancellation)
  - On container start: networks are re-attached via gRPC
  - arca-tap-forwarder is restarted in container namespace
  - NetworkBridge re-establishes vsock relay connections
  - Maintain same IPs and MACs across restarts via NetworkManager state
  - Files: `Sources/ContainerBridge/NetworkBridge.swift`, `NetworkManager.swift`

#### Task 5: Integration and Testing (Week 10)

- [x] **Test TAP device creation in container**
  - ✅ arca-tap-forwarder successfully creates eth0 TAP device
  - ✅ Interface receives correct IP address (172.18.0.x)
  - ✅ MAC address properly configured
  - ✅ Verified via manual testing with `docker exec`

- [x] **Test vsock relay in Arca daemon**
  - ✅ NetworkBridge successfully accepts connections on allocated ports
  - ✅ Bidirectional relay working after non-blocking I/O fix
  - ✅ Both directions log packet flow (container→helper and helper→container)
  - ✅ Concurrent relays work independently

- [x] **Test helper VM TAP and OVS attachment**
  - ✅ Helper VM creates OVS internal ports (port-<containerID>)
  - ✅ TAP devices attached to correct bridges
  - ✅ Bidirectional packet forwarding confirmed in helper VM logs
  - ✅ OVS bridges correctly configured

- [x] **Test end-to-end container networking**
  - ✅ Network creation: `docker network create test-net`
  - ✅ Container connection: `docker network connect test-net <container>`
  - ✅ Ping to gateway succeeds: `ping 172.18.0.1` (0% packet loss)
  - ✅ Inter-container connectivity verified
  - ✅ Full packet flow confirmed: container → vsock → host → helper VM → OVS → helper VM → host → vsock → container
  - **Performance**: 4-7ms RTT with 1ms polling sleep (room for optimization)

- [x] **Test network attachment/detachment**
  - ✅ Dynamic network attachment working (no container restart needed)
  - Verify connectivity works after restart
  - Detach: `docker network disconnect test-net <container>`
  - Verify container has no network access
  - Files: `scripts/test-network-connect-disconnect.sh`

- [ ] **Performance testing**
  - Benchmark container-to-container throughput with iperf3
  - Measure latency with ping
  - Compare to Docker Desktop performance
  - Document results in NETWORK_ARCHITECTURE.md
  - Files: `scripts/benchmark-network.sh`

#### Task 6: Bug Fixes and Cleanup (Post Phase 3.4)

- [ ] **Fix arca-tap-forwarder-go startup reliability**
  - Problem: Forwarder process starts but doesn't respond to gRPC commands
  - Symptom: Must manually pkill and restart with `docker exec` to work
  - Investigation needed:
    - Check if gRPC server is binding correctly on vsock
    - Verify vsock port allocation is correct
    - Check for race conditions in startup sequence
    - Add health check endpoint to verify forwarder is ready
  - Files: `arca-tap-forwarder-go/main.go`, `Sources/ContainerBridge/NetworkBridge.swift`

- [ ] **Fix duplicate network attachment prevention**
  - Problem: Can attach same network to container multiple times
  - Expected: Docker returns error "container already connected to network"
  - Solution: Check containerNetworks mapping before attachment
  - Return 409 Conflict if already attached
  - Files: `Sources/ContainerBridge/NetworkManager.swift` (attachContainerToNetwork)

- [ ] **Remove obsolete vminit-with-forwarder build**
  - Problem: We no longer need arca-tap-forwarder built into vminit filesystem
  - Cleanup:
    - Remove forwarder from vminit build scripts
    - Rebuild clean vminit image without forwarder
    - Update documentation to reflect new architecture
  - Files: `.build/checkouts/containerization/Makefile`, Documentation

#### Default "bridge" Network

- [x] **Create default bridge network on daemon startup**
  - ✅ Check if "bridge" network exists
  - ✅ If not: create with subnet 172.17.0.0/16, gateway 172.17.0.1
  - ✅ Mark as default network
  - ✅ Already implemented in NetworkManager.initialize()
  - Files: `Sources/ContainerBridge/NetworkManager.swift:90-103`
  - **COMPLETED**: Default bridge network created on daemon startup

- [x] **Implement network auto-attachment for containers**
  - ✅ Store networkMode from HostConfig during container creation
  - ✅ Auto-attach to specified network on container start
  - ✅ Handle "none", "default", "bridge", and custom networks
  - ✅ Skip auto-attach if networks already attached
  - Files: `Sources/ContainerBridge/ContainerManager.swift:628-677`
  - **COMPLETED**: Containers auto-attach based on networkMode
  - Behavior:
    - `docker run alpine` → auto-attaches to "bridge"
    - `docker run --network my-net alpine` → auto-attaches to "my-net"
    - `docker run --network none alpine` → no attachment
    - `docker network connect` → manual attachment works

### Phase 3.5: DNS Resolution (Week 9)

#### DNS Configuration in Helper VM

- [ ] **Configure dnsmasq in helper VM for per-network DNS**
  - Generate dnsmasq config per network
  - Format: /etc/dnsmasq.d/{networkID}.conf
  - Listen on bridge interface (e.g., arca-br-{networkID})
  - Serve DNS from gateway IP (e.g., 172.18.0.1)
  - Add A records for containers: {container-name} → {ip}
  - Support container aliases from EndpointConfig
  - Reload dnsmasq on config changes
  - Files: `helpervm/control-api/dns.go`

- [ ] **Update AttachContainer API to configure DNS**
  - Add container hostname to dnsmasq config
  - Support multiple aliases per container
  - Reload dnsmasq after adding entries
  - Files: `helpervm/control-api/server.go` (AttachContainer handler)

- [ ] **Update DetachContainer API to clean up DNS**
  - Remove container's DNS entries
  - Reload dnsmasq
  - Files: `helpervm/control-api/server.go` (DetachContainer handler)

#### Container DNS Configuration

- [ ] **Configure container /etc/resolv.conf to use network gateway**
  - Set nameserver to network gateway IP (e.g., 172.18.0.1)
  - Use Apple's DNSConfiguration API
  - Apply on container start
  - Files: `Sources/ContainerBridge/ContainerManager.swift`

- [ ] **Test DNS resolution between containers**
  - Integration test: Create two containers on same network
  - From container1: ping container2 by name
  - Verify DNS resolution works
  - Test with aliases
  - Files: `Tests/ArcaTests/NetworkDNSTests.swift`

### Phase 3.6: Docker Compose Integration (Week 10)

#### Compose Network Features

- [ ] **Test multi-container Compose file with custom network**
  - Create sample docker-compose.yml with custom network
  - Define multiple services on same network
  - Test service-to-service DNS resolution
  - Files: `tests/compose/simple-web-redis/docker-compose.yml`

- [ ] **Test Compose with multiple networks**
  - Frontend network + backend network
  - Web service on frontend network
  - API service on both networks
  - Database service on backend network only
  - Verify network isolation
  - Files: `tests/compose/multi-network/docker-compose.yml`

- [ ] **Test Compose network aliases**
  - Define service with multiple aliases
  - Verify all aliases resolve to same IP
  - Test from another container on same network
  - Files: `tests/compose/aliases/docker-compose.yml`

#### Docker Compose Compatibility Testing

- [ ] **Test WordPress + MySQL Compose stack**
  - Use official WordPress Compose example
  - Verify database connectivity via network
  - Verify WordPress can connect to MySQL by service name
  - Test volume persistence for MySQL data
  - Files: `tests/compose/wordpress/docker-compose.yml`

- [ ] **Test web app + Redis Compose stack**
  - Simple web app that connects to Redis by name
  - Verify Redis connection works
  - Test scaling web app (multiple containers on same network)
  - Files: `tests/compose/web-redis/docker-compose.yml`

- [ ] **Create comprehensive Compose compatibility test script**
  - Test docker compose up -d
  - Test docker compose ps
  - Test docker compose logs
  - Test docker compose exec
  - Test docker compose down
  - Verify all compose.yml files work correctly
  - Files: `scripts/test-compose.sh`

### Phase 3.7: Volumes (Week 11)

**Note**: Volumes are simpler than networks and build on existing Apple Containerization volume support.

#### Volume API Models

- [ ] **Create Docker Volume API request/response models**
  - VolumeCreateRequest (Name, Driver, DriverOpts, Labels)
  - Volume (Name, Driver, Mountpoint, Labels, Scope, CreatedAt)
  - VolumeListResponse (Volumes, Warnings)
  - VolumePruneResponse (VolumesDeleted, SpaceReclaimed)
  - Files: `Sources/DockerAPI/Models/Volume.swift`

#### VolumeManager Actor

- [ ] **Implement VolumeManager actor**
  - Track named volumes: [name: VolumeMetadata]
  - Store volumes in `~/.arca/volumes/`
  - Support "local" driver only (store on host filesystem)
  - Integrate with Apple's Containerization volume support
  - Files: `Sources/ContainerBridge/VolumeManager.swift`

- [ ] **Implement volume creation**
  - Create directory under `~/.arca/volumes/{name}/`
  - Store volume metadata (name, driver, labels, created date)
  - Return Volume response
  - Files: `Sources/ContainerBridge/VolumeManager.swift` (createVolume method)

- [ ] **Implement volume listing and inspection**
  - listVolumes(filters:) - Support filters: name, label, dangling
  - inspectVolume(name:) - Return full volume details
  - Calculate volume size (du -sh)
  - Files: `Sources/ContainerBridge/VolumeManager.swift`

- [ ] **Implement volume deletion**
  - Verify no containers are using volume
  - Delete volume directory
  - Remove metadata
  - Error handling: 409 if in use, 404 if not found
  - Files: `Sources/ContainerBridge/VolumeManager.swift` (deleteVolume method)

- [ ] **Implement volume pruning**
  - Find dangling volumes (not referenced by any container)
  - Delete dangling volumes
  - Calculate space reclaimed
  - Files: `Sources/ContainerBridge/VolumeManager.swift` (pruneVolumes method)

#### Volume API Endpoints

- [ ] **POST /volumes/create - Create volume**
  - Parse VolumeCreateRequest
  - Validate driver (only "local" supported)
  - Call volumeManager.createVolume()
  - Return Volume response
  - Files: `Sources/DockerAPI/Handlers/VolumeHandlers.swift`

- [ ] **GET /volumes - List volumes**
  - Parse filters query parameter
  - Call volumeManager.listVolumes(filters:)
  - Return VolumeListResponse
  - Files: `Sources/DockerAPI/Handlers/VolumeHandlers.swift`

- [ ] **GET /volumes/{name} - Inspect volume**
  - Parse volume name
  - Call volumeManager.inspectVolume()
  - Return Volume object
  - Error handling: 404 if not found
  - Files: `Sources/DockerAPI/Handlers/VolumeHandlers.swift`

- [ ] **DELETE /volumes/{name} - Delete volume**
  - Parse volume name and force parameter
  - Call volumeManager.deleteVolume(force:)
  - Return 204 No Content on success
  - Error handling: 404 if not found, 409 if in use
  - Files: `Sources/DockerAPI/Handlers/VolumeHandlers.swift`

- [ ] **POST /volumes/prune - Prune volumes**
  - Parse filters query parameter
  - Call volumeManager.pruneVolumes(filters:)
  - Return VolumePruneResponse
  - Files: `Sources/DockerAPI/Handlers/VolumeHandlers.swift`

- [ ] **Register volume routes in ArcaDaemon**
  - POST /volumes/create → handleCreateVolume
  - GET /volumes → handleListVolumes
  - GET /volumes/{name} → handleInspectVolume
  - DELETE /volumes/{name} → handleDeleteVolume
  - POST /volumes/prune → handlePruneVolumes
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift`

#### Container-Volume Integration

- [ ] **Update ContainerManager to support volume mounts**
  - Parse Mounts and Volumes from ContainerCreateRequest
  - Resolve named volumes via VolumeManager
  - Create anonymous volumes for undefined names
  - Build VZVirtioFileSystemDeviceConfiguration for each mount
  - Handle VirtioFS limitations (document read-only workarounds if needed)
  - Files: `Sources/ContainerBridge/ContainerManager.swift`

- [ ] **Test volume persistence across container restarts**
  - Create container with volume
  - Write data to volume
  - Stop and remove container
  - Create new container with same volume
  - Verify data persists
  - Files: `Tests/ArcaTests/VolumePersistenceTests.swift`

### Phase 3.8: Testing and Polish (Week 12)

#### Comprehensive Testing

- [ ] **Create Phase 3 test script for networks**
  - Test all network CRUD operations
  - Test container connectivity on custom networks
  - Test DNS resolution by container name
  - Test network isolation (containers on different networks can't communicate)
  - Test network connect/disconnect
  - Test with short network IDs
  - Files: `scripts/test-phase3-networks.sh`

- [ ] **Create Phase 3 test script for volumes**
  - Test volume creation, listing, inspection, deletion
  - Test volume mounts in containers
  - Test volume persistence across container restarts
  - Test volume pruning
  - Test anonymous volumes
  - Files: `scripts/test-phase3-volumes.sh`

- [ ] **Run full Docker Compose compatibility suite**
  - WordPress + MySQL
  - Multi-tier web app (frontend, backend, database on different networks)
  - App with persistent volumes
  - Test docker compose up/down/restart
  - Test docker compose logs -f
  - Verify all scenarios work correctly
  - Files: `scripts/test-compose-full.sh`

#### Documentation

- [ ] **Update LIMITATIONS.md with network limitations**
  - Document MacVLAN/IPVLAN not supported
  - Document hot-plug limitation (container restart required for network connect)
  - Document performance overhead (10-15% vs native)
  - Document helper VM resource usage (128MB RAM, 1 CPU)
  - Files: `Documentation/LIMITATIONS.md`

- [ ] **Update API_COVERAGE.md with Phase 3 endpoints**
  - Mark all network endpoints as implemented
  - Mark all volume endpoints as implemented
  - Update coverage percentage
  - Files: `Documentation/API_COVERAGE.md`

- [ ] **Create COMPOSE_COMPATIBILITY.md**
  - Document which Compose features are supported
  - List tested Compose files
  - Provide migration examples from Docker Desktop
  - Document any Compose-specific limitations
  - Files: `Documentation/COMPOSE_COMPATIBILITY.md`

#### Performance Testing

- [ ] **Benchmark container-to-container network throughput**
  - Use iperf3 between containers on same network
  - Compare to Docker Desktop
  - Document results in NETWORK_ARCHITECTURE.md
  - Files: `scripts/benchmark-network.sh`

- [ ] **Benchmark DNS resolution latency**
  - Measure time to resolve container names
  - Compare to Docker Desktop
  - Document results
  - Files: `scripts/benchmark-dns.sh`

- [ ] **Benchmark helper VM overhead**
  - Measure memory usage of helper VM under load
  - Measure CPU usage during high network traffic
  - Document resource usage in NETWORK_ARCHITECTURE.md
  - Files: `scripts/benchmark-helpervm.sh`

#### Error Handling and Edge Cases

- [ ] **Test helper VM failure recovery**
  - Kill helper VM process
  - Verify NetworkHelperVM detects failure
  - Verify automatic restart
  - Verify network state restoration
  - Files: `Tests/ArcaTests/HelperVMRecoveryTests.swift`

- [ ] **Test network operations with stopped containers**
  - Connect/disconnect network from stopped container
  - Verify changes apply when container starts
  - Files: `Tests/ArcaTests/NetworkEdgeCasesTests.swift`

- [ ] **Test IPAM edge cases**
  - Subnet exhaustion (all IPs allocated)
  - IP address conflicts
  - Invalid CIDR notation
  - Overlapping subnets
  - Files: `Tests/ArcaTests/IPAMEdgeCasesTests.swift`

- [ ] **Test volume edge cases**
  - Volume name conflicts
  - Deleting volume while container is using it
  - Invalid volume names
  - Volume directory permission issues
  - Files: `Tests/ArcaTests/VolumeEdgeCasesTests.swift`

### Success Criteria ✅
```bash
# Network operations work:
docker network create my-network                    # Creates network
docker network ls | grep my-network                 # Lists network
docker network inspect my-network                   # Shows details
docker run -d --name web --network my-network nginx # Container on network
docker run -d --name app --network my-network alpine # Second container
docker exec web ping -c 1 app                       # DNS resolution works
docker network disconnect my-network web            # Disconnect container
docker network rm my-network                        # Delete network

# Volume operations work:
docker volume create my-volume                      # Creates volume
docker volume ls | grep my-volume                   # Lists volume
docker volume inspect my-volume                     # Shows details
docker run -v my-volume:/data alpine sh -c "echo test > /data/file" # Write to volume
docker run -v my-volume:/data alpine cat /data/file # Read from volume (persisted)
docker volume rm my-volume                          # Delete volume

# Docker Compose works:
docker compose up -d                                # Start services
docker compose ps                                   # List services
docker compose logs                                 # View logs
docker compose exec web sh                          # Execute in service
docker compose down                                 # Stop and remove

# Test with production Compose files:
cd tests/compose/wordpress && docker compose up -d  # WordPress + MySQL works
cd tests/compose/web-redis && docker compose up -d  # Web + Redis works
```

### Phase 3 Dependencies

**Required before starting Phase 3**:
- ✅ Phase 2 complete (interactive containers and exec API)
- ✅ Swift gRPC package added to Package.swift
- ✅ Helper VM build infrastructure (Makefile, scripts)

**External dependencies**:
- OVN/OVS packages in Alpine Linux (available via apk)
- dnsmasq (available via apk)
- Go compiler for control API server (can use Docker to build)
- protobuf compiler for gRPC (protoc)

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