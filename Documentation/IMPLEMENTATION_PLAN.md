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

### Phase 3.15: Routing Infrastructure Improvements (Week 2.5) ✅

**Rationale**: Before implementing the Network Management Layer, improve the HTTP routing infrastructure to make endpoint implementation cleaner and more maintainable. This gives us 80% of Vapor's benefits with 5% of the complexity, while maintaining our minimal-dependency philosophy.

**Status**: COMPLETED - All routing infrastructure improvements have been implemented and are in active use.

#### Router DSL Enhancement

- [x] **Add HTTP method convenience methods to Router**
  - Implemented `.get()`, `.post()`, `.put()`, `.delete()`, `.head()` methods ✓
  - Clean syntax: `builder.get("/containers/json") { req in ... }` ✓
  - Replaced verbose `router.register(method: .GET, pattern: ...)` calls ✓
  - Maintains existing route matching and path parameter extraction ✓
  - Files: `Sources/ArcaDaemon/Router.swift:135-157`
  - **COMPLETED**: All HTTP method shortcuts implemented and in use

#### Middleware Pattern

- [x] **Design middleware protocol and pipeline**
  - Created `Middleware` protocol with proper async signature ✓
  - Added middleware chain to Router with `middlewares: [Middleware]` ✓
  - Implemented `builder.use(_ middleware: Middleware)` registration ✓
  - Executes middlewares in order before route handlers via recursive chain ✓
  - Files: `Sources/ArcaDaemon/Middleware.swift:6-36`, `Sources/ArcaDaemon/Router.swift:14,35-47,113-119`
  - **COMPLETED**: Full middleware pipeline with context support

- [x] **Implement APIVersionNormalizer middleware**
  - Moved version normalization to middleware ✓
  - Strips `/v{major}.{minor}` prefix from request path using regex ✓
  - Preserves query parameters during normalization ✓
  - Simplifies router logic and makes version handling explicit ✓
  - Files: `Sources/ArcaDaemon/APIVersionNormalizer.swift`
  - **COMPLETED**: Active middleware handling /v1.51/containers → /containers

- [x] **Implement RequestLogger middleware**
  - Logs incoming requests: method, path, URI ✓
  - Logs response: status code, duration in milliseconds ✓
  - Uses structured logging with Logger metadata ✓
  - Filters log level based on status code (warning for 4xx/5xx) ✓
  - Logs error response bodies at debug level ✓
  - Handles both standard and streaming responses ✓
  - Files: `Sources/ArcaDaemon/RequestLogger.swift`
  - **COMPLETED**: Full request/response logging with timing

#### Request/Response Helpers

- [x] **Add HTTPRequest convenience extensions**
  - `func queryBool(_ key: String, default: Bool = false) -> Bool` - Handles "true"/"1"/"false"/"0" ✓
  - `func queryInt(_ key: String) -> Int?` - Parse integer query params ✓
  - `func queryString(_ key: String) -> String?` - Get string query params ✓
  - `func queryArray(_ key: String) -> [String]?` - Parse comma-separated arrays ✓
  - `func pathParam(_ key: String) -> String?` - Type-safe path parameter access ✓
  - `func requiredPathParam(_ key: String) throws -> String` - Throwing version ✓
  - `func jsonBody<T: Decodable>(_ type: T.Type) throws -> T` - Decode JSON body ✓
  - `func optionalJSONBody<T: Decodable>(_ type: T.Type) -> T?` - Non-throwing variant ✓
  - Additional helpers: `header()`, `hasHeader()`, `contentType`, `isJSON` ✓
  - Files: `Sources/ArcaDaemon/HTTPRequest+Helpers.swift`
  - **COMPLETED**: Comprehensive request parsing utilities

- [x] **Add HTTPResponse convenience static methods**
  - `static func ok<T: Encodable>(_ value: T) -> HTTPResponse` - 200 OK with JSON ✓
  - `static func ok(_ text: String) -> HTTPResponse` - 200 OK with plain text ✓
  - `static func ok() -> HTTPResponse` - 200 OK with no body ✓
  - `static func created<T: Encodable>(_ value: T) -> HTTPResponse` - 201 Created ✓
  - `static func noContent() -> HTTPResponse` - 204 No Content ✓
  - `static func badRequest(_ message: String) -> HTTPResponse` - 400 with error ✓
  - `static func unauthorized(_ message: String) -> HTTPResponse` - 401 ✓
  - `static func forbidden(_ message: String) -> HTTPResponse` - 403 ✓
  - `static func notFound(_ message: String) -> HTTPResponse` - 404 with error ✓
  - `static func notFound(_ resourceType: String, id: String) -> HTTPResponse` - 404 typed ✓
  - `static func conflict(_ message: String) -> HTTPResponse` - 409 with error ✓
  - `static func unprocessableEntity(_ message: String) -> HTTPResponse` - 422 ✓
  - `static func internalServerError(_ message: String) -> HTTPResponse` - 500 ✓
  - `static func internalServerError(_ error: Error) -> HTTPResponse` - 500 from Error ✓
  - `static func notImplemented(_ message: String) -> HTTPResponse` - 501 ✓
  - `static func serviceUnavailable(_ message: String) -> HTTPResponse` - 503 ✓
  - Files: `Sources/DockerAPI/HTTPResponse+Helpers.swift`
  - **COMPLETED**: Full suite of response helpers

#### Refactor Existing Routes

- [x] **Migrate container routes to new DSL**
  - All container endpoints use new `.get()`, `.post()`, `.delete()` methods ✓
  - Uses request helpers: `queryBool()`, `queryInt()`, `queryString()`, `pathParam()` ✓
  - Uses response helpers: `HTTPResponse.ok()`, `notFound()`, `badRequest()`, etc. ✓
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift:246-545`
  - **COMPLETED**: All container routes migrated

- [x] **Migrate image routes to new DSL**
  - All image endpoints converted to new convenience methods ✓
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift:551-638`
  - **COMPLETED**: All image routes migrated

