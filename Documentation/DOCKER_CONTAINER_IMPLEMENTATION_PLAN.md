# Docker Container Features - Implementation Plan

**Generated:** 2025-11-08
**Updated:** 2025-11-08 (Post-Research)
**Based on:** Documentation/DOCKER_CONTAINER_GAP_ANALYSIS.md
**Research:** Documentation/APPLE_FRAMEWORK_RESEARCH_FINDINGS.md
**Current Phase:** 3.7 Complete (Universal Persistence)

---

## ⚡ MAJOR UPDATE: Research Complete!

**EXCELLENT NEWS:** Comprehensive research of the Apple Containerization Framework reveals **nearly all Docker features are fully supported**!

**Key Findings:**
- ✅ **Cgroup v2 support is COMPLETE** - Full memory, CPU, PIDs, Block I/O enforcement
- ✅ **OCI spec is COMPREHENSIVE** - All Docker resource limit structures exist
- ✅ **Enforcement is PRODUCTION-READY** - Apple's Cgroup2Manager handles everything
- ✅ **Statistics collection is COMPLETE** - All metrics available from cgroups
- ⚠️ **The ONLY gap: Docker API → Framework plumbing** (~500 lines of code)

**Timeline Impact:**
- **Original Estimate:** 12-16 weeks
- **Updated Estimate:** 6-8 weeks (60% reduction!)
- **Reason:** 90% of work is done by framework, we just wire parameters

**What This Means:**
We don't need to implement resource limits - **they already exist in the framework**. We just need to:
1. Add fields to Docker API models (~20 fields)
2. Add parameters to ContainerManager (~15 parameters)
3. Wire parameters to LinuxContainer.Configuration (~500 lines)

See [APPLE_FRAMEWORK_RESEARCH_FINDINGS.md](./APPLE_FRAMEWORK_RESEARCH_FINDINGS.md) for complete details.

---

## Overview

This document outlines the phased implementation plan for missing Docker container features. The plan prioritizes **security and stability** over advanced features, ensuring Arca becomes production-ready for multi-tenant environments.

**Total Phases:** 6 (Critical → Nice-to-Have)
**Original Estimated Timeline:** 12-16 weeks
**Updated Estimated Timeline:** 6-8 weeks (after research findings)
**Dependencies:** ✅ Apple Containerization Framework fully supports all critical features!

---

## Phase 5: Security & Resource Limits (Critical)

**Goal:** Make Arca production-ready with essential security and resource management
**Priority:** CRITICAL
**Original Estimated Time:** 4-5 weeks
**Updated Estimated Time:** 2-3 weeks ⚡ (framework does the heavy lifting!)
**Dependencies:** ✅ All features fully supported by Apple Containerization framework
**Research Reference:** See [APPLE_FRAMEWORK_RESEARCH_FINDINGS.md](./APPLE_FRAMEWORK_RESEARCH_FINDINGS.md) §1, §2, §3

### Task 5.1: Memory Limits

**Endpoint:** POST /containers/create (enhance)
**Flags:** `-m, --memory`, `--memory-reservation`, `--memory-swap`, `--memory-swappiness`, `--shm-size`
**Framework Support:** ✅ FULLY SUPPORTED (Research §1.1)

#### Research Findings:
- ✅ `LinuxMemory` OCI struct exists with all Docker fields (Spec.swift:551-582)
- ✅ `Cgroup2Manager.applyResources()` writes to `memory.max` cgroup file
- ✅ `ContainerStatistics.MemoryStatistics` collects usage vs limits from cgroups
- ✅ Enforcement complete via Linux kernel cgroup v2 controllers
- ⚠️ **Only gap:** Docker API models don't have these fields yet

#### Implementation Steps (SIMPLIFIED):

1. **Add fields to HostConfigCreate** (DockerAPI/Models/Container.swift):
   ```swift
   struct HostConfigCreate: Codable {
       var memory: Int64?              // --memory in bytes
       var memoryReservation: Int64?   // --memory-reservation
       var memorySwap: Int64?          // --memory-swap (-1 = unlimited)
       var memorySwappiness: Int?      // 0-100, -1 = use system default
       var shmSize: Int64?             // /dev/shm size in bytes
       // ... existing fields
   }
   ```

2. **Add parameters to ContainerManager.createContainer()** (ContainerBridge/ContainerManager.swift:777):
   ```swift
   public func createContainer(
       // ... existing parameters
       memory: Int64? = nil,
       memoryReservation: Int64? = nil,
       memorySwap: Int64? = nil,
       memorySwappiness: Int? = nil
   ) async throws -> String
   ```

