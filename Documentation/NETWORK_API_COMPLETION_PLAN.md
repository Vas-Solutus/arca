# Docker Network API - Complete Compatibility Implementation Plan

**Created**: 2025-11-07
**Last Updated**: 2025-11-07
**Target**: 100% Docker Engine API v1.51 Network Compatibility
**Current Status**: ~95% Complete (7/7 endpoints, Phases 1-2 complete)
**Estimated Remaining Effort**: ~4-5 hours (Phases 3-5)

**Reference Documents**:
- [NETWORK_API_GAP_ANALYSIS.md](NETWORK_API_GAP_ANALYSIS.md) - Detailed gap analysis
- [DOCKER_ENGINE_v1.51.yaml](DOCKER_ENGINE_v1.51.yaml) - API specification

---

## Table of Contents

- [Overview](#overview)
- [Architecture Considerations](#architecture-considerations)
- [Phase 1: Default vmnet Network](#phase-1-default-vmnet-network)
- [Phase 2: Network Prune Endpoint](#phase-2-network-prune-endpoint)
- [Phase 3: Missing Filters & Query Parameters](#phase-3-missing-filters--query-parameters)
- [Phase 4: User-Specified IP Addresses](#phase-4-user-specified-ip-addresses)
- [Phase 5: API Model Completeness](#phase-5-api-model-completeness)
- [Phase 6: Advanced Features](#phase-6-advanced-features)
- [Testing Strategy](#testing-strategy)
- [Success Criteria](#success-criteria)

---

## Overview

### Current State

**Working Features** ✅:
- Core network CRUD (create, list, inspect, delete)
- Dynamic container attach/detach (WireGuard backend)
- Multi-network containers (eth0, eth1, eth2...)
- IPAM with custom subnets/gateways
- Network filtering (name, id, driver, label)
- Two backends: WireGuard (default), vmnet (optional)
- **Default networks: `bridge`, `vmnet`, `none`** ✅ (Phase 1 complete)
- **`/networks/prune` endpoint with filter support** ✅ (Phase 2 complete)
- **Default network deletion protection** ✅ (Phase 1 complete)

**Missing Features** ❌:
- Some query parameters (dangling, scope, type, verbose)
- User-specified IP addresses (partial implementation)
- Optional API fields (ConfigOnly, ConfigFrom, Peers, EnableIPv4)

### Goals

1. **100% Docker Network API compatibility** with v1.51 specification
2. **Default vmnet network** - Docker's "host" network equivalent for Arca
3. **Complete filter support** - All query parameters implemented
4. **Full IPAM control** - User-specified IPs and MAC addresses
5. **Production-ready** - Comprehensive testing and validation

---

## Architecture Considerations

### Default Network Types

Docker provides three default networks:
- `bridge` - Default isolated network (172.17.0.0/16)
- `host` - Direct host networking (no isolation)
- `none` - No networking (null driver)

Arca equivalents:
- `bridge` - WireGuard-based isolated network ✅ (implemented)
- `vmnet` - Native macOS networking (like Docker's `host`) ❌ (to be added)
- `none` - No networking ✅ (implemented)

### vmnet Network Architecture

**Key Requirement**: The default `vmnet` network must NOT conflict with any internal vmnet usage.

**Current vmnet Usage**:
- `VmnetNetworkBackend` - Creates user-facing vmnet networks (driver: "vmnet")
- `SharedVmnetNetwork` - Thread-safe wrapper around Containerization.VmnetNetwork
- No vmnet underlay usage by WireGuard backend (uses direct WireGuard mesh)

**Default vmnet Network Design**:
- **Name**: `vmnet` (user-visible name)
- **Driver**: `vmnet`
- **Subnet**: `192.168.67.0/24` (different from WireGuard subnets 172.x.x.x)
- **Purpose**: High-performance native networking (like Docker's host mode)
- **Isolation**: Separate from user-created vmnet networks via unique subnet
- **Creation**: On daemon startup (if not exists), stored in database
- **Deletion**: Protected (cannot delete default network)

**No Conflicts**:
- WireGuard backend doesn't use vmnet underlay
- User-created vmnet networks use different subnets (10.x.x.x auto-allocated)
- Default vmnet uses 192.168.67.0/24 (reserved range)

---

## Phase 1: Default vmnet Network

**Goal**: Add default `vmnet` network (Docker `host` equivalent)
**Priority**: HIGH
**Estimated Effort**: 2-3 hours
**Status**: ✅ COMPLETE (2025-11-07)

### Tasks

#### Task 1.1: Update NetworkManager Default Network Creation

**File**: `Sources/ContainerBridge/NetworkManager.swift`

**Changes**:
1. Add vmnet to default networks in `createDefaultNetworks()` method
2. Create default vmnet network with reserved subnet
3. Ensure vmnet backend is initialized if vmnet network created

**Code Location**: `NetworkManager.swift:75-117` (createDefaultNetworks)

**Implementation**:
```swift
private func createDefaultNetworks() async throws {
    logger.info("Creating default networks (if not exist)")

    // 1. Create "bridge" network (172.17.0.0/16 - Docker's default)
    if await getNetworkByName(name: "bridge") == nil {
        logger.info("Creating default 'bridge' network (172.17.0.0/16)")
        let _ = try await createNetwork(
            name: "bridge",
            driver: "bridge",
            subnet: "172.17.0.0/16",
            gateway: "172.17.0.1",
            ipRange: nil,
            options: [:],
            labels: [:],
            isDefault: true
        )
        logger.info("Created default 'bridge' network")
    }

    // 2. Create "vmnet" network (192.168.67.0/24 - Arca's host equivalent)
    if await getNetworkByName(name: "vmnet") == nil {
        logger.info("Creating default 'vmnet' network (192.168.67.0/24)")
        let _ = try await createNetwork(
            name: "vmnet",
            driver: "vmnet",
            subnet: "192.168.67.0/24",
            gateway: "192.168.67.1",
            ipRange: nil,
            options: [:],
            labels: [:],
            isDefault: true
        )
        logger.info("Created default 'vmnet' network")
    }

    // 3. Create "none" network (null driver - no network interfaces)
    if await getNetworkByName(name: "none") == nil {
        logger.info("Creating default 'none' network (null driver)")
        let _ = try await createNetwork(
            name: "none",
            driver: "null",
            subnet: nil,
            gateway: nil,
            ipRange: nil,
            options: [:],
            labels: [:],
            isDefault: true
        )
        logger.info("Created default 'none' network")
    }

    logger.info("Default networks created successfully")
}
```

**Expected Behavior**:
- On daemon startup, three default networks created: `bridge`, `vmnet`, `none`
- `docker network ls` shows all three by default
- Networks persisted to database (survive daemon restart)

#### Task 1.2: Prevent Default vmnet Network Deletion

**File**: `Sources/ContainerBridge/NetworkManager.swift`

**Changes**:
1. Check `isDefault` flag in `deleteNetwork()` method
2. Throw error if attempting to delete default network

**Code Location**: `NetworkManager.swift` (deleteNetwork method)

**Implementation**:
```swift
public func deleteNetwork(id: String) async throws {
    // Resolve backend and metadata
    let backend = getBackendForNetwork(id: id)

    // Get metadata to check if it's a default network
    guard let metadata = await getNetwork(id: id) else {
        throw NetworkManagerError.networkNotFound(id)
    }

    // Prevent deletion of default networks
    if metadata.isDefault {
        throw NetworkManagerError.cannotDeleteDefault(metadata.name)
    }

    // Continue with deletion...
}
```

#### Task 1.3: Update VmnetNetworkBackend Subnet Allocation

**File**: `Sources/ContainerBridge/VmnetNetworkBackend.swift`

**Changes**:
1. Reserve 192.168.67.0/24 for default vmnet network
2. Update auto-allocation to skip reserved range

**Code Location**: `VmnetNetworkBackend.swift` (allocateSubnet method)

**Implementation**:
```swift
private func allocateSubnet() throws -> String {
    // Auto-allocate from 10.0.0.0/8 space (avoid 192.168.67.0/24 reserved for default)
    // Current implementation already uses 10.x.x.x, so no changes needed
    // Just document the reservation in comments

    // Reserved subnets:
    // - 172.17.0.0/16 - Default bridge network (WireGuard)
    // - 192.168.67.0/24 - Default vmnet network
    // - 10.x.x.x - User-created vmnet networks (auto-allocated)

    // ... existing allocation logic ...
}
```

#### Task 1.4: Testing

**Test Commands**:
```bash
# 1. Start daemon
make run

# 2. Verify default networks exist
docker network ls
# Expected: bridge, vmnet, none

# 3. Inspect vmnet network
docker network inspect vmnet
# Expected: driver=vmnet, subnet=192.168.67.0/24

# 4. Create container on vmnet network
docker run -d --network vmnet --name test-vmnet nginx
docker inspect test-vmnet | grep -A 5 Networks
# Expected: Connected to vmnet network with 192.168.67.x IP

# 5. Attempt to delete default vmnet network (should fail)
docker network rm vmnet
# Expected: Error - cannot delete default network

# 6. Delete container and verify network persists
docker stop test-vmnet
docker rm test-vmnet
docker network ls
# Expected: vmnet network still exists
```

**Files to Modify**:
- `Sources/ContainerBridge/NetworkManager.swift` (~20 lines)
- `Sources/ContainerBridge/VmnetNetworkBackend.swift` (~5 lines comments)

**Acceptance Criteria**:
- ✅ `docker network ls` shows bridge, vmnet, none by default
- ✅ vmnet network uses 192.168.67.0/24 subnet
- ✅ Containers can attach to vmnet network at creation
- ✅ vmnet network survives daemon restart
- ✅ Cannot delete vmnet network (error thrown)
- ✅ No conflicts with user-created vmnet networks

---

## Phase 2: Network Prune Endpoint

**Goal**: Implement `/networks/prune` endpoint for cleanup
**Priority**: HIGH
**Estimated Effort**: 2-3 hours
**Status**: ✅ COMPLETE (2025-11-07)

### Tasks

#### Task 2.1: Add NetworkPruneResponse Model

**File**: `Sources/DockerAPI/Models/Network.swift`

**Changes**: Add response model for prune endpoint

**Implementation**:
```swift
/// Response for POST /networks/prune endpoint
public struct NetworkPruneResponse: Codable {
    public let networksDeleted: [String]

    enum CodingKeys: String, CodingKey {
        case networksDeleted = "NetworksDeleted"
    }

    public init(networksDeleted: [String]) {
        self.networksDeleted = networksDeleted
    }
}
```

**Lines Added**: ~10

#### Task 2.2: Implement handlePruneNetworks Handler

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Add prune handler method

**Implementation**:
```swift
/// Handle POST /networks/prune
/// Deletes unused networks (no containers attached)
///
/// Query parameters:
/// - filters: JSON encoded filters (until, label)
public func handlePruneNetworks(filters: [String: [String]] = [:]) async -> Result<NetworkPruneResponse, NetworkError> {
    logger.info("Handling prune networks request", metadata: ["filters": "\(filters)"])

    do {
        // Parse filters
        var untilDate: Date? = nil
        var labelFilters: [String] = []

        if let untilValues = filters["until"], let untilStr = untilValues.first {
            // Parse timestamp (Unix timestamp, RFC3339, or duration like "24h")
            untilDate = parseTimestamp(untilStr)
        }

        if let labels = filters["label"] {
            labelFilters = labels
        }

        // Get all networks from NetworkManager
        let allNetworks = await networkManager.listNetworks()

        var deletedNetworkIDs: [String] = []

        for network in allNetworks {
            // Skip default networks (bridge, vmnet, none)
            if network.isDefault {
                continue
            }

            // Skip networks with active containers
            let attachments = await networkManager.getNetworkAttachments(networkID: network.id)
            if !attachments.isEmpty {
                continue
            }

            // Apply until filter
            if let until = untilDate, network.created > until {
                continue
            }

            // Apply label filters
            if !labelFilters.isEmpty {
                let matchesLabels = labelFilters.allSatisfy { labelFilter in
                    if let (key, value) = labelFilter.split(separator: "=", maxSplits: 1).map({ String($0) }).tuple() {
                        return network.labels[key] == value
                    } else {
                        return network.labels[labelFilter] != nil
                    }
                }
                if !matchesLabels {
                    continue
                }
            }

            // Delete the network
            do {
                try await networkManager.deleteNetwork(id: network.id)
                deletedNetworkIDs.append(network.id)
                logger.info("Pruned network", metadata: ["id": "\(network.id)", "name": "\(network.name)"])
            } catch {
                logger.warning("Failed to prune network", metadata: [
                    "id": "\(network.id)",
                    "error": "\(error)"
                ])
            }
        }

        logger.info("Networks pruned", metadata: ["count": "\(deletedNetworkIDs.count)"])
        return .success(NetworkPruneResponse(networksDeleted: deletedNetworkIDs))

    } catch {
        logger.error("Failed to prune networks", metadata: ["error": "\(error)"])
        return .failure(NetworkError.listFailed(errorDescription(error)))
    }
}

/// Parse timestamp from string (Unix timestamp, RFC3339, or Go duration)
private func parseTimestamp(_ str: String) -> Date? {
    // Try Unix timestamp
    if let timestamp = TimeInterval(str) {
        return Date(timeIntervalSince1970: timestamp)
    }

    // Try RFC3339
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: str) {
        return date
    }

    // Try Go duration (e.g. "24h", "1h30m")
    if let duration = parseDuration(str) {
        return Date(timeIntervalSinceNow: -duration)
    }

    return nil
}

/// Parse Go duration string (e.g. "24h", "1h30m", "10m")
private func parseDuration(_ str: String) -> TimeInterval? {
    var remaining = str
    var totalSeconds: TimeInterval = 0

    let units: [(suffix: String, multiplier: TimeInterval)] = [
        ("h", 3600),
        ("m", 60),
        ("s", 1)
    ]

    for (suffix, multiplier) in units {
        if let range = remaining.range(of: suffix) {
            let numberStr = String(remaining[..<range.lowerBound])
            if let number = Double(numberStr) {
                totalSeconds += number * multiplier
                remaining = String(remaining[range.upperBound...])
            }
        }
    }

    return totalSeconds > 0 ? totalSeconds : nil
}
```

**Lines Added**: ~100

#### Task 2.3: Add Route Registration

**File**: `Sources/ArcaDaemon/ArcaDaemon.swift`

**Changes**: Register POST /networks/prune route

**Code Location**: After other network routes (~line 1176)

**Implementation**:
```swift
_ = builder.post("/networks/prune") { request in
    do {
        let filters = try QueryParameterValidator.parseDockerFiltersToArray(request.queryParameters["filters"])

        let result = await networkHandlers.handlePruneNetworks(filters: filters)

        switch result {
        case .success(let response):
            return .standard(HTTPResponse.ok(response))
        case .failure(let error):
            return .standard(HTTPResponse.internalServerError(error.description))
        }
    } catch {
        return .standard(HTTPResponse.badRequest("Invalid filters parameter"))
    }
}
```

**Lines Added**: ~15

#### Task 2.4: Testing

**Test Commands**:
```bash
# 1. Create test networks
docker network create test-network-1
docker network create test-network-2
docker network create test-network-3

# 2. Attach container to one network
docker run -d --network test-network-1 --name test-container alpine sleep 1000

# 3. Prune networks (should delete 2 unused)
docker network prune -f
# Expected: Deleted test-network-2, test-network-3
# Expected: test-network-1 NOT deleted (in use)

# 4. Verify networks
docker network ls
# Expected: bridge, vmnet, none, test-network-1 (test-network-2 and 3 gone)

# 5. Test with label filter
docker network create --label env=test test-labeled
docker network create --label env=prod test-prod
docker network prune --filter "label=env=test" -f
# Expected: Only test-labeled deleted

# 6. Test with until filter
docker network prune --filter "until=1h" -f
# Expected: Networks created more than 1 hour ago deleted
```

**Files to Modify**:
- `Sources/DockerAPI/Models/Network.swift` (+10 lines)
- `Sources/DockerAPI/Handlers/NetworkHandlers.swift` (+100 lines)
- `Sources/ArcaDaemon/ArcaDaemon.swift` (+15 lines)

**Acceptance Criteria**:
- ✅ `docker network prune` deletes unused networks
- ✅ Default networks (bridge, vmnet, none) NOT deleted
- ✅ Networks with active containers NOT deleted
- ✅ Label filter works correctly
- ✅ Until filter works (timestamp, RFC3339, duration)
- ✅ Returns list of deleted network IDs

---

## Phase 3: Missing Filters & Query Parameters

**Goal**: Implement all missing query parameters
**Priority**: MEDIUM
**Estimated Effort**: 1.5 hours
**Status**: 🔴 Not Started

### Tasks

#### Task 3.1: Add Missing Filters to GET /networks

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Add dangling, scope, type filters to `applyFilters()` method

**Code Location**: `NetworkHandlers.swift:311-350` (applyFilters)

**Implementation**:
```swift
private func applyFilters(_ networks: [NetworkMetadata], filters: [String: [String]]) -> [NetworkMetadata] {
    var filtered = networks

    // ... existing filters (name, id, driver, label) ...

    // Filter by dangling (networks not in use by containers)
    if let danglingValues = filters["dangling"], !danglingValues.isEmpty {
        if let dangling = Bool(danglingValues[0]) ?? (danglingValues[0] == "1" ? true : false) {
            filtered = filtered.filter { network in
                let attachments = await networkManager.getNetworkAttachments(networkID: network.id)
                return dangling ? attachments.isEmpty : !attachments.isEmpty
            }
        }
    }

    // Filter by scope (local, swarm, global)
    if let scopes = filters["scope"], !scopes.isEmpty {
        filtered = filtered.filter { network in
            // For now, all networks are "local" scope (no swarm support)
            scopes.contains("local")
        }
    }

    // Filter by type (custom, builtin)
    if let types = filters["type"], !types.isEmpty {
        filtered = filtered.filter { network in
            if types.contains("builtin") && network.isDefault {
                return true
            }
            if types.contains("custom") && !network.isDefault {
                return true
            }
            return false
        }
    }

    return filtered
}
```

**Note**: The `dangling` filter requires async access to `networkManager`, which means we need to make `applyFilters()` an async function or handle it in the handler.

**Better Approach** - Move dangling filter to handler:
```swift
public func handleListNetworks(filters: [String: [String]] = [:]) async -> Result<[Network], NetworkError> {
    let allNetworks = await networkManager.listNetworks()

    // Apply sync filters first
    var filteredMetadata = applyFilters(allNetworks, filters: filters)

    // Apply dangling filter (async)
    if let danglingValues = filters["dangling"], !danglingValues.isEmpty {
        if let dangling = parseBool(danglingValues[0]) {
            var danglingFiltered: [NetworkMetadata] = []
            for network in filteredMetadata {
                let attachments = await networkManager.getNetworkAttachments(networkID: network.id)
                let isDangling = attachments.isEmpty
                if dangling == isDangling {
                    danglingFiltered.append(network)
                }
            }
            filteredMetadata = danglingFiltered
        }
    }

    // Convert to Docker API format
    // ... existing code ...
}

private func parseBool(_ str: String) -> Bool? {
    if let boolVal = Bool(str) {
        return boolVal
    }
    if str == "1" || str.lowercased() == "true" {
        return true
    }
    if str == "0" || str.lowercased() == "false" {
        return false
    }
    return nil
}
```

**Lines Modified**: ~30

#### Task 3.2: Add Query Parameters to GET /networks/{id}

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Accept verbose and scope parameters (log warning, no behavior change for now)

**Code Location**: `NetworkHandlers.swift:61-79` (handleInspectNetwork)

**Implementation**:
```swift
public func handleInspectNetwork(
    id: String,
    verbose: Bool = false,
    scope: String? = nil
) async -> Result<Network, NetworkError> {
    logger.debug("Handling inspect network request", metadata: [
        "id": "\(id)",
        "verbose": "\(verbose)",
        "scope": "\(scope ?? "none")"
    ])

    // TODO: Implement verbose mode (include peer info, services)
    if verbose {
        logger.warning("Verbose mode not yet implemented for network inspect")
    }

    // TODO: Implement scope filtering
    if let scope = scope {
        logger.warning("Scope filtering not yet implemented", metadata: ["scope": "\(scope)"])
    }

    // ... existing implementation ...
}
```

**Route Update** in `ArcaDaemon.swift`:
```swift
_ = builder.get("/networks/{id}") { request in
    guard let id = request.pathParam("id") else {
        return .standard(HTTPResponse.badRequest("Missing network ID"))
    }

    let verbose = request.queryBool("verbose", default: false)
    let scope = request.queryString("scope")

    let result = await networkHandlers.handleInspectNetwork(
        id: id,
        verbose: verbose,
        scope: scope
    )

    // ... existing switch ...
}
```

**Lines Modified**: ~15

#### Task 3.3: Testing

**Test Commands**:
```bash
# Test dangling filter
docker network create unused-network
docker network ls --filter dangling=true
# Expected: unused-network listed

docker run -d --network unused-network --name test alpine sleep 1000
docker network ls --filter dangling=true
# Expected: unused-network NOT listed (in use)

docker network ls --filter dangling=false
# Expected: unused-network listed (in use)

# Test scope filter
docker network ls --filter scope=local
# Expected: All networks (we only support local)

# Test type filter
docker network ls --filter type=builtin
# Expected: bridge, vmnet, none

docker network ls --filter type=custom
# Expected: User-created networks only

# Test verbose and scope (inspect)
docker network inspect bridge --verbose
# Expected: Works (logs warning about verbose not implemented)

docker network inspect bridge?scope=local
# Expected: Works (logs warning about scope not implemented)
```

**Files to Modify**:
- `Sources/DockerAPI/Handlers/NetworkHandlers.swift` (~45 lines)
- `Sources/ArcaDaemon/ArcaDaemon.swift` (~10 lines)

**Acceptance Criteria**:
- ✅ Dangling filter works (true/false, 1/0)
- ✅ Scope filter works (returns local networks)
- ✅ Type filter works (builtin vs custom)
- ✅ Verbose parameter accepted (logs warning)
- ✅ Scope parameter accepted (logs warning)

---

## Phase 4: User-Specified IP Addresses

**Goal**: Complete user-specified IP address support
**Priority**: MEDIUM
**Estimated Effort**: 2-3 hours
**Status**: 🟡 Partially Implemented (TODO exists)

### Tasks

#### Task 4.1: Implement User IP Validation in WireGuard Backend

**File**: `Sources/ContainerBridge/WireGuardNetworkBackend.swift`

**Changes**: Support user-specified IPs in `attachContainerToNetwork()`

**Current Code** (WireGuardNetworkBackend.swift:~200-300):
```swift
public func attachContainerToNetwork(
    // ... parameters ...
    userSpecifiedIP: String? = nil  // NEW PARAMETER
) async throws -> NetworkAttachment {
    // ... existing code ...

    // Allocate IP for this container on this network
    let ip: String
    if let userIP = userSpecifiedIP {
        // Validate IP is within subnet
        guard isIPInSubnet(userIP, subnet: metadata.subnet) else {
            throw NetworkManagerError.invalidIPAddress("IP \(userIP) not in subnet \(metadata.subnet)")
        }

        // Check if IP is already allocated
        if let existingAttachments = containerAttachments[networkID] {
            for (_, attachment) in existingAttachments {
                if attachment.ip == userIP {
                    throw NetworkManagerError.ipAlreadyInUse(userIP)
                }
            }
        }

        // Use user-specified IP
        ip = userIP
    } else {
        // Auto-allocate IP (existing logic)
        ip = allocateIP(networkID: networkID, subnet: metadata.subnet)
    }

    // ... rest of implementation ...
}

private func isIPInSubnet(_ ip: String, subnet: String) -> Bool {
    let parts = subnet.split(separator: "/")
    guard parts.count == 2,
          let cidr = Int(parts[1]) else {
        return false
    }

    let subnetIP = String(parts[0])

    // Simple validation: parse both IPs and check they're in same network
    // This is simplified - production would use proper CIDR checking
    let ipOctets = ip.split(separator: ".").compactMap { Int($0) }
    let subnetOctets = subnetIP.split(separator: ".").compactMap { Int($0) }

    guard ipOctets.count == 4, subnetOctets.count == 4 else {
        return false
    }

    // Check first N octets match based on CIDR
    let octetsToCheck = cidr / 8
    for i in 0..<octetsToCheck {
        if ipOctets[i] != subnetOctets[i] {
            return false
        }
    }

    return true
}
```

**Lines Added**: ~50

#### Task 4.2: Update NetworkHandlers to Pass User IP

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Extract user IP from EndpointConfig and pass to backend

**Code Location**: `NetworkHandlers.swift:175-252` (handleConnectNetwork)

**Current Code** (line 189):
```swift
let _ = endpointConfig?.ipamConfig?.ipv4Address  // TODO: Support user-specified IP addresses
```

**Updated Code**:
```swift
let userIP = endpointConfig?.ipamConfig?.ipv4Address

// Attach to network via NetworkManager
let attachment = try await networkManager.attachContainerToNetwork(
    containerID: containerID,
    container: container,
    networkID: resolvedNetworkID,
    containerName: containerName,
    aliases: aliases,
    userSpecifiedIP: userIP  // NEW PARAMETER
)
```

**Lines Modified**: ~5

#### Task 4.3: Update NetworkManager to Support User IPs

**File**: `Sources/ContainerBridge/NetworkManager.swift`

**Changes**: Add userSpecifiedIP parameter to attachContainerToNetwork

**Implementation**:
```swift
public func attachContainerToNetwork(
    containerID: String,
    container: any LinuxContainer,
    networkID: String,
    containerName: String,
    aliases: [String],
    userSpecifiedIP: String? = nil  // NEW PARAMETER
) async throws -> NetworkAttachment {
    // Route to appropriate backend
    if let backend = wireGuardBackend, networkDrivers[networkID] == "bridge" {
        return try await backend.attachContainerToNetwork(
            containerID: containerID,
            container: container,
            networkID: networkID,
            containerName: containerName,
            aliases: aliases,
            userSpecifiedIP: userSpecifiedIP  // PASS THROUGH
        )
    }

    // vmnet backend doesn't support user IPs yet
    if let backend = vmnetBackend, networkDrivers[networkID] == "vmnet" {
        if userSpecifiedIP != nil {
            throw NetworkManagerError.unsupportedFeature("vmnet backend does not support user-specified IPs")
        }
        // ... existing vmnet code ...
    }

    // ... rest of implementation ...
}
```

**Lines Modified**: ~10

#### Task 4.4: Add Error Types

**File**: `Sources/ContainerBridge/NetworkTypes.swift`

**Changes**: Add new error types

**Implementation**:
```swift
public enum NetworkManagerError: Error, CustomStringConvertible {
    // ... existing errors ...
    case invalidIPAddress(String)
    case ipAlreadyInUse(String)
    case unsupportedFeature(String)

    public var description: String {
        switch self {
        // ... existing cases ...
        case .invalidIPAddress(let message):
            return "Invalid IP address: \(message)"
        case .ipAlreadyInUse(let ip):
            return "IP address \(ip) is already in use"
        case .unsupportedFeature(let message):
            return "Unsupported feature: \(message)"
        }
    }
}
```

**Lines Added**: ~15

#### Task 4.5: Testing

**Test Commands**:
```bash
# Create network with custom subnet
docker network create --subnet 172.20.0.0/16 mynet

# Test user-specified IP
docker network connect --ip 172.20.0.100 mynet mycontainer
docker inspect mycontainer | grep -A 10 Networks
# Expected: IP = 172.20.0.100

# Test IP validation (outside subnet)
docker network connect --ip 192.168.1.100 mynet mycontainer2
# Expected: Error - IP not in subnet

# Test duplicate IP
docker run -d --name container2 alpine sleep 1000
docker network connect --ip 172.20.0.100 mynet container2
# Expected: Error - IP already in use

# Test auto-allocation still works
docker network connect mynet container3
docker inspect container3 | grep -A 10 Networks
# Expected: Auto-allocated IP (e.g. 172.20.0.2)
```

**Files to Modify**:
- `Sources/ContainerBridge/WireGuardNetworkBackend.swift` (+50 lines)
- `Sources/ContainerBridge/NetworkManager.swift` (+10 lines)
- `Sources/DockerAPI/Handlers/NetworkHandlers.swift` (+5 lines)
- `Sources/ContainerBridge/NetworkTypes.swift` (+15 lines)

**Acceptance Criteria**:
- ✅ User can specify IP when connecting to network
- ✅ IP validated to be within subnet
- ✅ Error if IP already in use
- ✅ Error if IP outside subnet
- ✅ Auto-allocation still works when IP not specified
- ✅ Works for docker run --ip and docker network connect --ip

---

## Phase 5: API Model Completeness

**Goal**: Add missing fields to API models
**Priority**: LOW
**Estimated Effort**: 1 hour
**Status**: 🔴 Not Started

### Tasks

#### Task 5.1: Add Missing Network Response Fields

**File**: `Sources/DockerAPI/Models/Network.swift`

**Changes**: Add optional fields to Network struct

**Implementation**:
```swift
public struct Network: Codable {
    // ... existing fields ...

    // NEW FIELDS
    public let enableIPv4: Bool            // Enable IPv4 on network
    public let configFrom: ConfigReference?  // Config source network
    public let configOnly: Bool             // Is config-only network
    public let peers: [PeerInfo]?           // Overlay network peers

    enum CodingKeys: String, CodingKey {
        // ... existing keys ...
        case enableIPv4 = "EnableIPv4"
        case configFrom = "ConfigFrom"
        case configOnly = "ConfigOnly"
        case peers = "Peers"
    }

    public init(
        // ... existing parameters ...
        enableIPv4: Bool = true,           // NEW
        configFrom: ConfigReference? = nil, // NEW
        configOnly: Bool = false,          // NEW
        peers: [PeerInfo]? = nil           // NEW
    ) {
        // ... existing assignments ...
        self.enableIPv4 = enableIPv4
        self.configFrom = configFrom
        self.configOnly = configOnly
        self.peers = peers
    }
}

// NEW TYPES
public struct ConfigReference: Codable {
    public let network: String

    enum CodingKeys: String, CodingKey {
        case network = "Network"
    }
}

public struct PeerInfo: Codable {
    public let name: String
    public let ip: String

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case ip = "IP"
    }
}
```

**Lines Added**: ~40

#### Task 5.2: Update convertToDockerNetwork to Include New Fields

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Set new fields in conversion method

**Code Location**: `NetworkHandlers.swift:352-397` (convertToDockerNetwork)

**Implementation**:
```swift
private func convertToDockerNetwork(_ metadata: NetworkMetadata) async -> Network {
    // ... existing code ...

    return Network(
        // ... existing parameters ...
        enableIPv4: true,              // NEW - always true for now
        configFrom: nil,               // NEW - not supported yet
        configOnly: false,             // NEW - not supported yet
        peers: nil                     // NEW - no overlay networks
    )
}
```

**Lines Modified**: ~5

#### Task 5.3: Add Missing NetworkCreateRequest Fields

**File**: `Sources/DockerAPI/Models/Network.swift`

**Changes**: Add optional fields to create request

**Implementation**:
```swift
public struct NetworkCreateRequest: Codable {
    // ... existing fields ...

    // NEW FIELDS
    public let scope: String?           // Network scope (swarm, global, local)
    public let configOnly: Bool?        // Create config-only network
    public let configFrom: ConfigReference?  // Source config network
    public let enableIPv4: Bool?        // Enable IPv4

    enum CodingKeys: String, CodingKey {
        // ... existing keys ...
        case scope = "Scope"
        case configOnly = "ConfigOnly"
        case configFrom = "ConfigFrom"
        case enableIPv4 = "EnableIPv4"
    }
}
```

**Lines Added**: ~15

#### Task 5.4: Log Warnings for Unsupported Create Fields

**File**: `Sources/DockerAPI/Handlers/NetworkHandlers.swift`

**Changes**: Log warnings when unsupported fields are used

**Code Location**: `NetworkHandlers.swift:83-132` (handleCreateNetwork)

**Implementation**:
```swift
public func handleCreateNetwork(request: NetworkCreateRequest) async -> Result<NetworkCreateResponse, NetworkError> {
    // ... existing code ...

    // Log warnings for unsupported fields
    if let scope = request.scope, scope != "local" {
        logger.warning("Scope '\(scope)' not supported, using 'local'", metadata: ["network": "\(request.name)"])
    }

    if request.configOnly == true {
        logger.warning("ConfigOnly networks not supported", metadata: ["network": "\(request.name)"])
        return .failure(NetworkError.invalidRequest("ConfigOnly networks not supported"))
    }

    if request.configFrom != nil {
        logger.warning("ConfigFrom not supported", metadata: ["network": "\(request.name)"])
        return .failure(NetworkError.invalidRequest("ConfigFrom not supported"))
    }

    if request.enableIPv4 == false {
        logger.warning("Disabling IPv4 not supported", metadata: ["network": "\(request.name)"])
        return .failure(NetworkError.invalidRequest("IPv4 cannot be disabled"))
    }

    // ... continue with creation ...
}
```

**Lines Added**: ~20

#### Task 5.5: Testing

**Test Commands**:
```bash
# Verify new fields present in response
docker network inspect bridge | jq '.[] | {EnableIPv4, ConfigOnly, ConfigFrom, Peers}'
# Expected: {"EnableIPv4": true, "ConfigOnly": false, "ConfigFrom": null, "Peers": null}

# Test creating network with unsupported scope
docker network create --scope=swarm test-swarm
# Expected: Warning logged, error returned (swarm not supported)

# Test creating config-only network
docker network create --config-only test-config
# Expected: Error - ConfigOnly not supported
```

**Files to Modify**:
- `Sources/DockerAPI/Models/Network.swift` (+55 lines)
- `Sources/DockerAPI/Handlers/NetworkHandlers.swift` (+25 lines)

**Acceptance Criteria**:
- ✅ Network responses include EnableIPv4, ConfigOnly, ConfigFrom, Peers fields
- ✅ All fields properly serialized/deserialized
- ✅ Default values set correctly
- ✅ Warnings logged for unsupported create parameters
- ✅ Errors returned for truly unsupported features (ConfigOnly, etc.)

---

## Phase 6: Advanced Features (Future Work)

**Goal**: Advanced networking features
**Priority**: LOW (Future Enhancement)
**Estimated Effort**: 6-10 hours
**Status**: 🔵 Future Work

### Tasks (Not Prioritized)

#### Task 6.1: IPv6 Support (~5-8 hours)
- WireGuard IPv6 interface configuration
- Dual-stack IPAM (IPv4 + IPv6)
- IPv6 subnet allocation
- Testing with IPv6 containers

#### Task 6.2: User-Specified MAC Addresses (~1 hour)
- Pass MAC address to virtualization framework
- Validation (valid MAC format, no conflicts)

#### Task 6.3: Config-Only Networks (~2 hours)
- Network template storage
- Validation that config-only networks can't be used directly
- ConfigFrom implementation (inherit config from template)

**Note**: These features are rarely used and not critical for Docker compatibility. Implement based on user demand.

---

## Testing Strategy

### Unit Tests

**File**: `Tests/ArcaTests/NetworkAPITests.swift` (new file)

**Test Cases**:
1. Default network creation (bridge, vmnet, none)
2. Network prune (with filters)
3. User-specified IP validation
4. Filter logic (dangling, scope, type)
5. API model serialization

**Implementation**:
```swift
import XCTest
@testable import DockerAPI
@testable import ContainerBridge

final class NetworkAPITests: XCTestCase {
    func testDefaultNetworksCreated() async throws {
        // Test that all three default networks are created
        let manager = NetworkManager(...)
        try await manager.initialize()

        let networks = await manager.listNetworks()
        XCTAssertTrue(networks.contains { $0.name == "bridge" })
        XCTAssertTrue(networks.contains { $0.name == "vmnet" })
        XCTAssertTrue(networks.contains { $0.name == "none" })
    }

    func testNetworkPrune() async throws {
        // Test prune deletes unused networks
        // ...
    }

    func testUserSpecifiedIP() async throws {
        // Test user IP validation
        // ...
    }

    // ... more tests ...
}
```

### Integration Tests

**Script**: `scripts/test-network-api.sh` (new file)

**Test Scenarios**:
```bash
#!/bin/bash
set -e

echo "=== Testing Network API Compatibility ==="

# 1. Test default networks
echo "1. Verifying default networks..."
docker network ls | grep -q bridge
docker network ls | grep -q vmnet
docker network ls | grep -q none

# 2. Test network creation
echo "2. Testing network creation..."
docker network create --subnet 172.20.0.0/16 test-network

# 3. Test network prune
echo "3. Testing network prune..."
docker network create unused-1
docker network create unused-2
docker network prune -f | grep -q "unused-1"

# 4. Test filters
echo "4. Testing filters..."
docker network ls --filter type=builtin | grep -q bridge
docker network ls --filter dangling=true

# 5. Test user-specified IPs
echo "5. Testing user-specified IPs..."
docker network create --subnet 172.21.0.0/16 ip-test
docker run -d --name ip-container --network ip-test --ip 172.21.0.100 alpine sleep 1000
docker inspect ip-container | grep -q "172.21.0.100"

# 6. Test default network protection
echo "6. Testing default network protection..."
! docker network rm bridge  # Should fail
! docker network rm vmnet   # Should fail

echo "=== All tests passed! ==="
```

### Compatibility Testing

**Tools**:
- Docker CLI (test actual Docker commands)
- Docker Compose (multi-container networking)
- Buildx (builder networking)

**Test Cases**:
```bash
# Docker Compose multi-network test
cat > docker-compose.yml <<EOF
services:
  web:
    image: nginx
    networks:
      - frontend
      - backend
  db:
    image: postgres
    networks:
      - backend

networks:
  frontend:
  backend:
EOF

docker-compose up -d
docker-compose down

# Buildx builder test
docker buildx create --use --name arca-builder
docker build -t test .
docker buildx rm arca-builder
```

---

## Success Criteria

### Phase Completion Criteria

| Phase | Criteria | Validation |
|-------|----------|------------|
| Phase 1 | Default vmnet network exists | `docker network ls` shows vmnet |
| Phase 2 | Prune endpoint works | `docker network prune` deletes unused |
| Phase 3 | All filters work | `docker network ls --filter` works for all filter types |
| Phase 4 | User IPs work | `docker network connect --ip` works |
| Phase 5 | API models complete | All spec fields present in responses |

### Overall Success Criteria

**Functional**:
- ✅ All 7 network endpoints implemented (100%)
- ✅ All query parameters supported
- ✅ All API fields present
- ✅ User-specified IPs working
- ✅ Default networks (bridge, vmnet, none) created

**Compatibility**:
- ✅ `docker network` commands work without errors
- ✅ `docker-compose` networking works
- ✅ `docker buildx` networking works
- ✅ Integration test script passes 100%

**Quality**:
- ✅ Unit tests for all new functionality
- ✅ No regressions in existing tests
- ✅ Error messages match Docker format
- ✅ Logging comprehensive for debugging

---

## Implementation Timeline

### Recommended Order

**Week 1** (High Priority - 5-6 hours):
1. Phase 1: Default vmnet Network (2-3 hours)
2. Phase 2: Network Prune Endpoint (2-3 hours)

**Week 2** (Medium Priority - 3-4 hours):
3. Phase 3: Missing Filters & Query Parameters (1.5 hours)
4. Phase 4: User-Specified IP Addresses (2-3 hours)

**Week 3** (Low Priority - 1 hour):
5. Phase 5: API Model Completeness (1 hour)

**Total Time**: ~10-12 hours for 100% compatibility

### Phase 6 (Future Work):
- Implement based on user feedback and demand
- Not required for Docker compatibility
- Estimated 6-10 additional hours if needed

---

## Progress Tracking

### Phase Status

- [x] **Phase 1**: Default vmnet Network (100%) ✅ **COMPLETE**
  - [x] Task 1.1: Update NetworkManager default creation
  - [x] Task 1.2: Prevent default network deletion
  - [x] Task 1.3: Update subnet allocation
  - [x] Task 1.4: Testing

- [x] **Phase 2**: Network Prune Endpoint (100%) ✅ **COMPLETE**
  - [x] Task 2.1: Add NetworkPruneResponse model
  - [x] Task 2.2: Implement handlePruneNetworks
  - [x] Task 2.3: Add route registration
  - [x] Task 2.4: Testing

- [ ] **Phase 3**: Missing Filters & Query Parameters (0%)
  - [ ] Task 3.1: Add missing filters to GET /networks
  - [ ] Task 3.2: Add query parameters to GET /networks/{id}
  - [ ] Task 3.3: Testing

- [ ] **Phase 4**: User-Specified IP Addresses (0%)
  - [ ] Task 4.1: Implement validation in WireGuard backend
  - [ ] Task 4.2: Update NetworkHandlers
  - [ ] Task 4.3: Update NetworkManager
  - [ ] Task 4.4: Add error types
  - [ ] Task 4.5: Testing

- [ ] **Phase 5**: API Model Completeness (0%)
  - [ ] Task 5.1: Add missing Network response fields
  - [ ] Task 5.2: Update convertToDockerNetwork
  - [ ] Task 5.3: Add missing NetworkCreateRequest fields
  - [ ] Task 5.4: Log warnings for unsupported fields
  - [ ] Task 5.5: Testing

- [ ] **Phase 6**: Advanced Features (Future)
  - [ ] Task 6.1: IPv6 Support
  - [ ] Task 6.2: User-Specified MAC Addresses
  - [ ] Task 6.3: Config-Only Networks

---

## References

- [NETWORK_API_GAP_ANALYSIS.md](NETWORK_API_GAP_ANALYSIS.md) - Detailed gap analysis
- [DOCKER_ENGINE_v1.51.yaml](DOCKER_ENGINE_v1.51.yaml) - API specification (lines 10961-11370)
- [Docker Network Documentation](https://docs.docker.com/engine/api/v1.51/#tag/Network)

---

## Notes

### Architecture Decisions

1. **Default vmnet Network**: Uses dedicated subnet (192.168.67.0/24) to avoid conflicts
2. **No vmnet Underlay**: WireGuard doesn't use vmnet underlay, so no conflicts possible
3. **Filter Implementation**: Async dangling filter handled in handler (not applyFilters)
4. **User IP Validation**: Implemented in WireGuard backend (vmnet doesn't support yet)
5. **Unsupported Features**: Log warnings but don't block (graceful degradation)

### Future Enhancements

If user demand arises:
- IPv6 full support (currently hardcoded to false)
- MAC address control (currently auto-generated)
- Config-only network templates
- Overlay network support (requires multi-host architecture)
- Swarm networking features (not applicable to single-node macOS)

---

**Last Updated**: 2025-11-07
**Status**: Phases 1-2 Complete (Default vmnet Network, Network Prune Endpoint)
**Next Step**: Phase 3 (Missing Filters & Query Parameters) - Estimated 1.5 hours

### Completed Phases Summary

**Phase 1: Default vmnet Network** ✅
- Added default `vmnet` network (192.168.67.0/24) alongside `bridge` and `none`
- Implemented deletion protection for all default networks
- Documented reserved subnet ranges
- All tests passing

**Phase 2: Network Prune Endpoint** ✅
- Implemented `/networks/prune` endpoint with filter support (label, until)
- Added timestamp parsing (Unix, RFC3339, Go duration formats)
- Protects default networks and networks with active containers
- All tests passing (basic prune, active containers, label filtering)
