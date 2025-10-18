# Known Limitations and Differences

This document describes known differences between Arca (Docker Engine API backed by Apple's Containerization framework) and standard Docker Engine behavior.

## Image Size Reporting

**Status**: Known limitation
**Affected APIs**: `GET /images/json`, `GET /images/{id}/json`
**Impact**: Image sizes appear smaller in Arca than in Docker

### Description

Arca reports **compressed** (on-disk storage) sizes for OCI images, while Docker reports **uncompressed** (extracted filesystem) sizes.

**Example**:
```bash
# Docker Engine
docker images alpine
# REPOSITORY   TAG       IMAGE ID       CREATED      SIZE
# alpine       latest    4b7ce07002c6   9 days ago   13.3MB

# Arca
docker images alpine  # with DOCKER_HOST=unix:///var/run/arca.sock
# REPOSITORY   TAG       IMAGE ID       CREATED      SIZE
# alpine       latest    4b7ce07002c6   9 days ago   4.14MB
```

### Technical Background

The OCI Image specification defines layer descriptors with only **compressed blob sizes**:
- `manifest.layers[].size` = size of compressed tar.gz blob
- `config.rootfs.diff_ids` = digests of uncompressed layers (no size metadata)

Docker Engine historically tracked uncompressed sizes because that's what users care about (disk space after extraction). However, the OCI spec doesn't provide this information directly, requiring either:
1. Decompressing each layer to measure (slow)
2. Tracking uncompressed sizes during pull/push operations (requires storage)
3. Using compression ratio heuristics (inaccurate)

### Current Behavior

Arca implements **OCI-compliant** behavior by reporting compressed sizes from `manifest.layers[].size`. This is:
-  Fast - no decompression required
-  OCI spec-compliant
-  Accurate for storage metrics
- L Different from Docker Engine

### Future Work

**Phase 4**: Implement proper uncompressed size tracking
- Track uncompressed sizes during image pull operations
- Store metadata alongside OCI content
- Report Docker-compatible sizes in API responses

See `IMPLEMENTATION_PLAN.md` Phase 4 for details.

### Workaround

To see actual extracted sizes, inspect the container filesystem after creation:
```bash
docker create --name temp alpine
docker export temp | wc -c
docker rm temp
```

---

## Networking

**Status**: Architectural difference
**Affected APIs**: Network CRUD operations, container network connect/disconnect
**Impact**: DNS-based networking instead of bridge networks

### Description

Apple's Containerization framework uses **DNS-based networking** rather than traditional Linux bridge networks. Containers on the same network can reach each other via DNS names, but not via virtual network interfaces.

**Example**:
```bash
# In Docker, containers get IPs on a bridge network:
# container1: 172.20.0.2
# container2: 172.20.0.3

# In Arca, containers communicate via DNS:
# container1 -> container2.my-network.container.internal
```

### Current Behavior

- Containers can communicate via DNS names: `{container-name}.{network-name}.container.internal`
- No bridge interfaces or direct IP allocation
- `docker network inspect` shows limited network information

### Future Work

This is an architectural difference in Apple's Containerization framework and cannot be changed at the Arca layer.

---

## Volumes

**Status**: Partial limitation
**Affected APIs**: Volume CRUD operations, container volume mounts
**Impact**: Some VirtioFS limitations affect volume operations

### Description

Apple's Containerization uses VirtioFS for sharing directories between host and VM. This has some limitations compared to Docker's volume implementation:

- Read-only mounts work reliably
- Some write operations may have different performance characteristics
- File watching (inotify) behavior may differ

### Current Behavior

Basic volume operations work:
```bash
docker volume create mydata
docker run -v mydata:/data alpine
```

### Known Issues

- Complex permission scenarios may behave differently
- High-frequency writes may have different performance
- File watching tools may need adjustment

### Future Work

Document specific VirtioFS behaviors and best practices for volume usage with Arca.

---

## Build Operations

**Status**: Not yet implemented
**Affected APIs**: `POST /build`
**Impact**: Image building not supported

### Description

The `docker build` command and associated API endpoints are not yet implemented. This includes:
- Building images from Dockerfile
- Build context handling
- Multi-stage builds
- Build cache

### Workaround

Use standard Docker Engine to build images, then pull them into Arca:
```bash
# Build with Docker
docker build -t myapp:latest .
docker push myregistry/myapp:latest

# Use with Arca
export DOCKER_HOST=unix:///var/run/arca.sock
docker pull myregistry/myapp:latest
docker run myapp:latest
```

### Future Work

**Phase 4**: Implement build API using Apple's builder infrastructure or integrate with external build tools.

---

## Swarm Mode

**Status**: Not supported
**Affected APIs**: All swarm-related endpoints
**Impact**: Docker Swarm orchestration unavailable

### Description

Arca does not implement Docker Swarm mode APIs. This includes:
- Services
- Secrets
- Configs
- Nodes
- Tasks
- Stacks

### Workaround

Use Kubernetes or other orchestration platforms that work via the standard container APIs.

---

## Platform Support

**Status**: Architectural constraint
**Impact**: macOS-only, Apple Silicon optimized

### Description

Arca runs exclusively on macOS and leverages Apple's Containerization framework, which requires:
- macOS 14.0+ (macOS Sonoma or later)
- Apple Silicon (arm64) or Intel (with limitations)

Container images must be:
- linux/arm64 for native performance on Apple Silicon
- linux/amd64 (runs via Rosetta 2 or QEMU with performance penalty)

### Current Behavior

- Native Apple Silicon performance for linux/arm64 images
- Automatic platform selection via `Platform.current`
- Multi-platform images pull appropriate manifest

---

## API Version Compatibility

**Status**: In progress
**Target**: Docker Engine API v1.51
**Current**: Partial implementation

### Description

Arca targets Docker Engine API v1.51 but is not yet feature-complete. See `IMPLEMENTATION_PLAN.md` for implementation phases.

### Current Status

**Phase 1 (MVP)**:  Complete
- System info and version
- Container lifecycle (create, start, stop, list, inspect, remove, logs, wait)
- Image operations (list, inspect, pull, remove, tag)

**Phase 2-4**: In progress
- Exec API
- Networks
- Volumes
- Build
- Advanced features

### API Version Negotiation

Arca supports version-prefixed paths:
```
GET /v1.51/containers/json   Supported
GET /v1.28/containers/json   Supported (minimum version)
GET /containers/json         Defaults to v1.51
```

---

## Performance Characteristics

### Image Pull Performance

First pull of an image requires downloading all layers. Subsequent pulls of the same image are fast due to content-addressable storage.

### Container Startup Time

Container startup includes VM initialization overhead (typically 1-3 seconds), which is slower than Docker's namespace-based containers but provides better isolation.

### Resource Usage

Each container runs in its own lightweight VM, providing strong isolation at the cost of slightly higher memory overhead compared to namespace-based containers.

---

## Reporting Issues

If you encounter behavior that differs from these documented limitations, please report it at:
https://github.com/anthropics/arca/issues

Include:
- Arca version (`docker version` with DOCKER_HOST set)
- macOS version
- Complete command that demonstrates the issue
- Expected vs actual behavior