- [x] **Migrate system routes to new DSL**
  - Version, ping, info endpoints using new DSL ✓
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift:220-244`
  - **COMPLETED**: All system routes migrated

- [x] **Migrate network routes to new DSL**
  - All network endpoints use new DSL methods ✓
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift:640-796`
  - **COMPLETED**: All network routes migrated

#### Testing

- [ ] **Unit tests for Router DSL**
  - Test `.get()`, `.post()`, `.put()`, `.delete()` registration
  - Verify route matching with new API
  - Test middleware execution order
  - Files: `Tests/ArcaTests/RouterTests.swift`
  - **TODO**: Unit tests not yet implemented (functionality works in integration)

- [ ] **Unit tests for middleware**
  - Test APIVersionNormalizer strips versions correctly
  - Test RequestLogger logs requests/responses
  - Test middleware chain execution
  - Files: `Tests/ArcaTests/MiddlewareTests.swift`
  - **TODO**: Unit tests not yet implemented (functionality works in production)

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

### Phase 3.2: Network Management Layer (Week 3-4) ✅

**Status**: COMPLETED - Full NetworkManager and IPAM implementation with Docker-compatible networking

#### NetworkManager Actor

- [x] **Implement NetworkManager actor with core state**
  - ✅ Created NetworkMetadata struct (id, name, driver, subnet, gateway, containers, created, options, labels, isDefault)
  - ✅ Maintains networks dictionary: `[String: NetworkMetadata]`
  - ✅ Maintains networksByName mapping: `[String: String]` (name → ID)
  - ✅ Maintains containerNetworks mapping: `[String: Set<String>]` (container → network IDs)
  - ✅ Maintains deviceCounter: `[String: Int]` for eth0, eth1, etc.
  - ✅ Initialize with references to NetworkHelperVM, IPAMAllocator, ContainerManager, NetworkBridge
  - ✅ Full actor isolation with Sendable conformance
  - Files: `Sources/ContainerBridge/NetworkManager.swift:7-80`
  - **COMPLETED**: Thread-safe NetworkManager with complete state tracking

- [x] **Implement network creation logic**
  - ✅ Generates Docker network ID (64-char hex via generateNetworkID)
  - ✅ Validates network name (alphanumeric, hyphens, underscores)
  - ✅ Parses and validates IPAM config (subnet, gateway, IP range)
  - ✅ Auto-allocates subnet from 172.18.0.0/16 - 172.31.0.0/16 if not specified
  - ✅ Calls helperVM.createBridge() via OVNClient to create OVS bridge
  - ✅ Stores NetworkMetadata with all fields
  - ✅ Returns Docker-compatible network response
  - ✅ Handles duplicate name detection
  - Files: `Sources/ContainerBridge/NetworkManager.swift:112-200`
  - **COMPLETED**: Full network creation with IPAM integration

- [x] **Implement network deletion logic**
  - ✅ Verifies network exists (throws networkNotFound)
  - ✅ Checks no containers are attached (or force disconnect if force=true)
  - ✅ Calls helperVM.deleteBridge() via OVNClient
  - ✅ Removes from networks dictionary and networksByName
  - ✅ Cleans up IPAM state via releaseIP
  - ✅ Prevents deletion of default "bridge" network
  - Files: `Sources/ContainerBridge/NetworkManager.swift:201-240`
  - **COMPLETED**: Full network deletion with validation

- [x] **Implement network listing and inspection**
  - ✅ listNetworks(filters:) - Supports filters: name, id, driver
  - ✅ inspectNetwork(id:) - Returns full network details with container info
  - ✅ Translates to Docker API format via NetworkHandlers
  - ✅ Supports lookup by ID or name
  - Files: `Sources/ContainerBridge/NetworkManager.swift:241-275`
  - **COMPLETED**: Full listing and inspection APIs

- [x] **Implement container network connection**
  - ✅ connectContainer(containerID:containerName:networkID:ipv4Address:aliases:)
  - ✅ Prevents duplicate network attachment
  - ✅ Allocates IP via IPAM
  - ✅ Generates MAC address
  - ✅ Assigns device names (eth0, eth1, etc.)
  - ✅ Uses NetworkBridge for TAP-over-vsock attachment
  - ✅ Updates network and container metadata
  - Files: `Sources/ContainerBridge/NetworkManager.swift:276-404`
  - **COMPLETED**: Dynamic network attachment without container restart

- [x] **Implement container network disconnection**
  - ✅ disconnectContainer(containerID:networkID:force:)
  - ✅ Verifies network and container exist
  - ✅ Releases IP via IPAM
  - ✅ Detaches via NetworkBridge
  - ✅ Updates metadata
  - Files: `Sources/ContainerBridge/NetworkManager.swift:405-454`
  - **COMPLETED**: Full disconnection support

#### IPAM (IP Address Management)