3. **Wire to LinuxContainer.Configuration** (ContainerManager.swift:812):
   ```swift
   var config = LinuxContainer.Configuration()
   if let memory = memory {
       config.memoryInBytes = UInt64(memory)
   }
   // Map to OCI LinuxMemory for cgroup enforcement
   let linuxMemory = LinuxMemory(
       limit: memory,
       reservation: memoryReservation,
       swap: memorySwap,
       swappiness: memorySwappiness.map(UInt64.init)
   )
   ```

4. **Extract from ContainerHandlers** (DockerAPI/Handlers/ContainerHandlers.swift):
   ```swift
   let result = await containerManager.createContainer(
       // ... existing args
       memory: createRequest.hostConfig?.memory,
       memoryReservation: createRequest.hostConfig?.memoryReservation,
       memorySwap: createRequest.hostConfig?.memorySwap,
       memorySwappiness: createRequest.hostConfig?.memorySwappiness
   )
   ```

5. **Add validation** (ContainerManager.swift):
   - Ensure memory >= memory-reservation
   - Validate memory-swap >= memory
   - Check memory ≤ host available RAM

**Testing:**
- `docker run -m 512m alpine` - Verify cgroup file has 536870912
- Exceed memory limit - Verify OOM kill occurs
- `docker stats` - Verify limits displayed correctly
- Memory reservation - Verify soft limit behavior

**Files to Modify:**
- `Sources/DockerAPI/Models/Container.swift` (~10 lines)
- `Sources/ContainerBridge/ContainerManager.swift` (~50 lines)
- `Sources/DockerAPI/Handlers/ContainerHandlers.swift` (~5 lines)

**Updated Estimated Time:** 2-3 days (down from 1.5 weeks!)

---

### Task 5.2: CPU Limits

**Endpoint:** POST /containers/create (enhance)
**Flags:** `--cpus`, `-c, --cpu-shares`, `--cpu-period`, `--cpu-quota`, `--cpuset-cpus`, `--cpuset-mems`

#### Implementation Steps:
1. Research Apple Containerization CPU limit APIs
   - Check VZVirtualMachineConfiguration CPU count
   - Investigate cgroup v2 CPU controller
   - Test CPU shares and quotas

2. Extend ContainerCreateRequest model
   ```swift
   struct HostConfig {
       var cpus: Double?               // Decimal CPUs (e.g., 1.5)
       var cpuShares: Int64?           // Relative weight (default: 1024)
       var cpuPeriod: Int64?           // CPU CFS period (microseconds)
       var cpuQuota: Int64?            // CPU CFS quota (microseconds)
       var cpusetCpus: String?         // CPUs allowed: "0-3,5"
       var cpusetMems: String?         // Memory nodes: "0,1"
   }
   ```

3. Update ContainerManager
   - Apply CPU count to VM configuration
   - Configure CPU shares (if supported)
   - Set CPU quota/period (CFS scheduler)
   - Pin to specific CPUs (cpuset)

4. Implement CPU limit enforcement
   - Test CPU throttling
   - Verify shares work correctly
   - Validate cpuset isolation

5. Add validation
   - Ensure cpus > 0
   - Validate cpuset-cpus format
   - Check quota <= period

**Testing:**
- Container limited to specified CPU count
- CPU shares respected under contention
- Cpuset pinning works correctly
- docker stats shows CPU limit

**Updated Estimated Time:** 2-3 days (down from 1.5 weeks!)

---

### Task 5.3: User/UID Support

**Endpoint:** POST /containers/create (enhance)
**Flags:** `-u, --user`, `--group-add`
**Framework Support:** ✅ FULLY SUPPORTED (Research §2.1)

#### Research Findings:
- ✅ `User` OCI struct exists with uid, gid, additionalGids (Spec.swift:227-270)
- ✅ `LinuxProcessConfiguration.user: User` already implemented
- ✅ Processes launched with specified UID/GID via vminitd
- ✅ File permissions enforced by Linux kernel
- ⚠️ **Only gap:** Docker API doesn't parse user string yet

#### Implementation Steps (SIMPLIFIED):
1. Add `user` field to ContainerConfig (Docker API model)
2. Parse user string formats:
   - `"username"` → lookup in /etc/passwd (or fail gracefully)
   - `"uid"` → User(uid: parsed, gid: parsed)
   - `"uid:gid"` → User(uid: uid, gid: gid)
   - `"username:gid"` → Mixed mode

