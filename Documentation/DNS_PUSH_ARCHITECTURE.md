# DNS Push Architecture

## Overview

Arca implements **direct push** architecture for distributing DNS topology updates to containers. When containers join/leave networks or start/stop, the Arca daemon pushes updated DNS mappings by calling the existing tap-forwarder gRPC service over vsock.

This reuses the existing tap-forwarder infrastructure (originally built for TAP device management) by adding one new RPC method: `UpdateDNSMappings`.

## Architecture Components

```
┌─────────────────────────────────────────────────────────────┐
│                      Arca Daemon (Host)                      │
│                                                               │
│  ContainerManager                                            │
│    - Tracks network topology                                 │
│    - Detects container lifecycle events                      │
│    - Triggers DNS updates                                    │
│                                                               │
│  TAPForwarderClient (Swift gRPC client)                      │
│    - AttachNetwork()      ← existing                         │
│    - DetachNetwork()      ← existing                         │
│    - UpdateDNSMappings()  ← NEW                              │
│                                                               │
└───────────────────────────┬───────────────────────────────────┘
                            │
                            │ vsock port 5555
                            │ Host→Container only
                            │
┌───────────────────────────▼───────────────────────────────────┐
│                      Container VM                             │
│                                                               │
│  arca-tap-forwarder (gRPC server on vsock 5555)              │
│    - AttachNetwork()      → creates TAP device               │
│    - DetachNetwork()      → destroys TAP device              │
│    - UpdateDNSMappings()  → forwards to embedded-DNS         │
│             │                                                 │
│             │ Unix socket: /tmp/arca-dns-control.sock        │
│             ▼                                                 │
│  arca-embedded-dns                                            │
│    - DNS server on 127.0.0.11:53                             │
│    - Receives topology updates                               │
│    - Resolves container names                                │
│                                                               │
└───────────────────────────────────────────────────────────────┘
```

## Key Insight: Extending Existing Infrastructure

**tap-forwarder is already a gRPC server** that the daemon calls to manage TAP network devices. We simply added one more RPC method to the existing service definition. This means:

- ✅ No new communication channel needed
- ✅ No new vsock port required
- ✅ Reuses existing connection infrastructure
- ✅ tap-forwarder is already running in every container (part of vminit)

## How It Works

### Phase 1: TAP Device Management (Already Working)

When a container joins a network:

1. **Daemon → tap-forwarder**: `AttachNetwork(device="tap0", vsock_port=6000, ip="10.0.1.2")`
2. **tap-forwarder**: Creates TAP device, configures IP, starts packet forwarding
3. **Result**: Container has network connectivity

### Phase 2: DNS Topology Push (NEW)

When network topology changes (container start/stop/join/leave):

1. **Daemon builds snapshot**: All containers on networks this container is attached to
2. **Daemon → tap-forwarder**: `UpdateDNSMappings(networks={...})`
3. **tap-forwarder → embedded-DNS**: Converts protobuf to JSON, sends via Unix socket
4. **embedded-DNS**: Updates in-memory DNS resolution table
5. **Result**: Container can resolve names of other containers on its networks

## Implementation Status

### ✅ Already Implemented (Phase 3.5.1)

- [x] Added `UpdateDNSMappings` RPC to tap-forwarder proto
- [x] Implemented RPC handler in tap-forwarder (Go)
- [x] Handler converts protobuf → JSON and forwards to embedded-DNS
- [x] embedded-DNS control server receives JSON via Unix socket
- [x] embedded-DNS updates local DNS mappings
- [x] embedded-DNS resolves container names using mappings
- [x] Added `updateDNSMappings()` method to TAPForwarderClient (Swift)

### 🚧 TODO: Topology Publisher (Phase 3.5.2)

Implement in `ContainerManager.swift`:

```swift
/// Push DNS topology to a container after network changes
func pushDNSTopologyUpdate(to dockerID: String) async {
    // 1. Get container's networks
    guard let networks = getContainerNetworks(dockerID) else {
        logger.warning("Cannot push DNS: container not found")
        return
    }

    // 2. Build topology snapshot for this container
    var mappings: [String: Arca_Tapforwarder_V1_NetworkPeers] = [:]
    for networkName in networks {
        let peers = getContainersOnNetwork(networkName)
        mappings[networkName] = Arca_Tapforwarder_V1_NetworkPeers(
            containers: peers.map { peer in
                Arca_Tapforwarder_V1_ContainerDNSInfo(
                    name: peer.name,
                    id: peer.dockerID,
                    ipAddress: peer.ipAddress,
                    aliases: peer.aliases
                )
            }
        )
    }

    // 3. Dial container and push
    guard let nativeContainer = nativeContainers[dockerID] else { return }

    do {
        let client = try await TAPForwarderClient.connect(
            container: nativeContainer,
            port: 5555,
            logger: logger
        )
        let response = try await client.updateDNSMappings(networks: mappings)
        logger.info("DNS topology pushed successfully", metadata: [
            "container": dockerID,
            "records": "\(response.recordsUpdated)"
        ])
    } catch {
        logger.error("Failed to push DNS topology", metadata: [
            "container": dockerID,
            "error": "\(error)"
        ])
    }
}

// Call this method:
// - After container starts
// - After network attach/detach
// - When another container on same network starts/stops/joins/leaves
```

### Trigger Points

DNS topology updates must be pushed when:

