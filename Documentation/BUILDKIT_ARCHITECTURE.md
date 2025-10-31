# BuildKit Architecture - vsock Integration

**Status**: Phase 4 - Build API (IN PROGRESS)

## Overview

Arca integrates BuildKit for `docker build` functionality using a **vsock-based architecture** that provides secure, isolated communication without network exposure. BuildKit runs in a dedicated container with NO network access, communicating exclusively via virtio-vsock.

## Architecture

```
Arca Daemon (macOS Host)
  ↓
BuildKitClient (Swift gRPC)
  ↓ container.dialVsock(8088)
virtio-vsock channel
  ↓
BuildKit Container (Linux VM)
  ├─ PID 1: buildkitd (localhost:8088)
  └─ PID 2: vsock-proxy (vsock:8088 → TCP localhost:8088)
```

### Security Model

**Complete Network Isolation**:
- BuildKit container has `networkMode: "none"`
- BuildKit daemon listens ONLY on localhost:8088 (not exposed to any network)
- vsock provides secure, isolated host↔container communication
- Control plane and other containers cannot reach BuildKit

**vsock Communication**:
- Host uses `Container.dialVsock(8088)` to connect to BuildKit
- vsock-proxy inside container forwards to localhost:8088
- No TCP exposure, no network routing required

## Components

### 1. Custom BuildKit Image

**Location**: `buildkit-image/`

**Build**: `make buildkit` creates `~/.arca/buildkit/oci-layout/`

**Dockerfile** (`buildkit-image/Dockerfile`):
```dockerfile
# Multi-stage build: Go builder + moby/buildkit base
FROM golang:1.23-alpine AS proxy-builder
WORKDIR /build
COPY proxy/main.go .
RUN go mod init vsock-proxy && \
    go get github.com/mdlayher/vsock@latest && \
    go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -o vsock-proxy main.go

FROM moby/buildkit:latest
COPY --from=proxy-builder /build/vsock-proxy /usr/local/bin/vsock-proxy
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vsock-proxy
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 2. vsock Proxy

**Location**: `buildkit-image/proxy/main.go`

**Purpose**: Bridges vsock (guest-side) to TCP localhost

**Implementation**:
- Uses `github.com/mdlayher/vsock` library (same as control plane)
- Listens on vsock port 8088
- Forwards to TCP localhost:8088
- Bidirectional io.Copy for full gRPC support
- ~67 lines of Go code

**Key Code**:
```go
import "github.com/mdlayher/vsock"

listener, err := vsock.Listen(8088, nil)  // vsock port 8088
// Accept connections and forward to localhost:8088
```

### 3. Entrypoint Script

**Location**: `buildkit-image/entrypoint.sh`

**Process Management**:
```bash
#!/bin/sh
set -e

# Start vsock-to-TCP proxy in background
/usr/local/bin/vsock-proxy &
PROXY_PID=$!

# Trap signals to ensure proxy is killed when buildkitd exits
trap "kill $PROXY_PID 2>/dev/null || true" EXIT TERM INT

# Wait for proxy to start
sleep 0.5

# Start buildkitd on localhost only (PID 1)
exec /usr/bin/buildkitd --addr tcp://127.0.0.1:8088 "$@"
```

**Process Tree**:
- PID 1: `/usr/bin/buildkitd --addr tcp://127.0.0.1:8088`
- PID 2: `/usr/local/bin/vsock-proxy`

### 4. BuildKitManager (Swift)

**Location**: `Sources/ContainerBuild/BuildKitManager.swift`

**Responsibilities**:
- Ensures BuildKit image exists in ImageStore
- Creates and manages `arca-buildkit` container
- Manages `buildkit-cache` named volume
- Initializes BuildKitClient with vsock connection

**Container Configuration**:
```swift
ContainerCreateRequest(
    image: "arca/buildkit:latest",
    name: "arca-buildkit",
    command: ["/usr/local/bin/entrypoint.sh"],  // Explicit entrypoint
    networkMode: "none",  // NO network access
    restartPolicy: RestartPolicy(name: "always"),
    binds: ["buildkit-cache:/var/lib/buildkit"],
    labels: [
        "com.arca.internal": "true",
        "com.arca.role": "buildkit"
    ]
)
```