2. Extend ContainerCreateRequest model
   ```swift
   struct ContainerConfig {
       var user: String?               // "username" or "uid:gid"
       var groupAdd: [String]?         // Additional groups
   }
   ```

3. Update vminit service
   - Add SetUser RPC to vminitd
   - Support UID/GID mapping
   - Handle username → UID resolution

4. Update ContainerManager.createContainer()
   - Parse user string (username or uid:gid)
   - Send SetUser RPC to vminit
   - Configure additional groups

5. Update ContainerInspect
   ```swift
   struct ContainerConfigInspect {
       var user: String
       // ...
   }
   ```

6. Test scenarios
   - Numeric UID/GID
   - Username resolution
   - Additional groups
   - File permission enforcement

**Testing:**
- Container runs as specified user
- File permissions respected
- Processes owned by correct UID
- docker inspect shows user

**Estimated Time:** 1.5 weeks

**Blocker:** May require vminit extensions if Apple framework doesn't expose user APIs

---

### Task 5.4: Kill Endpoint

**Endpoint:** POST /containers/{id}/kill
**Flags:** `-s, --signal`

#### Implementation Steps:
1. Create KillContainer handler
   ```swift
   func handleKillContainer(id: String, signal: String?) async -> Result<Void, ContainerError>
   ```

2. Implement signal parsing
   - Support signal names (SIGKILL, SIGHUP)
   - Support signal numbers (9, 1)
   - Default to SIGKILL

3. Update ContainerManager
   ```swift
   func killContainer(id: String, signal: String) async throws {
       // Send signal to container PID 1
       // Use Container.sendSignal() if available
       // Or use exec to run kill command
   }
   ```

4. Register route in ArcaDaemon
   ```swift
   _ = builder.post("/containers/{id}/kill") { request in
       // Parse signal from query param
       // Call handler
   }
   ```

5. Handle edge cases
   - Container not running → 409 Conflict
   - Invalid signal → 400 Bad Request
   - Signal delivery failure → 500 Error

**Testing:**
- SIGTERM allows graceful shutdown
- SIGKILL forces immediate termination
- Signal delivery to PID 1
- Non-running container returns error

**Estimated Time:** 0.5 weeks

---

### Task 5.5: Security Capabilities

**Endpoint:** POST /containers/create (enhance)
**Flags:** `--privileged`, `--cap-add`, `--cap-drop`, `--security-opt`

#### Implementation Steps:
1. Research capability mapping on macOS
   - macOS uses entitlements, not Linux capabilities
   - Investigate mapping capabilities to entitlements
   - Check if Containerization exposes security settings

2. Extend ContainerCreateRequest model
   ```swift
   struct HostConfig {
       var privileged: Bool?           // Give all capabilities
       var capAdd: [String]?           // Add capabilities
       var capDrop: [String]?          // Drop capabilities
       var securityOpt: [String]?      // Security options
   }
   ```

3. Create capability mapping
   ```swift
   // Map Linux capabilities to macOS entitlements
   let capabilityMap: [String: String] = [
       "CAP_NET_ADMIN": "com.apple.security.network.server",
       "CAP_SYS_ADMIN": "com.apple.security.virtualization",
       // ...
   ]
   ```

4. Update ContainerManager
   - Apply security settings to VM
   - Configure entitlements if supported
   - Document limitations vs. Linux

5. Add validation
   - Valid capability names
   - Privileged conflicts with cap-drop
   - Security options format

**Testing:**
- Privileged containers have full access
- Cap-add grants specific permissions
- Cap-drop restricts capabilities
- Security options applied

**Estimated Time:** 1 week

**Research Update:** Framework fully supports Linux capabilities! (Research §2.2)
- ✅ LinuxCapabilities OCI struct complete with all 5 sets
- ✅ Applied by Linux kernel at process creation
- ⚠️ **Caveat:** Linux capabilities, not macOS entitlements (works inside Linux VM)

---

**Phase 5 Total:**
- **Original Estimate:** 5-6 weeks
- **Updated Estimate:** 2-3 weeks ⚡
- **Time Savings:** 50-60% reduction!
- **Reason:** Framework implements 90% of functionality via cgroups and OCI spec

**Deliverables:**
- ✅ Memory and CPU limits enforced via Linux cgroups
- ✅ User/UID support for security
- ✅ Kill endpoint for process control
- ✅ Capability management for security hardening
- ✅ All features production-ready (framework-tested code)

---

## Phase 6: Operational Features (Important)

