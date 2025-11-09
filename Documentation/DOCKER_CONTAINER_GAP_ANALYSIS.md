# Docker Container Commands - Gap Analysis

**Generated:** 2025-11-08
**Source:** https://docs.docker.com/reference/cli/docker/container/
**API Spec:** Documentation/DOCKER_ENGINE_v1.51.yaml
**Current Implementation:** Phase 3.7 Complete (Universal Persistence)

---

## Executive Summary

Arca currently implements **19 out of 25** Docker container CLI commands (76% coverage). The implementation focuses on core container lifecycle operations, with most missing functionality related to advanced resource management, filesystem operations, and specialized features.

**Implementation Status:**
- ✅ **Fully Implemented:** 16 commands
- ⚠️ **Partially Implemented:** 3 commands
- ❌ **Not Implemented:** 6 commands

---

## 1. API Endpoint Coverage

### Implemented Endpoints (19/24)

| Endpoint | Method | CLI Command | Status | Notes |
|----------|--------|-------------|--------|-------|
| `/containers/json` | GET | `docker ps` / `ls` | ✅ Complete | Supports all, limit, size, filters |
| `/containers/create` | POST | `docker create` | ⚠️ Partial | Missing many flags (see §3) |
| `/containers/{id}/json` | GET | `docker inspect` | ✅ Complete | Full inspection support |
| `/containers/{id}/top` | GET | `docker top` | ✅ Complete | Uses exec + ps |
| `/containers/{id}/logs` | GET | `docker logs` | ✅ Complete | Streaming + filtering |
| `/containers/{id}/stats` | GET | `docker stats` | ✅ Complete | Streaming + single-shot |
| `/containers/{id}/resize` | POST | `docker attach` | ✅ Complete | TTY resize (no-op) |
| `/containers/{id}/start` | POST | `docker start` | ✅ Complete | Supports checkpoint (experimental) |
| `/containers/{id}/stop` | POST | `docker stop` | ✅ Complete | Supports timeout, signal |
| `/containers/{id}/restart` | POST | `docker restart` | ✅ Complete | Supports timeout, signal |
| `/containers/{id}/rename` | POST | `docker rename` | ✅ Complete | Full support |
| `/containers/{id}/pause` | POST | `docker pause` | ✅ Complete | Full support |
| `/containers/{id}/unpause` | POST | `docker unpause` | ✅ Complete | Full support |
| `/containers/{id}/attach` | POST | `docker attach` | ✅ Complete | Streaming logs (no stdin) |
| `/containers/{id}/wait` | POST | `docker wait` | ✅ Complete | Full support |
| `/containers/{id}` | DELETE | `docker rm` | ✅ Complete | Supports force, volumes |
| `/containers/{id}/archive` | GET | `docker cp` (from) | ⚠️ Stub | Returns not implemented |
| `/containers/{id}/archive` | PUT | `docker cp` (to) | ✅ Complete | Uses exec + tar |
| `/containers/prune` | POST | `docker prune` | ✅ Complete | Removes stopped containers |

### Missing Endpoints (5/24)

| Endpoint | Method | CLI Command | Priority | Impact |
|----------|--------|-------------|----------|--------|
| `/containers/{id}/changes` | GET | `docker diff` | Low | Diagnostic only |
| `/containers/{id}/export` | GET | `docker export` | Medium | Image creation workflow |
| `/containers/{id}/kill` | POST | `docker kill` | High | Process management |
| `/containers/{id}/update` | POST | `docker update` | Medium | Runtime config changes |
| `/containers/{id}/attach/ws` | GET | `docker attach` (WS) | Low | Interactive attach via websocket |

### Missing CLI Commands (Not API Endpoints)

| Command | Equivalent | Status | Notes |
|---------|------------|--------|-------|
| `docker run` | `create` + `start` | ✅ Works | Docker CLI combines operations |
| `docker commit` | POST `/commit` | ❌ Missing | Creates image from container |
| `docker cp` (from container) | GET `/archive` | ⚠️ Stub | Needs implementation |

---

## 2. CLI Command Coverage

### Fully Implemented Commands (16/25)

✅ **attach** - Attach to running container (read-only, no stdin)
✅ **create** - Create container (partial flag support)
✅ **exec** - Execute command in container
✅ **inspect** - Display detailed information
✅ **logs** - Fetch container logs
✅ **ls** / **ps** - List containers
✅ **pause** - Pause container processes
✅ **prune** - Remove stopped containers
✅ **rename** - Rename container
✅ **restart** - Restart container
✅ **rm** - Remove container
✅ **start** - Start stopped container
✅ **stats** - Display resource usage statistics
✅ **stop** - Stop running container
✅ **top** - Display running processes
✅ **unpause** - Unpause container
✅ **wait** - Wait for container to stop