- [x] **Create IPAMAllocator actor**
  - ✅ Tracks IP allocations per network: `[networkID: [containerID: ip]]`
  - ✅ Implements allocateIP(networkID:subnet:preferredIP:) ✓
    - ✅ Parses CIDR notation
    - ✅ Reserves .0 (network), .1 (gateway), .255 (broadcast)
    - ✅ Finds next available IP or uses preferredIP if specified
    - ✅ Validates preferredIP is in subnet and not reserved
    - ✅ Returns IP address string
  - ✅ Implements releaseIP(networkID:containerID:) ✓
  - ✅ Handles subnet exhaustion error
  - ✅ Additional methods: trackAllocation, getAllocatedIP
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift`
  - **COMPLETED**: Full IPAM with actor isolation

- [x] **Implement default network subnet allocation**
  - ✅ Docker default: 172.17.0.0/16 for "bridge" network ✓
  - ✅ Custom networks: Auto-allocate from 172.18.0.0/16 - 172.31.0.0/16 ✓
  - ✅ Detects subnet conflicts via allocatedSubnets set ✓
  - ✅ Supports user-specified subnets ✓
  - ✅ calculateGateway() helper for .1 gateway calculation
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift:29-81`
  - **COMPLETED**: Subnet allocation matching Docker behavior

- [ ] **Implement persistent IPAM state**
  - Store allocations in `~/.arca/ipam.json`
  - Load on daemon startup
  - Save on every allocation/release
  - Handle corrupted state file gracefully
  - Files: `Sources/ContainerBridge/IPAMAllocator.swift`, `Sources/ContainerBridge/Config.swift`
  - **TODO**: IPAM state is currently in-memory only (lost on daemon restart)

- [ ] **Test IPAM allocation and persistence**
  - Unit test: Allocate/release IPs
  - Test subnet exhaustion handling
  - Test persistence across restarts
  - Test conflict detection
  - Files: `Tests/ArcaTests/IPAMAllocatorTests.swift`
  - **TODO**: No dedicated IPAM unit tests (works in integration)

### Phase 3.3: Docker Network API Endpoints (Week 5-6) ✅

**Status**: COMPLETED - All Docker Network API endpoints implemented and operational

#### Network API Models

- [x] **Create Docker Network API request/response models**
  - ✅ NetworkCreateRequest (Name, Driver, IPAM, Options, Labels) ✓
  - ✅ NetworkCreateResponse (Id, Warning) ✓
  - ✅ Network (full network object for inspect/list) ✓
  - ✅ NetworkConnectRequest (Container, EndpointConfig) ✓
  - ✅ NetworkDisconnectRequest (Container, Force) ✓
  - ✅ IPAM structs (Config, Address) ✓
  - ✅ NetworkContainer (container info in network inspect) ✓
  - ✅ EndpointIPAMConfig, EndpointSettings ✓
  - Files: `Sources/DockerAPI/Models/Network.swift`
  - **COMPLETED**: Complete Docker Network API model coverage

- [x] **Create NetworkHandlers**
  - ✅ Implements handler methods returning HTTPResponseType ✓
  - ✅ Wires up NetworkManager calls ✓
  - ✅ Handles errors and translates to HTTP status codes ✓
  - ✅ Converts NetworkMetadata to Docker API format ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`
  - **COMPLETED**: Full handlers with error translation

#### Network Endpoints

- [x] **POST /networks/create - Create network**
  - ✅ Parses NetworkCreateRequest from body ✓
  - ✅ Validates driver (supports "bridge", rejects unsupported) ✓
  - ✅ Extracts IPAM config (subnet, gateway, IP range) ✓
  - ✅ Calls networkManager.createNetwork() ✓
  - ✅ Returns NetworkCreateResponse with ID ✓
  - ✅ Error handling: 400 for invalid config, 409 for duplicate name, 500 for internal errors ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:90-135`, `Sources/ArcaDaemon/ArcaDaemon.swift:675-695`
  - **COMPLETED**: Full create network endpoint

- [x] **GET /networks - List networks**
  - ✅ Parses filters query parameter (JSON object: {"name": {"my-net": true}}) ✓
  - ✅ Supports filters: name, id, driver ✓
  - ✅ Calls networkManager.listNetworks(filters:) ✓
  - ✅ Returns array of Network objects ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:29-51`, `Sources/ArcaDaemon/ArcaDaemon.swift:640-655`
  - **COMPLETED**: Full list networks endpoint

- [x] **GET /networks/{id} - Inspect network**
  - ✅ Parses network ID or name from path ✓
  - ✅ Supports lookup by ID or name (NetworkManager resolves) ✓
  - ✅ Calls networkManager.inspectNetwork() ✓
  - ✅ Returns Network object with full details including containers ✓
  - ✅ Error handling: 404 if not found ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:55-86`, `Sources/ArcaDaemon/ArcaDaemon.swift:657-673`
  - **COMPLETED**: Full inspect network endpoint

- [x] **DELETE /networks/{id} - Delete network**
  - ✅ Parses network ID or name ✓
  - ✅ Parses force query parameter ✓
  - ✅ Calls networkManager.deleteNetwork(force:) ✓
  - ✅ Returns 204 No Content on success ✓
  - ✅ Error handling: 404 if not found, 409 if containers attached and !force ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:137-167`, `Sources/ArcaDaemon/ArcaDaemon.swift:697-717`
  - **COMPLETED**: Full delete network endpoint

- [x] **POST /networks/{id}/connect - Connect container**
  - ✅ Parses network ID and NetworkConnectRequest body ✓
  - ✅ Resolves container ID from name or ID ✓
  - ✅ Extracts EndpointConfig (IPv4Address, Aliases) ✓
  - ✅ Allocates IP (uses specified or auto-allocates) ✓
  - ✅ Generates MAC address ✓
  - ✅ Calls networkManager.connectContainer() ✓
  - ✅ Dynamic attachment via TAP-over-vsock (no container restart!) ✓
  - ✅ Updates network and container metadata ✓
  - ✅ Error handling: 404 if network/container not found, 409 if already connected ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:169-243`, `Sources/ArcaDaemon/ArcaDaemon.swift:719-756`
  - **COMPLETED**: Full connect endpoint with hot-plug support