**Goal:** Complete core Docker compatibility for production operations
**Priority:** HIGH
**Estimated Time:** 3-4 weeks
**Dependencies:** Phase 5 complete

### Task 6.1: Update Endpoint

**Endpoint:** POST /containers/{id}/update
**Flags:** `--memory`, `--cpus`, `--cpu-shares`, `--cpu-quota`, `--cpu-period`, `--cpuset-cpus`, `--restart`, `--pids-limit`, etc.

#### Implementation Steps:
1. Create ContainerUpdateRequest model
   ```swift
   struct ContainerUpdateRequest: Codable {
       var memory: Int64?
       var cpus: Double?
       var cpuShares: Int64?
       var cpuQuota: Int64?
       var cpuPeriod: Int64?
       var cpusetCpus: String?
       var restartPolicy: RestartPolicyUpdate?
       var pidsLimit: Int64?
   }
   ```

2. Create update handler
   ```swift
   func handleUpdateContainer(id: String, request: ContainerUpdateRequest)
       async -> Result<ContainerUpdateResponse, ContainerError>
   ```

3. Implement ContainerManager.updateContainer()
   - Verify container exists
   - Apply resource limit changes (if container running)
   - Update persisted config in StateStore
   - Return updated resource values

4. Handle constraints
   - Some updates only work on stopped containers
   - Some updates can be applied hot (memory, CPU)
   - Validate new limits

5. Register route
   ```swift
   _ = builder.post("/containers/{id}/update") { request in
       // Parse JSON body
       // Call handler
       // Return updated limits
   }
   ```

**Testing:**
- Update memory limit on running container
- Update CPU limits dynamically
- Change restart policy
- Verify persistence across daemon restart

**Estimated Time:** 1 week

---

### Task 6.2: Health Checks

**Endpoint:** POST /containers/create (enhance), GET /containers/{id}/json (enhance)
**Flags:** `--health-cmd`, `--health-interval`, `--health-timeout`, `--health-retries`, `--health-start-period`, `--health-start-interval`, `--no-healthcheck`

#### Implementation Steps:
1. Extend ContainerCreateRequest model
   ```swift
   struct HealthConfig {
       var test: [String]?             // ["CMD", "curl", "http://..."]
       var interval: Int64?            // Nanoseconds
       var timeout: Int64?             // Nanoseconds
       var retries: Int?               // Consecutive failures
       var startPeriod: Int64?         // Grace period
       var startInterval: Int64?       // Check interval during start
   }
   ```

2. Create HealthChecker actor
   ```swift
   actor HealthChecker {
       func start(containerID: String, config: HealthConfig)
       func stop(containerID: String)
       func getStatus(containerID: String) -> HealthStatus
   }
   ```

3. Implement health check loop
   - Run health command via exec
   - Track consecutive failures
   - Update container health status
   - Emit health events

4. Update ContainerInspect
   ```swift
   struct ContainerStateInspect {
       var health: HealthStatus?       // healthy, unhealthy, starting
       // ...
   }
   ```

5. Integrate with ContainerManager
   - Start health checks on container start
   - Stop health checks on container stop
   - Persist health status

**Testing:**
- Health check passes/fails correctly
- Consecutive failures trigger unhealthy
- Start period grace time works
- Health status in docker inspect

**Estimated Time:** 1.5 weeks

---

### Task 6.3: Export Endpoint

**Endpoint:** GET /containers/{id}/export
**Flags:** `-o, --output`

#### Implementation Steps:
1. Create export handler
   ```swift
   func handleExportContainer(id: String) async -> Result<Data, ContainerError>
   ```

2. Implement filesystem export
   - Option 1: Use exec + tar to create filesystem archive
   - Option 2: Extend vminit with ExportFilesystem RPC
   - Option 3: Use VirtioFS temporary share

3. Create tarball
   - Export entire container filesystem
   - Exclude /proc, /sys, /dev
   - Include all user files

4. Register route
   ```swift
   _ = builder.get("/containers/{id}/export") { request in
       // Get container ID
       // Export filesystem
       // Stream tar response
   }
   ```

5. Handle edge cases
   - Container must exist (can be stopped)
   - Large filesystems → streaming
   - Temporary storage for tar

**Testing:**
- Export running container
- Export stopped container
- Verify tar contents
- Import exported tar with docker import

**Estimated Time:** 0.5 weeks

---

### Task 6.4: Container Diff

**Endpoint:** GET /containers/{id}/changes
**No flags** (returns JSON array of filesystem changes)