1. **Container starts**: Push topology to new container
2. **Container stops**: Push updates to all containers on its networks (remove stopped container)
3. **Network attach**: Push updated topology to container (add new network's containers)
4. **Network detach**: Push updated topology to container (remove network's containers)
5. **Cascading updates**: When container A starts, push updates to all containers on A's networks (add A to their view)

## Protocol Definitions

### gRPC (tap-forwarder)

`containerization/vminitd/extensions/tap-forwarder/proto/tapforwarder.proto`:

```protobuf
service TAPForwarder {
    // Existing methods
    rpc AttachNetwork(AttachNetworkRequest) returns (AttachNetworkResponse);
    rpc DetachNetwork(DetachNetworkRequest) returns (DetachNetworkResponse);
    rpc ListNetworks(ListNetworksRequest) returns (ListNetworksResponse);
    rpc GetStatus(GetStatusRequest) returns (GetStatusResponse);

    // NEW: DNS topology push
    rpc UpdateDNSMappings(UpdateDNSMappingsRequest) returns (UpdateDNSMappingsResponse);
}

message UpdateDNSMappingsRequest {
    // Complete network topology for this container
    // Maps network name → peers on that network
    map<string, NetworkPeers> networks = 1;
}

message NetworkPeers {
    repeated ContainerDNSInfo containers = 1;
}

message ContainerDNSInfo {
    string name = 1;           // Container name (for DNS)
    string id = 2;             // Docker container ID
    string ip_address = 3;     // IP on this network
    repeated string aliases = 4; // Hostname aliases
}

message UpdateDNSMappingsResponse {
    bool success = 1;
    string error = 2;
    uint32 records_updated = 3;
}
```

### JSON (embedded-DNS)

`containerization/vminitd/extensions/embedded-dns/internal/dns/control.go`:

```json
{
  "networks": {
    "network-name": {
      "containers": [
        {
          "name": "container-name",
          "id": "docker-container-id-64-chars",
          "ip_address": "10.0.1.2",
          "aliases": ["alias1", "alias2"]
        }
      ]
    }
  }
}
```

## Design Principles

### Reuse: Extend Don't Duplicate

- **One gRPC server per container**: tap-forwarder already runs, just add one RPC
- **One vsock port**: Port 5555 already allocated for tap-forwarder
- **One connection**: TAPForwarderClient can handle both TAP and DNS operations

### Security: vsock Isolation

- **Unidirectional**: Only host→container communication
- **No TCP exposure**: Control plane stays off container networks
- **Per-container scope**: Each container only sees its own networks

### Simplicity: Complete Snapshots

- **No deltas**: Send full topology eliminates synchronization bugs
- **Idempotent**: Safe to retry on failure
- **Stateless**: embedded-DNS doesn't track versions or sequence numbers

## Testing

### Unit Tests

```swift
func testBuildDNSTopology() {
    // Container on networks "web" and "db"
    let topology = containerManager.buildDNSTopology(for: "container1")
    XCTAssertEqual(topology["web"]?.containers.count, 2)  // nginx, container1
    XCTAssertEqual(topology["db"]?.containers.count, 2)   // postgres, container1
}

func testPushDNSTopology() async {
    await containerManager.pushDNSTopologyUpdate(to: "container1")
    // Verify TAPForwarderClient.updateDNSMappings was called
}
```

### Integration Test

```bash
# Create networks
docker network create web
docker network create db

# Create containers on separate networks
docker run -d --name nginx --network web nginx:latest
docker run -d --name postgres --network db postgres:latest

# Create multi-network container
docker run -d --name app --network web alpine:latest sleep infinity
docker network connect db app

# Verify DNS resolution
docker exec app nslookup nginx      # ✓ Should resolve (on web)
docker exec app nslookup postgres   # ✓ Should resolve (on db)
docker exec nginx nslookup postgres # ✗ Should fail (not on db)

# Test dynamic updates
docker run -d --name api --network web nginx:latest
docker exec app nslookup api        # ✓ Should resolve (new container)
```

## Troubleshooting

**DNS not resolving:**

1. Verify tap-forwarder is running: `docker exec <container> ps aux | grep arca-tap-forwarder`
2. Verify embedded-DNS is running: `docker exec <container> ps aux | grep arca-embedded-dns`
3. Check control socket exists: `docker exec <container> ls -la /tmp/arca-dns-control.sock`
4. Check daemon logs for `UpdateDNSMappings` gRPC calls
5. Check tap-forwarder logs for RPC handler execution

**Stale DNS mappings:**

1. Check if topology publisher is triggered on container lifecycle events
2. Verify gRPC response shows success
3. Check embedded-DNS logs for control server updates
4. Force update by restarting container or re-attaching network

## References

- **tap-forwarder proto**: `containerization/vminitd/extensions/tap-forwarder/proto/tapforwarder.proto`
- **tap-forwarder main**: `containerization/vminitd/extensions/tap-forwarder/cmd/arca-tap-forwarder/main.go`
- **embedded-DNS control**: `containerization/vminitd/extensions/embedded-dns/internal/dns/control.go`
- **TAPForwarderClient**: `Sources/ContainerBridge/TAPForwarderClient.swift`
- **ContainerManager**: `Sources/ContainerBridge/ContainerManager.swift`
- **vsock constraints**: See `CLAUDE.md` - only host→container via `Container.dialVsock()`