- [x] **POST /networks/{id}/disconnect - Disconnect container**
  - ✅ Parses network ID and NetworkDisconnectRequest body ✓
  - ✅ Resolves container ID ✓
  - ✅ Parses force parameter ✓
  - ✅ Calls networkManager.disconnectContainer(force:) ✓
  - ✅ Removes TAP device and releases resources ✓
  - ✅ Returns 204 No Content on success ✓
  - ✅ Updates network and container metadata ✓
  - ✅ Error handling: 404 if not found, 409 if not connected ✓
  - Files: `Sources/DockerAPI/Handlers/NetworkHandlers.swift:245-278`, `Sources/ArcaDaemon/ArcaDaemon.swift:758-794`
  - **COMPLETED**: Full disconnect endpoint

- [x] **Register network routes in ArcaDaemon**
  - ✅ POST /networks/create → handleCreateNetwork ✓
  - ✅ GET /networks → handleListNetworks ✓
  - ✅ GET /networks/{id} → handleInspectNetwork ✓
  - ✅ DELETE /networks/{id} → handleDeleteNetwork ✓
  - ✅ POST /networks/{id}/connect → handleConnectNetwork ✓
  - ✅ POST /networks/{id}/disconnect → handleDisconnectNetwork ✓
  - Files: `Sources/ArcaDaemon/ArcaDaemon.swift:637-794`
  - **COMPLETED**: All network routes registered and tested

### Phase 3.4: TAP-over-vsock Container Network Integration (Week 7-10) ✅

**Architecture**: Implement TAP devices in containers forwarded over vsock to helper VM for OVS bridge attachment. The arca-tap-forwarder binary is bind-mounted into containers and launched on-demand when containers connect to networks.

**Reference**: See `Documentation/NETWORK_ARCHITECTURE.md` for complete TAP-over-vsock design.

**Status**: COMPLETED - Full TAP-over-vsock networking with bidirectional packet forwarding and dynamic attachment

#### Task 1: Implement arca-tap-forwarder Binary (Week 7) ✅

- [x] **Create standalone arca-tap-forwarder Go implementation**
  - ✅ **Architecture change**: Switched from Swift to Go for better Linux compatibility
  - ✅ Independent Go binary built for Linux (cross-compiled)
  - ✅ gRPC server for receiving network configuration via vsock
  - ✅ TAP device creation using netlink (github.com/vishvananda/netlink)
  - ✅ Configured as TAP mode (IFF_TAP | IFF_NO_PI)
  - ✅ vsock connection to Arca daemon (host) for packet forwarding
  - ✅ Bidirectional forwarding: TAP ↔ vsock
  - ✅ Frame-based forwarding with length prefixes (4-byte header)
  - Files: `arca-tap-forwarder-go/cmd/arca-tap-forwarder/main.go`, `arca-tap-forwarder-go/internal/tap/tap.go`, `arca-tap-forwarder-go/internal/forwarder/forwarder.go`
  - **COMPLETED**: Go-based forwarder with gRPC control API

- [x] **Build and install arca-tap-forwarder**
  - ✅ Cross-compile with Go for linux/arm64
  - ✅ Static linking for Alpine Linux compatibility
  - ✅ Installed to `~/.arca/bin/arca-tap-forwarder` (14MB binary)
  - ✅ Build script: `scripts/build-tap-forwarder-go.sh`
  - ✅ Makefile target: `make tap-forwarder`
  - **COMPLETED**: Binary builds and deploys successfully

- [x] **Inject binary into containers via bind mount**
  - ✅ ContainerManager bind-mounts `~/.arca/bin/` directory → `/.arca/bin/` in container
  - ✅ Binary accessible at `/.arca/bin/arca-tap-forwarder`
  - ✅ Hidden dotfile directory minimizes user visibility
  - ✅ Read-only mount (virtiofs share with "ro" option)
  - ✅ Only mounted if directory exists
  - Files: `Sources/ContainerBridge/ContainerManager.swift:313-334`
  - **COMPLETED**: Bind mount working reliably

- [x] **Launch forwarder on-demand via container.exec()**
  - ✅ NetworkBridge.ensureTAPForwarderRunning() launches binary when needed
  - ✅ Executes `/.arca/bin/arca-tap-forwarder` in container namespace
  - ✅ Uses standard container.exec() API (runs in container namespace)
  - ✅ Process tracked in runningForwarders map for lifecycle management
  - ✅ Automatic cleanup when container stops
  - ✅ **Fix applied**: Added retry logic with exponential backoff for startup (TAPForwarderClient)
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:62-89`, `Sources/ContainerBridge/TAPForwarderClient.swift:43-109`
  - **COMPLETED**: Reliable on-demand launch with startup retry

#### Task 2: Implement NetworkBridge in Arca Daemon (Week 7-8) ✅

- [x] **Create NetworkBridge actor**
  - ✅ Tracks network attachments: `[containerID: [networkID: NetworkAttachment]]`
  - ✅ Tracks running forwarders: `[containerID: LinuxProcess]`
  - ✅ Manages port allocation via PortAllocator (base: 20000)
  - ✅ Implements `attachContainer()` to launch forwarder and configure network
  - ✅ Implements `detachContainer()` to cleanup network attachment
  - ✅ Handles relay task lifecycle with Task.detached
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:11-28`
  - **COMPLETED**: Full NetworkBridge actor with lifecycle management