### Partially Implemented Commands (3/25)

⚠️ **cp** - Copy files (TO container works, FROM container stubbed)
⚠️ **run** - Works via create+start, missing many flags
⚠️ **update** - Not implemented (no runtime config changes)

### Not Implemented Commands (6/25)

❌ **commit** - Create image from container changes
❌ **diff** - Inspect filesystem changes
❌ **export** - Export container filesystem as tar
❌ **kill** - Kill container with signal
❌ **port** - List port mappings
❌ **update** - Update container configuration

---

## 3. Container Create/Run Flag Coverage

**Note:** The `docker run` and `docker create` commands share the same underlying API endpoint (`POST /containers/create`) and accept identical flags.

### Supported Flags (Core Functionality)

#### Container Identity & Environment
✅ `--name` - Container name
✅ `-e, --env` - Environment variables
✅ `--env-file` - Environment from file
✅ `-w, --workdir` - Working directory
✅ `--entrypoint` - Override entrypoint
✅ `--label` - Metadata labels
✅ `--label-file` - Labels from file

#### Interactive & TTY
✅ `-i, --interactive` - Keep STDIN open
✅ `-t, --tty` - Allocate pseudo-TTY
✅ `-a, --attach` - Attach STDIN/STDOUT/STDERR
✅ `--detach-keys` - Override detach key sequence

#### Networking
✅ `--network` - Connect to network
✅ `-p, --publish` - Publish ports
✅ `-P, --publish-all` - Publish all exposed ports
✅ `--network-alias` - Network-scoped alias (via EndpointConfig)
✅ `--ip` - IPv4 address (via EndpointConfig)

#### Storage
✅ `-v, --volume` - Bind mount volumes
✅ `--volumes-from` - Mount volumes from container
✅ `--read-only` - Read-only root filesystem
✅ `--tmpfs` - Mount tmpfs (via ContainerManager)

#### Restart Policy
✅ `--restart` - Restart policy (no, always, on-failure, unless-stopped)

#### Lifecycle
✅ `--rm` - Auto-remove on exit
✅ `-d, --detach` - Run in background (docker run only)

### Missing Flags (Grouped by Category)

#### Resource Limits - CPU (15 flags)
❌ `-c, --cpu-shares` - CPU shares (relative weight)
❌ `--cpus` - Number of CPUs
❌ `--cpu-period` - CPU CFS period
❌ `--cpu-quota` - CPU CFS quota
❌ `--cpuset-cpus` - CPUs allowed for execution
❌ `--cpuset-mems` - Memory nodes allowed
❌ `--cpu-rt-period` - Real-time period
❌ `--cpu-rt-runtime` - Real-time runtime
❌ `--cpu-count` - CPU count (Windows)
❌ `--cpu-percent` - CPU percent (Windows)

**Impact:** Cannot enforce CPU limits or affinity. Containers can consume all available CPU.
**Priority:** Medium (important for multi-tenant environments)

#### Resource Limits - Memory (7 flags)
❌ `-m, --memory` - Memory limit
❌ `--memory-reservation` - Memory soft limit
❌ `--memory-swap` - Swap limit
❌ `--memory-swappiness` - Memory swappiness (0-100)
❌ `--kernel-memory` - Kernel memory limit
❌ `--shm-size` - Size of /dev/shm
❌ `--storage-opt` - Storage driver options

**Impact:** Cannot enforce memory limits. Risk of OOM killing host processes.
**Priority:** High (critical for stability)

#### Resource Limits - I/O (7 flags)
❌ `--blkio-weight` - Block IO weight
❌ `--blkio-weight-device` - Device-specific block IO weight
❌ `--device-read-bps` - Limit read rate (bytes/sec)
❌ `--device-read-iops` - Limit read rate (IO/sec)
❌ `--device-write-bps` - Limit write rate (bytes/sec)
❌ `--device-write-iops` - Limit write rate (IO/sec)
❌ `--io-maxbandwidth` - System drive bandwidth ceiling (Windows)
❌ `--io-maxiops` - System drive IOps ceiling (Windows)

**Impact:** Cannot enforce disk I/O limits. Single container can saturate disk.
**Priority:** Medium (important for I/O-intensive workloads)