**Special Handling**:
- `networkMode: "none"` prevents auto-attachment to bridge network
- Explicit command override required (Apple Containerization doesn't respect image ENTRYPOINT with nil command)
- Hidden from `docker ps` via `com.arca.internal` label
- Restart policy "always" ensures BuildKit survives daemon restarts

### 5. BuildKitClient (Swift)

**Location**: `Sources/ContainerBuild/BuildKitClient.swift`

**gRPC Communication**:
```swift
// Connect via vsock
let connection = try container.dialVsock(8088)
let channel = GRPCChannel(
    customFileDescriptor: connection,
    closeFileDescriptor: true
)

// BuildKit gRPC client
let client = Moby_Buildkit_V1_ControlNIOClient(channel: channel)
```

**Key Methods**:
- `connect()` - Establishes vsock connection with retry logic (10 attempts, exponential backoff)
- `solve()` - Executes builds via BuildKit's Solve RPC
- `disconnect()` - Graceful gRPC channel shutdown

### 6. Daemon Integration

**Location**: `Sources/ArcaDaemon/ArcaDaemon.swift`

**Image Loading**:
- Loads `arca/buildkit:latest` from `~/.arca/buildkit/oci-layout/`
- **Digest-based smart reloading**: Compares manifest digest to avoid unnecessary reloads
- Only reloads image when it actually changes (not on every daemon restart)

**Initialization Flow**:
```
1. Load BuildKit image from OCI layout (if changed)
2. Initialize BuildKitManager
3. BuildKitManager ensures container exists and is running
4. BuildKitClient connects via vsock
5. BuildKit ready for build requests
```

## Build Infrastructure

### Makefile Target

```bash
make buildkit  # Builds arca/buildkit:latest OCI image
```

**Build Script**: `scripts/build-buildkit-image.sh`

**Process**:
1. Builds multi-stage Docker image
2. Exports to OCI layout via skopeo
3. Fixes index.json for Apple Containerization compatibility
4. Installs to `~/.arca/buildkit/oci-layout/`

**Build Time**: ~15 seconds (with cache)

**Image Size**: ~96MB OCI layout

### Directory Structure

```
buildkit-image/
├── Dockerfile           # Multi-stage: Go builder + BuildKit base
├── proxy/
│   └── main.go         # vsock-to-TCP proxy (uses mdlayher/vsock)
├── entrypoint.sh       # Process manager for proxy + buildkitd
└── build.sh            # Helper script (use 'make buildkit' instead)

~/.arca/buildkit/
└── oci-layout/         # OCI image layout for arca/buildkit:latest
    ├── blobs/
    ├── index.json
    └── oci-layout
```

## Connection Flow

### Startup Sequence

1. **Daemon starts** → Loads BuildKit image (if changed)
2. **BuildKitManager.initialize()** → Ensures container exists
3. **Container starts** → Entrypoint launches vsock-proxy + buildkitd
4. **BuildKitClient.connect()** → Retries vsock:8088 connection (10 attempts, exponential backoff)
5. **Connection established** → gRPC channel ready
6. **BuildKit ready** → Log: "BuildKitManager initialized successfully"

### Runtime Communication

```
Docker CLI: docker build
  ↓
/build API endpoint (BuildHandlers.swift)
  ↓
BuildKitClient.solve(definition, frontend, attrs)
  ↓
gRPC over vsock:8088
  ↓
vsock-proxy (PID 2)
  ↓
TCP localhost:8088
  ↓
buildkitd (PID 1)
```

## Implementation Details

### Why vsock Instead of Network?

**Security**:
- No NAT required through control plane
- No TCP exposure on any network
- BuildKit is a privileged system service - should not be network-accessible
- vsock provides kernel-level isolation

**Simplicity**:
- No network configuration needed
- No port conflicts
- Direct host↔container channel
- Works without control plane being up

### Critical Fixes During Implementation

1. **Network Auto-Attachment**:
   - **Problem**: `networkMode: nil` defaulted to "bridge" network
   - **Fix**: Explicit `networkMode: "none"`

2. **vsock Library**:
   - **Problem**: Standard Go `net.Listen("vsock")` doesn't work
   - **Fix**: Use `github.com/mdlayher/vsock` (same as control plane)

3. **ENTRYPOINT Handling**:
   - **Problem**: Apple Containerization doesn't respect image ENTRYPOINT when command is nil
   - **Fix**: Explicit `command: ["/usr/local/bin/entrypoint.sh"]`

4. **Image Loading**:
   - **Problem**: Reloading image on every daemon restart is wasteful
   - **Fix**: Digest-based comparison (only reload when manifest digest changes)

### Connection Retry Logic

**BuildKitClient.connect()** uses exponential backoff:

```
Attempt 1: Immediate
Attempt 2: 1 second delay
Attempt 3: 2 seconds delay
Attempt 4: 4 seconds delay
Attempt 5: 8 seconds delay
Attempt 6-10: 16 seconds delay
```

**Why needed**: buildkitd takes ~1-2 seconds to initialize after container starts

**Success rate**: Typically connects on attempt 2-3 (~1-2 seconds)

## Testing

### Verify Installation

```bash
# Build BuildKit image
make buildkit

# Start daemon
make run

# Check logs for successful initialization
# Look for: "BuildKitManager initialized successfully"

# Verify processes in BuildKit container
DOCKER_HOST=unix:///tmp/arca.sock docker exec arca-buildkit ps aux
# Should show:
# PID 1: /usr/bin/buildkitd --addr tcp://127.0.0.1:8088
# PID 2: /usr/local/bin/vsock-proxy
```

### Check Container Configuration

```bash
DOCKER_HOST=unix:///tmp/arca.sock docker inspect arca-buildkit

# Verify:
# - "NetworkMode": "none"
# - "RestartPolicy": {"Name": "always"}
# - Labels: {"com.arca.internal": "true", "com.arca.role": "buildkit"}
# - Mounts: buildkit-cache → /var/lib/buildkit
```

### Test vsock Connection

BuildKit container logs show vsock connections:

```bash
DOCKER_HOST=unix:///tmp/arca.sock docker logs arca-buildkit

# Expected output:
# Starting vsock proxy on port 8088...
# Starting vsock-to-TCP proxy: vsock:8088 -> 127.0.0.1:8088
# Starting buildkitd on 127.0.0.1:8088...
# Accepted vsock connection from host(2):...
# running server on 127.0.0.1:8088
```

## Performance

- **Connection time**: ~1-2 seconds (2-3 retries)
- **Image size**: 96MB OCI layout
- **Build time**: ~15 seconds (with Docker cache)
- **vsock latency**: Sub-millisecond (local virtio-vsock channel)

## Comparison with Other Approaches

### Rejected: TCP over Bridge Network

**Why NOT used**:
- Requires NAT through control plane (not yet implemented)
- Exposes BuildKit to network (security risk)
- More complex routing
- Couples BuildKit to networking stack

### Rejected: Forking BuildKit for vsock

**Why NOT used**:
- Maintenance burden (tracking upstream changes)
- vsock-proxy approach is simpler
- Transparent to BuildKit (no BuildKit code changes)
- Easier to update BuildKit versions

### Chosen: vsock Proxy

**Advantages**:
- ✅ Simple architecture (~67 lines of Go)
- ✅ No BuildKit modifications
- ✅ Complete network isolation
- ✅ Reuses mdlayher/vsock library (same as control plane)
- ✅ Easy to test and debug
- ✅ Transparent gRPC forwarding

## Future Work

See `Documentation/IMPLEMENTATION_PLAN.md` Phase 4 for remaining tasks:

- **Phase 4.1**: Build context transfer via Session API
- **Phase 4.2**: Real-time progress streaming via Status RPC
- **Phase 4.3**: Complete Build API handlers
- **Phase 4.4**: Multi-stage builds and caching

## References

- **BuildKit**: https://github.com/moby/buildkit
- **mdlayher/vsock**: https://github.com/mdlayher/vsock
- **Docker Build API**: `Documentation/DOCKER_ENGINE_v1.51.yaml` (`/build` endpoint)
- **Implementation Plan**: `Documentation/IMPLEMENTATION_PLAN.md`