- [x] **Implement port allocation**
  - ✅ PortAllocator class for vsock port management
  - ✅ Base port 20000, allocates sequentially
  - ✅ Helper VM uses +10000 offset (containerPort 20000 → helperPort 30000)
  - ✅ Tracks allocated ports in PortAllocator.allocatedPorts set
  - ✅ Methods: allocate(), release()
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:32-58`
  - **COMPLETED**: Port allocation with proper cleanup

- [x] **Integrate NetworkBridge with NetworkManager**
  - ✅ NetworkManager uses NetworkBridge for container attachments
  - ✅ Calls `networkBridge.attachContainer()` when connecting to network
  - ✅ Passes container LinuxContainer, network/container metadata, IP, MAC, device name
  - ✅ Allocates vsock port for TAP-over-vsock relay
  - ✅ Communicates with arca-tap-forwarder via TAPForwarderClient (gRPC)
  - ✅ Sends AttachContainer gRPC request to helper VM with vsock port
  - Files: `Sources/ContainerBridge/NetworkManager.swift:276-404`
  - **COMPLETED**: Full integration with dynamic attachment

#### Task 3: Implement TAP Relay Server for Helper VM (Week 8-9) ✅

- [x] **Create gRPC control API in Go**
  - ✅ NetworkControl protobuf service definition
  - ✅ Implemented in Go for Alpine Linux compatibility
  - ✅ Uses mdlayher/vsock library for vsock listener
  - ✅ Listens on vsock port 9999 for control commands
  - ✅ Methods: CreateBridge, DeleteBridge, AttachContainer, DetachContainer, GetHealth, ListBridges
  - Files: `helpervm/proto/network.proto`, `helpervm/control-api/main.go`
  - **COMPLETED**: Full gRPC control API operational

- [x] **Implement TAPRelayManager for packet forwarding**
  - ✅ Manages active TAP relays: `map[uint32]*TAPRelay`
  - ✅ StartRelay() creates TAP device and starts bidirectional forwarding
  - ✅ StopRelay() cleans up TAP device and closes connections
  - ✅ Each relay listens on helperPort (containerPort + 10000)
  - ✅ Attaches TAP device to OVS bridge via ovs-vsctl add-port
  - ✅ Thread-safe access with mutex protection
  - Files: `helpervm/control-api/tap_relay.go`
  - **COMPLETED**: Full TAP relay management

- [x] **Implement TAP device creation and management**
  - ✅ Creates TAP device using /dev/net/tun (IFF_TAP | IFF_NO_PI)
  - ✅ Unique device names: `port-<containerID>` (MD5 hash prefix for length)
  - ✅ Attaches as OVS port (not internal - uses ovs-vsctl add-port)
  - ✅ Sets MAC address for container interface
  - ✅ Brings interface up with IFF_UP | IFF_RUNNING
  - ✅ Handles cleanup on errors
  - Files: `helpervm/control-api/tap_relay.go`
  - **COMPLETED**: Reliable TAP device management

- [x] **Implement bidirectional packet forwarding**
  - ✅ forwardVsockToTAP(): read from vsock, write to TAP fd
  - ✅ forwardTAPToVsock(): read from TAP fd, write to vsock
  - ✅ Uses goroutines for concurrent forwarding in each direction
  - ✅ Frame-based protocol with 4-byte length prefix
  - ✅ 64KB buffers for frame forwarding
  - ✅ Graceful error handling and connection cleanup
  - ✅ Context cancellation for shutdown
  - Files: `helpervm/control-api/tap_relay.go`
  - **COMPLETED**: Full bidirectional forwarding working

- [x] **Implement gRPC NetworkControl service**
  - ✅ CreateBridge RPC: creates OVS bridge with ovs-vsctl
  - ✅ DeleteBridge RPC: removes OVS bridge and cleans up ports
  - ✅ AttachContainer RPC: starts TAP relay for container, returns bridge name
  - ✅ DetachContainer RPC: stops TAP relay and removes from bridge
  - ✅ GetHealth RPC: returns helper VM health status
  - ✅ ListBridges RPC: lists all OVS bridges
  - ✅ Bridge naming: MD5 hash-based `br-{12 hex chars}` (15 char limit)
  - Files: `helpervm/control-api/server.go`
  - **COMPLETED**: Full gRPC service implementation

#### Task 4: Update ContainerManager for Network Attachment (Week 9) ✅

- [x] **Implement attachContainerToNetwork (revised implementation)**
  - ✅ Allocates IP from IPAM for specified network
  - ✅ Generates MAC address (format: `02:XX:XX:XX:XX:XX`)
  - ✅ Allocates vsock ports (containerPort, helperPort)
  - ✅ Launches arca-tap-forwarder daemon in running container via exec()
  - ✅ Communicates with forwarder via TAPForwarderClient (gRPC over vsock)
  - ✅ Sends ConfigureNetwork command to create TAP device with IP/MAC/gateway
  - ✅ Starts NetworkBridge relay for packet forwarding (Arca daemon → helper VM)
  - ✅ Tells helper VM to attach TAP to OVS bridge via AttachContainer gRPC
  - ✅ **Architecture win**: No container restart needed! Network attachment is fully dynamic
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:103-399`, `NetworkManager.swift:276-404`
  - **COMPLETED**: Full dynamic network attachment implementation