#### Networking - Advanced (9 flags)
❌ `--ip6` - IPv6 address
❌ `--link-local-ip` - Link-local addresses
❌ `--mac-address` - Container MAC address
❌ `--link` - Link to another container (deprecated)
❌ `--dns` - Custom DNS servers
❌ `--dns-search` - Custom DNS search domains
❌ `--dns-option` - DNS options
❌ `--add-host` - Custom host-to-IP mapping
❌ `--expose` - Expose port (metadata only)

**Impact:** Limited network customization. No custom DNS, no IPv6.
**Priority:** Low-Medium (Phase 3.1 DNS adds some functionality)

#### Devices & Hardware (4 flags)
❌ `--device` - Add host device to container
❌ `--device-cgroup-rule` - Add device cgroup rule
❌ `--gpus` - GPU devices to add
❌ `--runtime` - Runtime to use

**Impact:** Cannot pass through GPUs or other devices.
**Priority:** Low (niche use case, but important for ML/AI workloads)

#### Security & Permissions (11 flags)
❌ `-u, --user` - Username or UID
❌ `--group-add` - Add additional groups
❌ `--privileged` - Give extended privileges
❌ `--cap-add` - Add Linux capabilities
❌ `--cap-drop` - Drop Linux capabilities
❌ `--security-opt` - Security options
❌ `--userns` - User namespace
❌ `--uts` - UTS namespace
❌ `--pid` - PID namespace
❌ `--cgroupns` - Cgroup namespace
❌ `--cgroup-parent` - Parent cgroup

**Impact:** All containers run as root. Limited security isolation.
**Priority:** High (security concern)

#### Health Checks (7 flags)
❌ `--health-cmd` - Health check command
❌ `--health-interval` - Time between health checks
❌ `--health-timeout` - Max time for one health check
❌ `--health-retries` - Consecutive failures for unhealthy
❌ `--health-start-period` - Start period for initialization
❌ `--health-start-interval` - Check interval during start period
❌ `--no-healthcheck` - Disable HEALTHCHECK

**Impact:** No automated health monitoring. Orchestrators cannot detect unhealthy containers.
**Priority:** Medium (important for production deployments)

#### Logging (2 flags)
❌ `--log-driver` - Logging driver
❌ `--log-opt` - Log driver options

**Impact:** Fixed JSON file logging. Cannot use syslog, journald, etc.
**Priority:** Low (current logging works well)

#### Process Control (9 flags)
❌ `--init` - Run init inside container
❌ `--stop-signal` - Signal to stop container
❌ `--stop-timeout` - Timeout to stop container
❌ `--pids-limit` - Process ID limit
❌ `--ulimit` - Ulimit options
❌ `--oom-kill-disable` - Disable OOM Killer
❌ `--oom-score-adj` - Tune OOM preferences
❌ `--sysctl` - Sysctl options
❌ `--ipc` - IPC mode

**Impact:** Limited process management. Cannot tune kernel parameters.
**Priority:** Low-Medium

#### Platform & Image (4 flags)
❌ `--platform` - Set platform for multi-platform servers
❌ `--pull` - Pull image before creating (always, missing, never)
❌ `--isolation` - Container isolation technology
❌ `--disable-content-trust` - Skip image verification

**Impact:** Cannot specify pull policy or platform.
**Priority:** Low (single platform deployment)

#### Other (6 flags)
❌ `--hostname, -h` - Container hostname
❌ `--domainname` - Container NIS domain name
❌ `--cidfile` - Write container ID to file
❌ `--annotation` - Add annotation to container
❌ `-q, --quiet` - Suppress pull output
❌ `--sig-proxy` - Proxy received signals to process

**Impact:** Minor convenience features missing.
**Priority:** Low

---

## 4. Priority Assessment

### Critical Missing Features (Must Have)

**Security & Resource Limits:**
1. ❌ Memory limits (`-m, --memory`)
2. ❌ User/UID support (`-u, --user`)
3. ❌ Capability management (`--cap-add`, `--cap-drop`)
4. ❌ CPU limits (`--cpus`, `--cpu-shares`)

**Core Operations:**
5. ❌ Kill endpoint (`POST /containers/{id}/kill`)
6. ❌ Export endpoint (`GET /containers/{id}/export`)

### Important Missing Features (Should Have)

**Operational:**
1. ❌ Update endpoint (`POST /containers/{id}/update`)
2. ❌ Health checks (`--health-*` flags)
3. ❌ Process limits (`--pids-limit`)
4. ❌ Container filesystem diff (`GET /containers/{id}/changes`)
5. ❌ Port listing (`docker port`)
6. ❌ Archive extraction (`GET /containers/{id}/archive`)

