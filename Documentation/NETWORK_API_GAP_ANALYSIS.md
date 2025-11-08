# Docker Network API - Gap Analysis

**Generated**: 2025-11-07
**API Version**: Docker Engine API v1.51
**Reference**: Documentation/DOCKER_ENGINE_v1.51.yaml

This document analyzes the current implementation of Docker Network API endpoints in Arca against the Docker Engine API v1.51 specification.

---

## Executive Summary

**Overall Status**: 🟡 **Good Foundation - Minor Gaps**

- ✅ **Core Functionality**: All essential CRUD operations implemented
- ✅ **WireGuard Backend**: Full Docker compatibility with dynamic attach/detach
- ⚠️ **Missing Features**: 1 endpoint, some query parameters, and optional network fields
- 📊 **Completion**: ~85% of network API implemented

---

## Endpoint Coverage

### ✅ Implemented Endpoints (6/7)

| Endpoint | Method | Status | Handler | Notes |
|----------|--------|--------|---------|-------|
| `/networks` | GET | ✅ Implemented | `handleListNetworks` | Supports filters (name, id, driver, label) |
| `/networks/{id}` | GET | ✅ Implemented | `handleInspectNetwork` | Returns full network details |
| `/networks/create` | POST | ✅ Implemented | `handleCreateNetwork` | Supports IPAM, options, labels |
| `/networks/{id}` | DELETE | ✅ Implemented | `handleDeleteNetwork` | Validates not in use, prevents default deletion |
| `/networks/{id}/connect` | POST | ✅ Implemented | `handleConnectNetwork` | Dynamic network attach via WireGuard |
| `/networks/{id}/disconnect` | POST | ✅ Implemented | `handleDisconnectNetwork` | Dynamic network detach |

### ❌ Missing Endpoints (1/7)

| Endpoint | Method | Priority | Complexity | Estimated Effort |
|----------|--------|----------|------------|------------------|
| `/networks/prune` | POST | **Medium** | **Low** | ~2-3 hours |

**Impact**: Low - `docker network prune` won't work, but this is a cleanup utility, not core functionality.

---

## Implementation Gaps

### 1. Missing Endpoint: `/networks/prune`

**Specification** (DOCKER_ENGINE_v1.51.yaml:11338-11370):
```yaml
/networks/prune:
  post:
    summary: "Delete unused networks"
    operationId: "NetworkPrune"
    parameters:
      - name: "filters"
        in: "query"
        description: |
          Filters to process on the prune list
          - `until=<timestamp>` - Prune networks created before this timestamp
          - `label` - Prune networks with (or without) the specified labels
    responses:
      200:
        schema:
          properties:
            NetworksDeleted:
              type: "array"
              items:
                type: "string"
```

**What's Needed**:
- New handler method in `NetworkHandlers.swift`: `handlePruneNetworks(filters: [String: [String]])`
- New method in `NetworkManager.swift`: `pruneNetworks(until: Date?, labels: [String: String]?)`
- Route registration in `ArcaDaemon.swift`
- Response model: `NetworkPruneResponse` with `NetworksDeleted: [String]`

**Logic**:
1. Get all networks from both backends (WireGuard + vmnet)
2. Filter out default networks (bridge, none)
3. Filter networks with NO active container attachments
4. Apply optional filters (until, label)
5. Delete qualifying networks
6. Return list of deleted network IDs

**Files to Modify**:
- `Sources/DockerAPI/Handlers/NetworkHandlers.swift` (+30 lines)
- `Sources/ContainerBridge/NetworkManager.swift` (+40 lines)
- `Sources/DockerAPI/Models/Network.swift` (+10 lines for response model)
- `Sources/ArcaDaemon/ArcaDaemon.swift` (+15 lines for route)

**Estimated Effort**: 2-3 hours (straightforward implementation)

---

### 2. Missing Query Parameters

#### A. GET `/networks` (List Networks)

**Implemented Filters** ✅:
- `name` - Filter by network name
- `id` - Filter by network ID (partial match)
- `driver` - Filter by driver type
- `label` - Filter by labels

**Missing Filters** ❌:
- `dangling` - Filter networks not in use by containers
- `scope` - Filter by scope (swarm/global/local)
- `type` - Filter by type (custom/builtin)

**Priority**: Low
**Effort**: ~1 hour (add filter logic to `applyFilters()` in NetworkHandlers.swift)

#### B. GET `/networks/{id}` (Inspect Network)

**Implemented Query Parameters**: None ❌

**Missing Query Parameters** ❌:
- `verbose` - Detailed inspect output for troubleshooting
- `scope` - Filter the network by scope (swarm, global, or local)

**Priority**: Very Low (rarely used)
**Effort**: ~30 minutes (pass through to backend, no behavior change needed for now)

---

### 3. Missing Network Response Fields

The `Network` model in `Sources/DockerAPI/Models/Network.swift` is **missing optional fields** from the spec:

**Missing Fields** ❌:
- `ConfigFrom` - Reference to config-only network (for network templates)
- `ConfigOnly` - Whether network is config-only (bool, default: false)
- `Peers` - List of peer nodes for overlay networks (array, nullable)
- `EnableIPv4` - Currently hardcoded to `true`, should be configurable