- [x] **Implement bidirectional packet relay with non-blocking I/O**
  - ✅ Uses `Task.detached` for independent relay tasks
  - ✅ Sets vsock FDs to O_NONBLOCK mode with fcntl()
  - ✅ Poll loop with EAGAIN/EWOULDBLOCK handling
  - ✅ Sleeps 1ms when no data available to avoid busy-wait
  - ✅ Raw Darwin syscalls (read/write) on Int32 FDs for maximum control
  - ✅ Frame-based protocol: reads 4-byte length, then frame data
  - ✅ **Critical fix**: Swift's cooperative concurrency doesn't work with blocking I/O
  - ✅ Proper error handling and task cancellation
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:529-620`
  - **COMPLETED**: Non-blocking bidirectional relay working (4-7ms RTT)

- [x] **Implement container lifecycle with network attachments**
  - ✅ On container stop: relay tasks are cancelled automatically (Task cancellation)
  - ✅ On container start: networks are re-attached if previously connected
  - ✅ arca-tap-forwarder is restarted in container namespace
  - ✅ NetworkBridge re-establishes vsock relay connections
  - ✅ Maintains same IPs and MACs across restarts via NetworkManager state
  - ✅ Handles cleanup on errors and container removal
  - Files: `Sources/ContainerBridge/NetworkBridge.swift:401-454`, `NetworkManager.swift:276-404`
  - **COMPLETED**: Full lifecycle management with persistence

#### Task 5: Integration and Testing (Week 10) ✅

- [x] **Test TAP device creation in container**
  - ✅ arca-tap-forwarder successfully creates eth0 TAP device
  - ✅ Interface receives correct IP address (172.18.0.x)
  - ✅ MAC address properly configured
  - ✅ Verified via manual testing with `docker exec`
  - **COMPLETED**: TAP devices working in containers

- [x] **Test vsock relay in Arca daemon**
  - ✅ NetworkBridge successfully accepts connections on allocated ports
  - ✅ Bidirectional relay working after non-blocking I/O fix
  - ✅ Both directions log packet flow (container→helper and helper→container)
  - ✅ Concurrent relays work independently
  - **COMPLETED**: vsock relay fully operational

- [x] **Test helper VM TAP and OVS attachment**
  - ✅ Helper VM creates OVS ports (port-<containerID>)
  - ✅ TAP devices attached to correct bridges
  - ✅ Bidirectional packet forwarding confirmed in helper VM logs
  - ✅ OVS bridges correctly configured
  - **COMPLETED**: Helper VM integration working

- [x] **Test end-to-end container networking**
  - ✅ Network creation: `docker network create test-net`
  - ✅ Container connection: `docker network connect test-net <container>`
  - ✅ Ping to gateway succeeds: `ping 172.18.0.1` (0% packet loss)
  - ✅ Inter-container connectivity verified
  - ✅ Full packet flow confirmed: container → arca-tap-forwarder → vsock → Arca daemon → vsock → helper VM → OVS → helper VM → vsock → Arca daemon → vsock → arca-tap-forwarder → container
  - ✅ **Performance**: 4-7ms RTT with 1ms polling sleep (acceptable for MVP)
  - **COMPLETED**: End-to-end networking fully functional

- [x] **Test network attachment/detachment**
  - ✅ Dynamic network attachment working (no container restart needed)
  - ✅ Connectivity works after container restart (networks re-attached)
  - ✅ Detach: `docker network disconnect test-net <container>` works
  - ✅ Container loses network access after disconnect
  - ✅ Multiple networks per container working (eth0, eth1, etc.)
  - **COMPLETED**: Full attach/detach lifecycle tested

- [ ] **Performance testing**
  - Benchmark container-to-container throughput with iperf3
  - Measure latency with ping
  - Compare to Docker Desktop performance
  - Document results in NETWORK_ARCHITECTURE.md
  - Files: `scripts/benchmark-network.sh`
  - **TODO**: Formal performance benchmarking not yet done

#### Task 6: Bug Fixes and Cleanup (Post Phase 3.4) ✅

- [x] **Fix arca-tap-forwarder-go startup reliability**
  - ✅ **Problem identified**: Race condition - gRPC server not ready when first connection attempted
  - ✅ **Solution implemented**: Added retry loop with exponential backoff in TAPForwarderClient
  - ✅ Retry parameters: 50ms → 3s backoff, max 10 attempts
  - ✅ Forwarder now reliably responds on 2nd-3rd connection attempt
  - Files: `Sources/ContainerBridge/TAPForwarderClient.swift:43-109`
  - **COMPLETED**: Startup reliability fixed

- [x] **Fix duplicate network attachment prevention**
  - ✅ **Already implemented**: NetworkManager checks containerNetworks before attachment
  - ✅ Returns 409 Conflict if already attached
  - ✅ Verified via NetworkManager.connectContainer() line 293-296
  - Files: `Sources/ContainerBridge/NetworkManager.swift:293-296`
  - **COMPLETED**: Duplicate attachment prevention working

- [x] **Remove obsolete vminit-with-forwarder build**
  - ✅ Removed old Swift-based arca-tap-forwarder directory
  - ✅ Removed obsolete build scripts (build-vminit.sh, generate-tap-forwarder-grpc.sh)
  - ✅ Removed .arca-build directory with old binary
  - **COMPLETED**: Cleaned up obsolete Swift forwarder artifacts
  - New architecture: Go-based arca-tap-forwarder-go injected via bind mount

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

### Phase 3.5: DNS Resolution (Week 9) ✅ COMPLETE

#### DNS Configuration in Helper VM

- [x] **Configure dnsmasq in helper VM for per-network DNS**
  - ✅ Generate dnsmasq config per network (`/etc/dnsmasq.d/network-{networkID}.conf`)
  - ✅ Serve DNS from gateway IP (e.g., 172.18.0.1)
  - ✅ Add A records for containers: {container-name} → {ip}
  - ✅ Support container aliases from EndpointConfig
  - ✅ Restart dnsmasq on config changes (SIGHUP doesn't work reliably)
  - ✅ Added `domain-needed` and `bogus-priv` to prevent forwarding simple hostnames
  - ✅ Disabled hardware offloading on OVS bridges for userspace datapath compatibility
  - Files: `helpervm/control-api/server.go`, `helpervm/config/dnsmasq.conf`

- [x] **Update AttachContainer API to configure DNS**
  - ✅ Add container hostname to dnsmasq config via `configureDNS()`
  - ✅ Support multiple aliases per container
  - ✅ Track DNS entries in `dnsEntries` map per network
  - ✅ Restart dnsmasq after adding entries
  - Files: `helpervm/control-api/server.go` (AttachContainer handler, configureDNS, writeDnsmasqConfig)

- [x] **Update DetachContainer API to clean up DNS**
  - ✅ Remove container's DNS entries from `dnsEntries` map
  - ✅ Regenerate dnsmasq config without removed entries
  - ✅ Restart dnsmasq to apply changes
  - Files: `helpervm/control-api/server.go` (DetachContainer handler, removeDNS)

#### Container DNS Configuration

- [x] **Configure container /etc/resolv.conf to use network gateway**
  - ✅ Set nameserver to network gateway IP (e.g., 172.18.0.1)
  - ✅ Implemented in arca-tap-forwarder's `configureDNS()` function
  - ✅ Applied on first network attachment (eth0) using `os.WriteFile()`
  - Files: `arca-tap-forwarder-go/internal/forwarder/forwarder.go`

- [x] **Test DNS resolution between containers**
  - ✅ Manual testing: DNS resolution works via `nslookup`
  - ✅ Manual testing: Ping by container name works
  - ✅ Verified: `nslookup container1` returns `172.18.0.2`
  - ✅ Verified: `ping container1` successfully pings by name
  - TODO: Automated integration test in `Tests/ArcaTests/NetworkDNSTests.swift`

**Key Implementation Details:**
- dnsmasq must be **restarted** (not reloaded with SIGHUP) to pick up new `listen-address` directives
- Hardware offloading must be disabled on OVS bridges (`ethtool -K` commands) for userspace datapath
- `domain-needed` flag prevents dnsmasq from trying to forward simple hostnames to non-existent upstream servers
- DNS entries tracked in structured `DNSEntry` type with containerID, hostname, IP, and aliases
- Per-network dnsmasq configs written to `/etc/dnsmasq.d/network-{networkID[:12]}.conf`

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

### Phase 3.5.5: VLAN + Router for Bridge Networks 🚧 IN PROGRESS

**Rationale**: Implement native vmnet performance for bridge networks using VLAN tagging and simple Linux routing, while preserving OVS/OVN for future overlay network support. This provides 5-10x performance improvement for 95% of use cases.

**Architecture**: See `Documentation/VLAN_ROUTER_ARCHITECTURE.md` for complete design.

**Status**: PLANNING - Architecture documented, vminitd fork created as submodule

#### vminitd Extensions

- [ ] **Create vlan-service directory structure**
  - Create `vminitd/extensions/vlan-service/` directory
  - Create `proto/network.proto` with VLAN gRPC service definitions
  - Define NetworkConfig service with CreateVLAN, DeleteVLAN, ConfigureIP, AddRoute RPCs
  - Files: `vminitd/extensions/vlan-service/proto/network.proto`

- [ ] **Implement VLAN service using netlink**
  - Implement CreateVLAN RPC handler using vishvananda/netlink library
  - Create VLAN subinterfaces (eth0.100, eth0.200, etc.)
  - Configure IP addresses via netlink.AddrAdd
  - Bring interfaces up via netlink.LinkSetUp
  - Add routes via netlink.RouteAdd
  - Files: `vminitd/extensions/vlan-service/server.go`, `vminitd/extensions/vlan-service/vlan.go`

- [ ] **Integrate VLAN service with vminitd**
  - Modify vminitd startup to launch VLAN gRPC service
  - Ensure service listens on vsock (compatible with Container.dial())
  - Add proper error handling and logging
  - Files: `vminitd/vminitd/Sources/vminitd/main.swift` (or equivalent integration point)

- [ ] **Build custom vminit:latest OCI image**
  - Update vminitd build scripts to include VLAN service
  - Cross-compile VLAN service for Linux ARM64
  - Package into vminit:latest OCI image
  - Test image with Containerization framework
  - Files: `vminitd/scripts/build-vminit.sh`, `vminitd/Makefile`

#### Helper VM Router Service

- [ ] **Create router-service directory structure**
  - Create `helpervm/router-service/` directory
  - Define RouterService gRPC API in `helpervm/proto/router.proto`
  - Define CreateVLAN, DeleteVLAN, ConfigureNAT, ConfigureDNS RPCs
  - Files: `helpervm/proto/router.proto`, `helpervm/router-service/main.go`

- [ ] **Implement RouterService gRPC server**
  - Implement CreateVLAN handler (creates eth0.X on helper VM)
  - Implement DeleteVLAN handler (removes eth0.X)
  - Implement ConfigureNAT handler (iptables MASQUERADE rules)
  - Implement ConfigureDNS handler (dnsmasq per-VLAN configuration)
  - Use netlink library for VLAN interface management
  - Files: `helpervm/router-service/server.go`, `helpervm/router-service/router.go`

- [ ] **Update helper VM Dockerfile**
  - Add router-service binary to helper VM image
  - Update startup.sh to start router-service alongside OVS
  - Configure iptables for routing and NAT
  - Enable IP forwarding in kernel
  - Files: `helpervm/Dockerfile`, `helpervm/scripts/startup.sh`

- [ ] **Test router service in helper VM**
  - Launch helper VM with router service
  - Test VLAN creation via gRPC
  - Verify eth0.100, eth0.200 interfaces created
  - Test NAT configuration with iptables
  - Test routing between VLANs
  - Files: `tests/router-service-test.sh`

#### Arca Daemon Integration

- [ ] **Create VLANNetworkProvider**
  - Implement NetworkProvider protocol for VLAN-based networking
  - Create VLANNetworkProvider.swift
  - Implement createNetwork() to allocate VLAN ID and create VLAN on helper VM
  - Implement deleteNetwork() to clean up VLAN
  - Implement connectContainer() to create VLAN subinterface in container
  - Implement disconnectContainer() to remove VLAN subinterface
  - Files: `Sources/ContainerBridge/VLANNetworkProvider.swift`

- [ ] **Create RouterClient for helper VM communication**
  - Implement RouterClient.swift for gRPC communication with helper VM router service
  - Use Container.dial() for vsock communication
  - Implement createVLAN(), deleteVLAN(), configureNAT(), configureDNS() methods
  - Handle connection failures and retries
  - Files: `Sources/ContainerBridge/RouterClient.swift`

- [ ] **Create NetworkConfigClient for vminitd communication**
  - Implement NetworkConfigClient.swift for gRPC communication with vminitd
  - Use Container.dial() for vsock communication to container VMs
  - Implement createVLAN(), deleteVLAN(), configureIP(), addRoute() methods
  - Handle distroless containers gracefully
  - Files: `Sources/ContainerBridge/NetworkConfigClient.swift`

- [ ] **Implement VLAN ID allocator**
  - Create VLANAllocator actor
  - Manage VLAN ID allocation (100-4094 range)
  - Track allocated VLAN IDs per network
  - Handle VLAN ID release on network deletion
  - Files: `Sources/ContainerBridge/VLANAllocator.swift`

- [ ] **Update NetworkManager to route by driver**
  - Modify createNetwork() to select provider based on driver
  - Route "bridge" driver to VLANNetworkProvider
  - Route "overlay" driver to OVSNetworkProvider (existing)
  - Maintain backward compatibility with existing networks
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

- [ ] **Update container connection logic**
  - Modify connectContainerToNetwork() to use provider pattern
  - Call VLANNetworkProvider.connectContainer() for bridge networks
  - Call OVSNetworkProvider.connectContainer() for overlay networks
  - Handle VLAN subinterface creation in container VMs
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

- [ ] **Implement network disconnect support**
  - Add disconnectContainerFromNetwork() method
  - Remove VLAN subinterfaces from container VMs
  - Update container network state
  - Handle graceful cleanup on errors
  - Files: `Sources/ContainerBridge/NetworkManager.swift`

#### Testing

- [ ] **Test VLAN network creation**
  - Create bridge network via Docker API
  - Verify VLAN ID allocated
  - Verify helper VM VLAN interface created (eth0.X)
  - Verify NAT rules configured
  - Files: `tests/test-vlan-network-create.sh`

- [ ] **Test container connection to VLAN network**
  - Create container and connect to VLAN network
  - Verify VLAN subinterface created in container (eth0.X)
  - Verify IP address configured
  - Verify routing table includes gateway
  - Test connectivity to helper VM gateway
  - Files: `tests/test-vlan-container-connect.sh`

- [ ] **Test inter-container communication (same network)**
  - Create two containers on same VLAN network
  - Verify containers can ping each other
  - Verify low latency (<1ms)
  - Measure throughput (expect >1 Gbps)
  - Files: `tests/test-vlan-inter-container.sh`

- [ ] **Test network isolation (different networks)**
  - Create two VLAN networks (VLAN 100, VLAN 200)
  - Create containers on each network
  - Verify containers on different VLANs cannot communicate
  - Verify L2 isolation works correctly
  - Files: `tests/test-vlan-isolation.sh`

- [ ] **Test distroless container support**
  - Create distroless container (gcr.io/distroless/static)
  - Connect to VLAN network
  - Verify VLAN created via vminitd gRPC (no shell needed)
  - Verify networking works
  - Files: `tests/test-vlan-distroless.sh`

- [ ] **Test port mapping**
  - Create container with port mapping (-p 8080:80)
  - Verify iptables DNAT rule on helper VM
  - Test external connectivity to mapped port
  - Files: `tests/test-vlan-port-mapping.sh`

- [ ] **Test DNS resolution**
  - Create network with custom DNS
  - Verify dnsmasq configured per-VLAN
  - Test container name resolution
  - Test internet DNS resolution
  - Files: `tests/test-vlan-dns.sh`

- [ ] **Performance benchmarks**
  - Benchmark VLAN latency vs TAP-over-vsock
  - Benchmark VLAN throughput vs TAP-over-vsock
  - Document performance improvements
  - Files: `tests/benchmark-vlan-vs-tap.sh`, `Documentation/PERFORMANCE.md`

#### Documentation

- [ ] **Update CLAUDE.md with VLAN architecture**
  - Document dual architecture (VLAN for bridge, OVS for overlay)
  - Explain when each is used
  - Document VLAN ID allocation
  - Provide troubleshooting guide
  - Files: `CLAUDE.md`

- [ ] **Create user guide for VLAN networking**
  - Document bridge network creation
  - Explain VLAN limitations (4094 networks max)
  - Provide examples and best practices
  - Document performance characteristics
  - Files: `Documentation/VLAN_USER_GUIDE.md`

- [ ] **Document distroless container support**
  - Explain vminitd gRPC approach
  - Provide distroless container examples
  - Document limitations and workarounds
  - Files: `Documentation/DISTROLESS_SUPPORT.md`

#### Success Criteria

- ✅ Bridge networks use VLAN + Router (not OVS)
- ✅ 5-10x latency improvement over TAP-over-vsock
- ✅ 5x throughput improvement over TAP-over-vsock
- ✅ 90% reduction in helper VM memory usage (for bridge networks)
- ✅ Distroless containers fully supported
- ✅ All Docker bridge network features work
- ✅ OVS path preserved for future overlay networks
- ✅ Comprehensive test coverage

**Expected Outcome**: Native vmnet performance for 95% of use cases (bridge networks) while maintaining OVS for future multi-host overlay support. Clean separation of concerns with provider pattern.

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