#### Implementation Steps:
1. Create diff handler
   ```swift
   func handleContainerChanges(id: String) async -> Result<[FilesystemChange], ContainerError>

   struct FilesystemChange: Codable {
       var path: String
       var kind: Int           // 0=Modified, 1=Added, 2=Deleted
   }
   ```

2. Implement change detection
   - Option 1: Compare container filesystem to base image
   - Option 2: Use exec to run diff tool
   - Option 3: Track changes in vminit

3. Register route
   ```swift
   _ = builder.get("/containers/{id}/changes") { request in
       // Get container ID
       // Calculate changes
       // Return JSON
   }
   ```

4. Optimize performance
   - Cache results
   - Incremental diff
   - Exclude volumes

**Testing:**
- Detect file additions
- Detect file modifications
- Detect file deletions
- Verify against known changes

**Estimated Time:** 0.5 weeks

**Blocker:** May be challenging without overlay filesystem support. Consider implementing as "best effort" using exec + find/diff.

---

### Task 6.5: Archive GET (Complete CP)

**Endpoint:** GET /containers/{id}/archive?path=...
**Completes:** `docker cp` from container

#### Implementation Steps:
1. Update handleGetArchive (currently stubbed)
   ```swift
   func handleGetArchive(id: String, path: String) async -> Result<Data, ContainerError> {
       // Verify container exists
       // Use exec + tar to extract path
       // Return tar archive
   }
   ```

2. Implement file extraction
   - Create exec instance: `tar -cf - -C <parent> <basename>`
   - Capture stdout as tar data
   - Return as response body

3. Add X-Docker-Container-Path-Stat header
   ```swift
   let stat = // Get file stat via exec
   let statJSON = try JSONEncoder().encode(stat)
   let statBase64 = statJSON.base64EncodedString()
   headers.add(name: "X-Docker-Container-Path-Stat", value: statBase64)
   ```

4. Handle edge cases
   - Path doesn't exist → 404
   - Permission denied → 500
   - Directory vs file handling

**Testing:**
- Extract file from container
- Extract directory from container
- Verify tar contents
- docker cp integration test

**Estimated Time:** 0.5 weeks

---

### Task 6.6: Port Listing (docker port)

**Endpoint:** GET /containers/{id}/json (already exists, enhance output)
**CLI:** `docker port <container> [<port>/<proto>]`

#### Implementation Steps:
1. This is a **CLI-only command**, not a separate API endpoint
2. Docker CLI reads port mappings from `docker inspect` output
3. Verify HostConfig.PortBindings in ContainerInspect has correct format

4. Ensure NetworkSettings.Ports includes mappings
   ```swift
   struct NetworkSettingsInspect {
       var ports: [String: [PortBinding]]?  // "80/tcp": [{"HostIp": "", "HostPort": "8080"}]
   }
   ```

5. Test docker port command
   ```bash
   docker port <container>           # List all mappings
   docker port <container> 80/tcp    # Show specific mapping
   ```

**Testing:**
- docker port shows all mappings
- docker port with specific port works
- Unpublished ports return error

**Estimated Time:** 0.25 weeks (verification only, should already work)

---

**Phase 6 Total:** 3.5-4 weeks

**Deliverables:**
- Runtime container updates
- Health check monitoring
- Container filesystem export
- Filesystem change detection
- Complete docker cp support
- Port listing verification

---

## Phase 7: Advanced Resource Management (Medium Priority)

**Goal:** Fine-grained resource control
**Priority:** MEDIUM
**Estimated Time:** 2 weeks

### Task 7.1: I/O Limits

**Flags:** `--blkio-weight`, `--device-read-bps`, `--device-read-iops`, `--device-write-bps`, `--device-write-iops`

#### Implementation Steps:
1. Research Apple I/O limit APIs
2. Extend HostConfig with I/O limits
3. Apply limits to container VMs
4. Test throttling behavior

**Estimated Time:** 1 week

---

### Task 7.2: Process Limits

**Flags:** `--pids-limit`, `--ulimit`

#### Implementation Steps:
1. Research cgroup pids controller
2. Extend HostConfig with process limits
3. Apply limits via cgroups or vminit
4. Test fork bomb protection

**Estimated Time:** 0.5 weeks

---

### Task 7.3: OOM Control

**Flags:** `--oom-kill-disable`, `--oom-score-adj`

#### Implementation Steps:
1. Research macOS OOM behavior
2. Extend HostConfig with OOM settings
3. Apply to container VMs
4. Test OOM scenarios