**Current Model** (Sources/DockerAPI/Models/Network.swift:50-109):
```swift
public struct Network: Codable {
    public let name: String
    public let id: String
    public let created: String
    public let scope: String
    public let driver: String
    public let enableIPv6: Bool        // ✅ Present
    public let ipam: IPAM
    public let `internal`: Bool
    public let attachable: Bool
    public let ingress: Bool
    public let containers: [String: NetworkContainer]
    public let options: [String: String]
    public let labels: [String: String]

    // ❌ MISSING:
    // public let enableIPv4: Bool       // Should be configurable, not hardcoded
    // public let configFrom: ConfigReference?
    // public let configOnly: Bool
    // public let peers: [PeerInfo]?
}
```

**Priority**: Low (Swarm/overlay features not applicable to macOS single-node setup)
**Effort**: ~1 hour (add fields, update serialization, defaults)

---

### 4. Missing NetworkCreateRequest Fields

**Current Implementation** (Sources/DockerAPI/Models/Network.swift:7-31):
```swift
public struct NetworkCreateRequest: Codable {
    public let name: String
    public let checkDuplicate: Bool?    // ✅
    public let driver: String?          // ✅
    public let `internal`: Bool?        // ✅
    public let attachable: Bool?        // ✅
    public let ingress: Bool?           // ✅
    public let ipam: IPAM?             // ✅
    public let enableIPv6: Bool?       // ✅
    public let options: [String: String]?  // ✅
    public let labels: [String: String]?   // ✅

    // ❌ MISSING:
    // public let scope: String?          // e.g. "swarm", "global", "local"
    // public let configOnly: Bool?       // Create config-only network
    // public let configFrom: ConfigReference?  // Use config from another network
    // public let enableIPv4: Bool?       // Enable IPv4 (default: true)
}
```