**Resource Management:**
7. ❌ Memory swap controls (`--memory-swap`, `--memory-swappiness`)
8. ❌ I/O limits (`--device-read/write-bps/iops`)

### Nice-to-Have Features (Could Have)

**Advanced Networking:**
1. ❌ IPv6 support (`--ip6`)
2. ❌ Custom DNS (`--dns`, `--dns-search`)
3. ❌ MAC address assignment (`--mac-address`)
4. ❌ Host file management (`--add-host`)

**Advanced Features:**
5. ❌ GPU support (`--gpus`)
6. ❌ Device passthrough (`--device`)
7. ❌ Init process (`--init`)
8. ❌ Logging drivers (`--log-driver`)
9. ❌ Platform selection (`--platform`)
10. ❌ Websocket attach (`/attach/ws`)

---

## 5. Apple Containerization Framework Limitations

Some missing features may be constrained by Apple's Containerization framework:

### Framework Limitations (Need Investigation)
- **Resource Limits:** Apple's framework may not expose cgroup controls
- **Capabilities:** macOS uses entitlements, not Linux capabilities
- **User Namespaces:** May not be supported on macOS
- **GPU Passthrough:** Virtualization.framework limitations
- **Device Passthrough:** Limited hardware access in VMs

### Workarounds Required
- **Memory/CPU Limits:** May need to use Virtualization.framework VM settings
- **User/UID:** May need to use VM boot parameters or vminit extensions
- **Capabilities:** May need to map to macOS entitlements

---

## 6. Comparison with Docker Desktop

| Feature | Docker Desktop | Arca | Gap |
|---------|----------------|------|-----|
| Container lifecycle | ✅ Full | ✅ Full | None |
| Resource limits | ✅ Full | ❌ None | Critical |
| User/UID support | ✅ Full | ❌ None | Critical |
| Networking | ✅ Full | ✅ Most | Minor (DNS, IPv6) |
| Volumes | ✅ Full | ✅ Named volumes | None |
| Health checks | ✅ Full | ❌ None | Important |
| Security features | ✅ Full | ❌ None | Critical |
| Platform selection | ✅ Full | ❌ None | Nice-to-have |

---

## 7. Testing Coverage

### Well-Tested Commands
✅ create, start, stop, restart, rm
✅ logs, attach, wait
✅ pause, unpause
✅ stats, top
✅ exec
✅ inspect, ls/ps
✅ prune
✅ rename

### Needs Testing
⚠️ cp (to container - works but needs integration tests)
⚠️ resize (no-op implementation)
⚠️ archive endpoints (PUT works, GET stubbed)

### Not Testable (Not Implemented)
❌ commit, diff, export, kill, update, port

---

## 8. Recommendations

### Phase 1: Security & Stability (High Priority)
1. **Implement memory limits** - Critical for stability
2. **Implement CPU limits** - Important for multi-tenant
3. **Add user/UID support** - Critical for security
4. **Implement kill endpoint** - Complete lifecycle management
5. **Add capability controls** - Security hardening

### Phase 2: Operations (Medium Priority)
1. **Implement update endpoint** - Runtime configuration changes
2. **Add health check support** - Production readiness
3. **Implement export endpoint** - Image creation workflow
4. **Add container diff** - Debugging capability
5. **Implement GET /archive** - Complete cp command
6. **Add port listing** - Diagnostic capability

### Phase 3: Advanced Features (Low Priority)
1. **Add custom DNS support** - Network customization
2. **Implement IPv6** - Modern networking
3. **Add init process support** - Signal handling
4. **Implement logging drivers** - Log aggregation
5. **Add GPU support** - ML/AI workloads
6. **Platform selection** - Multi-arch support

---

## 9. Conclusion

Arca provides **strong coverage of core container operations** (76% of commands), with excellent implementation of:
- Complete container lifecycle (create, start, stop, restart, rm)
- Logging and monitoring (logs, stats, top)
- Interactive operations (attach, exec)
- State management (pause, unpause, wait)
- Network operations (via WireGuard backend)
- Volume operations (via VolumeManager)

**Critical gaps** exist in:
- Resource limits (memory, CPU, I/O)
- Security features (user/UID, capabilities)
- Advanced configuration (health checks, update)
- Some filesystem operations (export, archive GET, diff)

The implementation is **production-ready for development workflows** but requires resource limits and security features for **production multi-tenant environments**.