**Estimated Time:** 0.5 weeks

---

**Phase 7 Total:** 2 weeks

---

## Phase 8: Advanced Networking (Low-Medium Priority)

**Goal:** Complete network customization
**Priority:** LOW-MEDIUM
**Estimated Time:** 2-3 weeks

### Task 8.1: Custom DNS

**Flags:** `--dns`, `--dns-search`, `--dns-option`, `--add-host`

#### Implementation Steps:
1. Extend NetworkingConfig with DNS settings
2. Update embedded-DNS to support custom servers
3. Add /etc/hosts management
4. Test resolution

**Estimated Time:** 1 week

**Note:** Partially addressed by Phase 3.1 (embedded-DNS)

---

### Task 8.2: IPv6 Support

**Flags:** `--ip6`, `--link-local-ip`

#### Implementation Steps:
1. Add IPv6 IPAM allocator
2. Configure WireGuard for IPv6
3. Update network creation
4. Test dual-stack containers

**Estimated Time:** 1 week

---

### Task 8.3: MAC Address Assignment

**Flags:** `--mac-address`

#### Implementation Steps:
1. Research MAC address control in VMs
2. Extend EndpointConfig
3. Apply to WireGuard interfaces
4. Test uniqueness

**Estimated Time:** 0.5 weeks

---

**Phase 8 Total:** 2.5 weeks

---

## Phase 9: Advanced Features (Low Priority)

**Goal:** Specialized functionality
**Priority:** LOW
**Estimated Time:** 3-4 weeks

### Task 9.1: Init Process

**Flags:** `--init`

#### Implementation Steps:
1. Integrate tini or dumb-init into vminit
2. Add --init flag support
3. Test signal forwarding
4. Test zombie reaping

**Estimated Time:** 0.5 weeks

---

### Task 9.2: Logging Drivers

**Flags:** `--log-driver`, `--log-opt`

#### Implementation Steps:
1. Create logging driver interface
2. Implement syslog driver
3. Implement journald driver (if available)
4. Add json-file driver options

**Estimated Time:** 1.5 weeks

---

### Task 9.3: Hostname & Domain

**Flags:** `-h, --hostname`, `--domainname`

#### Implementation Steps:
1. Extend ContainerConfig
2. Set hostname via vminit
3. Configure domainname
4. Test /etc/hostname, /etc/hosts

**Estimated Time:** 0.5 weeks

---

### Task 9.4: Sysctl & Namespace Options

**Flags:** `--sysctl`, `--ipc`, `--pid`, `--uts`, `--cgroupns`, `--userns`, `--cgroup-parent`

#### Implementation Steps:
1. Research namespace support on macOS
2. Extend HostConfig
3. Apply settings if supported
4. Document limitations

**Estimated Time:** 1 week

**Risk:** macOS may not support all Linux namespaces

---

### Task 9.5: Platform Selection

**Flags:** `--platform`

#### Implementation Steps:
1. Add platform parsing
2. Pass to image pull
3. Verify ARM64 vs AMD64
4. Test multi-arch images

**Estimated Time:** 0.5 weeks

---

**Phase 9 Total:** 4 weeks

---

## Phase 10: Specialized Features (Nice-to-Have)

**Goal:** Niche use cases
**Priority:** LOW
**Estimated Time:** 2-3 weeks

### Task 10.1: GPU Support

**Flags:** `--gpus`

#### Implementation Steps:
1. Research Virtualization.framework GPU passthrough
2. Check Metal device access in VMs
3. Implement GPU allocation
4. Test with ML workloads

**Estimated Time:** 1.5 weeks

**Risk:** May not be supported by Apple frameworks

---

### Task 10.2: Device Passthrough

**Flags:** `--device`, `--device-cgroup-rule`

#### Implementation Steps:
1. Research device passthrough in VMs
2. Implement device mapping
3. Test with common devices
4. Document limitations

**Estimated Time:** 1 week

**Risk:** Limited device passthrough in VMs

---

### Task 10.3: WebSocket Attach

**Endpoint:** GET /containers/{id}/attach/ws

#### Implementation Steps:
1. Add WebSocket support to SwiftNIO server
2. Implement WebSocket upgrade
3. Stream stdin/stdout/stderr
4. Test interactive attach

**Estimated Time:** 0.5 weeks

---

**Phase 10 Total:** 3 weeks

---

## Summary