**Priority**: Low (Swarm-specific features)
**Effort**: ~30 minutes (add fields, ignore them for now since we don't support Swarm)

---

### 5. Partial Feature Support

#### A. User-Specified IP Addresses

**Status**: ⚠️ Placeholder Only

**Current Code** (NetworkHandlers.swift:189):
```swift
let _ = endpointConfig?.ipamConfig?.ipv4Address  // TODO: Support user-specified IP addresses
```

**Spec Requirement** (DOCKER_ENGINE_v1.51.yaml:11287-11290):
```yaml
EndpointConfig:
  IPAMConfig:
    IPv4Address: "172.24.56.89"
    IPv6Address: "2001:db8::5689"
```

**What's Needed**:
- Pass `ipv4Address` to `IPAMAllocator` to check availability and reserve
- Update WireGuard/vmnet backends to use specified IP instead of auto-allocating
- Validate IP is within network subnet
- Return error if IP already in use

**Priority**: Medium (useful for predictable container IPs)
**Effort**: ~2-3 hours

#### B. MAC Address Configuration

**Status**: ❌ Not Implemented

**Spec Requirement** (DOCKER_ENGINE_v1.51.yaml:11291):
```yaml
EndpointConfig:
  MacAddress: "02:42:ac:12:05:02"
```

**Current Behavior**: MAC addresses are auto-generated (not user-configurable)

**Priority**: Very Low (auto-generated MACs work fine)
**Effort**: ~1 hour (pass through to virtualization framework)

#### C. IPv6 Support

**Status**: ❌ Not Implemented (Hardcoded to `false`)

**Current Code** (NetworkHandlers.swift:388):
```swift
enableIPv6: false,  // IPv6 not supported yet
```

**Priority**: Low (IPv6 not critical for most use cases)
**Effort**: ~5-8 hours (WireGuard IPv6 support, IPAM changes, testing)

---

## Feature Comparison

### What Works Today ✅

1. **Network Lifecycle**:
   - ✅ Create networks with custom subnets/gateways
   - ✅ List networks with filtering (name, id, driver, label)
   - ✅ Inspect network details
   - ✅ Delete networks (validates no active containers)

2. **Container Networking**:
   - ✅ Dynamic network attach/detach (WireGuard backend)
   - ✅ Multi-network containers (eth0, eth1, eth2...)
   - ✅ Full mesh peer-to-peer networking
   - ✅ Network isolation per network
   - ✅ Container aliases for DNS

3. **IPAM**:
   - ✅ Automatic IP allocation
   - ✅ Custom subnet/gateway configuration
   - ✅ IP range limiting (IPRange parameter)
   - ✅ Conflict detection

4. **Backends**:
   - ✅ WireGuard backend (default, full Docker compatibility)
   - ✅ vmnet backend (optional, high-performance)
   - ✅ null driver (for "none" network)

### What's Missing ❌

1. **Endpoints**:
   - ❌ `/networks/prune` - Delete unused networks

2. **Query Parameters**:
   - ❌ `dangling` filter (GET /networks)
   - ❌ `scope` filter (GET /networks, GET /networks/{id})
   - ❌ `type` filter (GET /networks)
   - ❌ `verbose` parameter (GET /networks/{id})

3. **Network Features**:
   - ❌ User-specified IP addresses (partially implemented)
   - ❌ User-specified MAC addresses
   - ❌ IPv6 support
   - ❌ Config-only networks (templates)
   - ❌ EnableIPv4 configuration (hardcoded to true)

4. **Response Fields**:
   - ❌ `ConfigFrom` field
   - ❌ `ConfigOnly` field
   - ❌ `Peers` field (overlay networks)
   - ❌ `EnableIPv4` field in response

---

## Implementation Recommendations

### Priority 1: High-Impact, Low-Effort (Do First) 🎯

1. **Implement `/networks/prune`** (~2-3 hours)
   - Most commonly used missing feature
   - Required by `docker network prune` and `docker system prune`
   - Straightforward implementation

2. **Add missing filters to GET `/networks`** (~1 hour)
   - `dangling` - Filter unused networks
   - `scope` - Filter by scope
   - `type` - Filter custom vs builtin

### Priority 2: Medium-Impact, Medium-Effort (Do Next) 📊

3. **User-Specified IP Addresses** (~2-3 hours)
   - Complete the TODO in `handleConnectNetwork`
   - Useful for predictable container networking
   - Required for some docker-compose configurations

4. **Add missing Network response fields** (~1 hour)
   - `EnableIPv4`, `ConfigOnly`, `ConfigFrom`, `Peers`
   - Better spec compliance
   - Low risk (optional fields, can default to nil/false)

### Priority 3: Low-Impact, Low-Effort (Nice-to-Have) 📝

5. **Add missing NetworkCreateRequest fields** (~30 minutes)
   - `scope`, `configOnly`, `configFrom`, `enableIPv4`
   - Accept and ignore for now (log warning)
   - Better error messages for unsupported features

6. **Add query parameters to GET `/networks/{id}`** (~30 minutes)
   - `verbose`, `scope`
   - Accept and ignore for now (no behavior change)

### Priority 4: Low-Impact, High-Effort (Future Work) 🔮

7. **IPv6 Support** (~5-8 hours)
   - Requires WireGuard IPv6 configuration
   - IPAM allocator changes
   - Testing complexity
   - Not critical for most use cases

8. **User-Specified MAC Addresses** (~1 hour)
   - Rarely needed
   - Auto-generated MACs work fine

---

## Testing Recommendations

When implementing the above features, test with:

1. **`/networks/prune`**:
   ```bash
   docker network create test1
   docker network create test2
   docker network prune  # Should delete both

   docker network create test3
   docker run -d --network test3 alpine sleep 1000
   docker network prune  # Should NOT delete test3 (in use)
   ```

2. **Filters**:
   ```bash
   docker network ls --filter dangling=true
   docker network ls --filter scope=local
   docker network ls --filter type=custom
   ```

3. **User-Specified IPs**:
   ```bash
   docker network create --subnet 172.20.0.0/16 mynet
   docker network connect --ip 172.20.0.10 mynet mycontainer
   docker inspect mycontainer  # Verify IP is 172.20.0.10
   ```

---

## Summary

### Current State

Arca's network implementation is **solid** with all core Docker network functionality working:
- ✅ Full CRUD operations
- ✅ Dynamic attach/detach
- ✅ Multi-network containers
- ✅ IPAM with custom subnets
- ✅ Multiple backends (WireGuard + vmnet)

### Gaps

The gaps are **minor** and mostly consist of:
- 1 missing endpoint (`/networks/prune`)
- Some optional query parameters
- A few optional response fields
- One partially implemented feature (user-specified IPs)

### Effort Estimate

| Priority | Features | Estimated Time |
|----------|----------|----------------|
| P1 (High) | `/networks/prune` + filters | 3-4 hours |
| P2 (Medium) | User IPs + response fields | 3-4 hours |
| P3 (Low) | Request fields + query params | 1 hour |
| **Total** | **Complete network API** | **~7-9 hours** |

### Recommendation

**Current implementation is production-ready** for 95% of Docker use cases. The missing features are:
- **`/networks/prune`**: Medium priority (cleanup utility)
- **User-specified IPs**: Medium priority (useful for advanced configs)
- **Other gaps**: Low priority (optional, rarely used)

Implement **Priority 1** items (~3-4 hours) to achieve ~95% Docker compatibility for networks. The remaining gaps can be addressed based on user feedback.

---

## References

- **Docker Engine API Spec**: [Documentation/DOCKER_ENGINE_v1.51.yaml](DOCKER_ENGINE_v1.51.yaml) (lines 10961-11370)
- **Current Implementation**:
  - Handlers: [Sources/DockerAPI/Handlers/NetworkHandlers.swift](../Sources/DockerAPI/Handlers/NetworkHandlers.swift)
  - Manager: [Sources/ContainerBridge/NetworkManager.swift](../Sources/ContainerBridge/NetworkManager.swift)
  - Models: [Sources/DockerAPI/Models/Network.swift](../Sources/DockerAPI/Models/Network.swift)
  - Routes: [Sources/ArcaDaemon/ArcaDaemon.swift](../Sources/ArcaDaemon/ArcaDaemon.swift) (lines 1025-1176)