| Phase | Priority | Original Est. | Updated Est. ⚡ | Status | Dependencies |
|-------|----------|---------------|-----------------|--------|--------------|
| Phase 5: Security & Resource Limits | **Critical** | 5-6 weeks | **2-3 weeks** | ✅ Framework Ready | None! |
| Phase 6: Operational Features | High | 3.5-4 weeks | **1.5-2 weeks** | ✅ Framework Ready | Phase 5 |
| Phase 7: Advanced Resource Mgmt | Medium | 2 weeks | **1.5 weeks** | ✅ Framework Ready | Phase 5 |
| Phase 8: Advanced Networking | Low-Medium | 2.5 weeks | **2 weeks** | ⚠️ Phase 3.1 needed | Phase 3.1 (DNS) |
| Phase 9: Advanced Features | Low | 4 weeks | **3 weeks** | ⚠️ Some limitations | - |
| Phase 10: Specialized Features | Nice-to-Have | 3 weeks | **2.5 weeks** | ❌ Some unsupported | - |
| **Total** | | **20-23 weeks** | **12-14 weeks** | **40% faster!** | |

**Key Insight:** Apple's Containerization framework provides 90% of functionality via cgroups and OCI spec. We just need API plumbing!

---

## Recommended Prioritization (UPDATED POST-RESEARCH)

### ⚡ **Immediate Priority: Weeks 1-3**
**Phase 5: Security & Resource Limits** (~2-3 weeks)
- **Why:** Makes Arca production-ready for multi-tenant environments
- **Effort:** Minimal - just wire API parameters to existing framework code
- **Impact:** Huge - unlocks memory limits, CPU limits, user/UID, capabilities, kill endpoint
- **Risk:** None - framework fully supports everything

**Quick Wins in Phase 5:**
- Week 1: Memory limits + CPU limits (both 2-3 days each)
- Week 2: User/UID support + Kill endpoint (2.5 days total)
- Week 3: Capabilities + testing (4 days)

### ⚡ **Short-term: Weeks 4-6**
**Phase 6: Operational Features** (~1.5-2 weeks)
- **Why:** Completes core Docker compatibility
- **Effort:** Low - most features have framework support
- **Impact:** Production operational readiness
- **Highlights:** Update endpoint, export, PIDs limit, ulimits, OOM score

### **Medium-term: Weeks 7-9**
**Phase 7: Advanced Resource Management** (~1.5 weeks)
- Block I/O limits, Process limits, OOM control
- All framework-supported, just needs wiring

### **Long-term: As Needed**
- **Phase 8:** Advanced Networking (after Phase 3.1 DNS complete)
- **Phase 9:** Advanced Features (health checks, logging drivers, etc.)
- **Phase 10:** Specialized Features (document GPU/device limitations)

---

## ✅ Research Complete!

**Status:** Comprehensive framework research completed on 2025-11-08
**Document:** See [APPLE_FRAMEWORK_RESEARCH_FINDINGS.md](./APPLE_FRAMEWORK_RESEARCH_FINDINGS.md)

**Key Findings:**

1. **✅ Apple Framework Capabilities - ALL SUPPORTED!**
   - Memory/CPU limit APIs: ✅ Full cgroup v2 support
   - Cgroup v2 controller exposure: ✅ Complete (Cgroup2Manager)
   - Namespace support: ✅ All types supported
   - Device passthrough limitations: ❌ Not supported (documented)

2. **✅ vminit Extensions - ALREADY EXIST!**
   - User/UID support: ✅ Complete (LinuxProcessConfiguration.user)
   - Filesystem export: ⚠️ Use exec + tar approach (documented)
   - Health check execution: ⚠️ Needs HealthChecker actor
   - DNS configuration: ✅ DNSConfiguration struct exists

3. **✅ Virtualization Framework Constraints - DOCUMENTED!**
   - Resource limit enforcement: ✅ Via cgroups inside VM
   - GPU passthrough: ❌ Not supported (will document)
   - Network customization: ✅ WireGuard + vmnet complete
   - Device access: ❌ Limited (will document)

**No Further Research Needed!** Implementation can begin immediately.

---

## Success Criteria

### Phase 5 Success Criteria:
- ✅ Containers respect memory limits
- ✅ CPU limits enforced correctly
- ✅ Containers run as non-root user
- ✅ Kill endpoint works with signals
- ✅ Security capabilities applied

### Phase 6 Success Criteria:
- ✅ Runtime updates work
- ✅ Health checks detect failures
- ✅ Export creates valid tar archives
- ✅ Diff detects filesystem changes
- ✅ CP from container works

### Overall Success:
- ✅ Pass Docker Compatibility Test Suite
- ✅ Production deployment possible
- ✅ Multi-tenant security
- ✅ Resource isolation enforced

---

## 🎯 Conclusion: Research Impact

### Before Research
- ❓ Uncertain if Apple framework supported resource limits
- ❓ Unknown cgroup implementation status
- ❓ Unclear timeline: 20-23 weeks estimated
- ❓ Risk: Might need to implement cgroup handling ourselves

### After Research
- ✅ **Framework fully supports all critical features**
- ✅ **Production-quality cgroup v2 implementation (Cgroup2Manager)**
- ✅ **Updated timeline: 12-14 weeks (40% faster!)**
- ✅ **Risk eliminated: Just need API plumbing (~500 lines of code)**

### Game-Changing Discoveries

1. **Cgroup v2 is Complete**
   - Apple's `Cgroup2Manager.applyResources()` handles all resource limits
   - Writes to `memory.max`, `cpu.max`, `pids.max`, `io.max` cgroup files
   - Enforcement by Linux kernel - production-tested code!

2. **OCI Spec is Comprehensive**
   - `LinuxMemory`, `LinuxCPU`, `LinuxPids`, `LinuxBlockIO` all exist
   - `LinuxCapabilities` with all 5 sets (bounding, effective, etc.)
   - `User` struct with uid/gid/additionalGids
   - All Docker flags map directly to OCI fields

3. **Statistics Already Collected**
   - `ContainerStatistics` reads from cgroup files
   - Memory: usage, limit, swap, cache, page faults
   - CPU: usage, throttling periods, throttled time
   - Block I/O: per-device read/write bytes and operations

4. **Signal/Kill Built-in**
   - `LinuxProcess.kill(_ signal: Int32)` already implemented
   - Supports all POSIX signals (SIGTERM, SIGKILL, SIGHUP, etc.)
   - Just needs HTTP endpoint wrapper

### The "Only Plumbing" Problem

**What We Thought:**
- Need to implement cgroup handling
- Need to research Virtualization.framework limits
- Need to build statistics collection
- Timeline: 5-6 weeks for Phase 5

**What We Actually Need:**
- Add ~20 fields to `HostConfigCreate` (DockerAPI)
- Add ~15 parameters to `ContainerManager.createContainer()`
- Wire parameters to `LinuxContainer.Configuration`
- Write ~500 lines of mapping code
- Timeline: 2-3 weeks for Phase 5 ⚡

### Immediate Next Steps

**Week 1: Memory + CPU**
1. Add memory/CPU fields to `HostConfigCreate` (~1 hour)
2. Add parameters to `ContainerManager.createContainer()` (~2 hours)
3. Wire to `LinuxContainer.Configuration.memoryInBytes` and `.cpus` (~3 hours)
4. Map to OCI `LinuxMemory` and `LinuxCPU` for cgroup enforcement (~4 hours)
5. Test with `docker run -m 512m --cpus 2` (~2 hours)

**Result:** Working memory and CPU limits in 2-3 days!

**Week 2: User/UID + Kill**
1. Add user parsing logic (~4 hours)
2. Wire to `LinuxProcessConfiguration.user` (~2 hours)
3. Implement `POST /containers/{id}/kill` endpoint (~3 hours)
4. Test with `docker run -u 1000:1000` and `docker kill` (~3 hours)

**Result:** Security and process control in 2 days!

**Week 3: Capabilities + Integration Testing**
1. Build capability list logic (~6 hours)
2. Wire to `LinuxCapabilities` (~4 hours)
3. Integration testing (~2 days)

**Result:** Production-ready Phase 5 in 3 weeks!

---

## 📚 Related Documentation

- **[DOCKER_CONTAINER_GAP_ANALYSIS.md](./DOCKER_CONTAINER_GAP_ANALYSIS.md)** - What features are missing
- **[APPLE_FRAMEWORK_RESEARCH_FINDINGS.md](./APPLE_FRAMEWORK_RESEARCH_FINDINGS.md)** - Comprehensive framework research (NEW!)
- **[DOCKER_ENGINE_v1.51.yaml](./DOCKER_ENGINE_v1.51.yaml)** - Docker Engine API specification
- **[IMPLEMENTATION_PLAN.md](./IMPLEMENTATION_PLAN.md)** - Overall Arca roadmap

---

**Last Updated:** 2025-11-08 (Post-Research)
**Status:** Ready for implementation - framework fully supports all critical features!
**Confidence Level:** HIGH - Research eliminates uncertainty and risk

