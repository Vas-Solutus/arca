# VLAN + Router Architecture for Bridge Networks

## Executive Summary

This document describes Arca's dual-architecture approach to Docker networking:
- **Bridge networks** → VLAN + Simple Router (native vmnet performance)
- **Overlay networks** → OVS/OVN + TAP-over-vsock (multi-host capable)

This architecture provides native vmnet performance for 95% of use cases (bridge networks) while preserving the flexibility to support advanced features like overlay networks in the future.

## Motivation

### Problem with Current TAP-over-vsock Approach

The current implementation uses TAP devices inside container VMs with packet forwarding over vsock to a helper VM running OVS:

```
Container → TAP device → vsock → Host → vsock → Helper VM TAP → OVS bridge →
vsock → Host → vsock → TAP → Container
```

**Issues:**
- ⚠️ **Performance overhead** - Multiple userspace hops through vsock relay
- ⚠️ **Complexity** - TAP device management, vsock relay code, OVS configuration
- ⚠️ **Resource usage** - OVS/OVN processes consume ~100MB+ memory
- ⚠️ **Latency** - Estimated 2-5ms per packet (vs <1ms for native vmnet)

### Why VLANs for Bridge Networks?

Docker bridge networks have simple requirements:
- ✅ L2 isolation between networks
- ✅ Custom subnets and IP allocation
- ✅ Gateway/routing for internet access
- ✅ Port mapping for exposing services
- ✅ DNS resolution for container names

**VLANs provide all of this** with standard Linux networking:
- **L2 Isolation** - VLAN tags separate traffic
- **Routing** - Simple iptables + Linux routing
- **Performance** - Native vmnet path (hardware-accelerated)
- **Simplicity** - No OVS required

### Decision: Dual Architecture

| Network Type | Implementation | Use Case | Performance |
|-------------|---------------|----------|-------------|
| **bridge** (default) | VLAN + Router | Single-host (95% of users) | ⚡ Native vmnet |
| **overlay** | OVS/OVN + TAP | Multi-host (future) | ⚠️ vsock relay |

## Architecture Overview

### VLAN-Based Bridge Networks

```
Container A (on "frontend" network - VLAN 100):
  └─ eth0 (vmnet: 192.168.64.0/24)
       └─ eth0.100 (VLAN subinterface: 172.18.0.5/16)
          Route: default via 172.18.0.1 (helper VM router)

Container B (on "frontend" network - VLAN 100):
  └─ eth0 (vmnet: 192.168.64.0/24)
       └─ eth0.100 (VLAN subinterface: 172.18.0.10/16)
          Route: default via 172.18.0.1 (helper VM router)

Container C (on "backend" network - VLAN 200):
  └─ eth0 (vmnet: 192.168.64.0/24)
       └─ eth0.200 (VLAN subinterface: 172.19.0.8/16)
          Route: default via 172.19.0.1 (helper VM router)

Helper VM (Simple Linux Router):
  ├─ eth0 (vmnet: 192.168.64.5/24) - All VLANs arrive here
  ├─ eth0.100 (VLAN 100: 172.18.0.1/16) - "frontend" gateway
  ├─ eth0.200 (VLAN 200: 172.19.0.1/16) - "backend" gateway
  └─ IP forwarding + iptables for NAT/firewall
```

### Network Creation Flow

**1. User creates Docker network:**
```bash
docker network create --subnet 172.18.0.0/16 frontend
```

**2. Arca daemon processes request:**
```swift
func createNetwork(request: NetworkCreateRequest) async throws {
    let driver = request.Driver ?? "bridge"

    switch driver {
    case "bridge":
        // Allocate VLAN ID (e.g., 100)
        let vlanID = try await vlanAllocator.allocate()

        // Create network model
        let network = DockerNetwork(
            name: "frontend",
            driver: "bridge",
            subnet: "172.18.0.0/16",
            gateway: "172.18.0.1",
            vlanID: vlanID
        )

        // Configure helper VM router via gRPC
        try await routerClient.createVLAN(
            vlanID: vlanID,
            subnet: "172.18.0.0/16",
            gateway: "172.18.0.1"
        )

        return network

    case "overlay":
        // Use OVS/OVN (future implementation)
        return try await createOVSNetwork(request)
    }
}
```

**3. Helper VM creates VLAN interface:**
```go
// In helper VM gRPC service
func (s *RouterService) CreateVLAN(ctx context.Context, req *CreateVLANRequest) (*CreateVLANResponse, error) {
    // Create VLAN subinterface using netlink
    link, _ := netlink.LinkByName("eth0")
    vlan := &netlink.Vlan{
        LinkAttrs: netlink.LinkAttrs{
            Name:        fmt.Sprintf("eth0.%d", req.VlanID),
            ParentIndex: link.Attrs().Index,
        },
        VlanID: int(req.VlanID),
    }
    netlink.LinkAdd(vlan)

    // Configure gateway IP
    addr, _ := netlink.ParseAddr(req.Gateway + "/16")
    netlink.AddrAdd(vlan, addr)

    // Bring interface up
    netlink.LinkSetUp(vlan)

    // Configure iptables for NAT
    exec.Command("iptables", "-t", "nat", "-A", "POSTROUTING",
        "-s", req.Subnet, "-j", "MASQUERADE").Run()

    return &CreateVLANResponse{Success: true}, nil
}
```

### Container Connection Flow

**1. User connects container to network:**
```bash
docker network connect frontend my-container
```

**2. Arca daemon configures VLAN in container:**
```swift
func connectToBridgeNetwork(container: Container, network: BridgeNetwork) async throws {
    // Allocate IP from network subnet
    let ip = try allocateIP(network)  // e.g., 172.18.0.5

    // Configure VLAN via vminitd gRPC API
    try await container.dial { connection in
        let client = NetworkConfigClient(connection)
        try await client.createVLAN(
            parentInterface: "eth0",
            vlanID: network.vlanID,
            ipAddress: "\(ip)/\(network.prefixLen)",
            gateway: network.gateway
        )
    }

    // Update container network settings
    container.networks[network.name] = ContainerNetworkSettings(
        ipAddress: ip,
        gateway: network.gateway,
        macAddress: try await getContainerMAC(container, vlanID: network.vlanID)
    )
}
```

**3. vminitd creates VLAN in container VM:**
```go
// In custom vminitd (extensions/vlan-service)
func (s *NetworkConfigService) CreateVLAN(ctx context.Context, req *CreateVLANRequest) (*CreateVLANResponse, error) {
    // Get parent interface (eth0)
    link, err := netlink.LinkByName(req.ParentInterface)
    if err != nil {
        return nil, err
    }

    // Create VLAN subinterface (e.g., eth0.100)
    vlan := &netlink.Vlan{
        LinkAttrs: netlink.LinkAttrs{
            Name:        fmt.Sprintf("%s.%d", req.ParentInterface, req.VlanID),
            ParentIndex: link.Attrs().Index,
        },
        VlanID: int(req.VlanID),
    }

    if err := netlink.LinkAdd(vlan); err != nil {
        return nil, err
    }

    // Configure IP address
    addr, _ := netlink.ParseAddr(req.IpAddress)
    netlink.AddrAdd(vlan, addr)

    // Bring interface up
    netlink.LinkSetUp(vlan)

    // Add default route via gateway
    gateway := net.ParseIP(req.Gateway)
    route := &netlink.Route{
        LinkIndex: vlan.Attrs().Index,
        Dst:       nil,  // default route
        Gw:        gateway,
        Priority:  100,
    }
    netlink.RouteAdd(route)

    return &CreateVLANResponse{Success: true}, nil
}
```

### Packet Flow

**Container A → Container B (same network, VLAN 100):**
```
Container A (172.18.0.5)
  → eth0.100 (VLAN 100 tagged)
  → vmnet (VLAN tagged packet)
  → Helper VM eth0.100 (receives, checks routing table)
  → vmnet (VLAN tagged packet)
  → Container B eth0.100 (VLAN 100)
  → Container B (172.18.0.10)
```

**Container A → Internet:**
```
Container A (172.18.0.5)
  → eth0.100 (VLAN 100)
  → vmnet
  → Helper VM eth0.100 (gateway 172.18.0.1)
  → Helper VM iptables NAT
  → Host network
  → Internet
```

**Container A → Container C (different networks):**
```
Container A (172.18.0.5, VLAN 100)
  → Packet blocked (different VLANs = L2 isolation)
```

## Distroless Container Support

### Challenge

Distroless containers (e.g., `gcr.io/distroless/static`) lack shell and utilities:
- ❌ No `/bin/sh`
- ❌ No `ip` command
- ❌ Just the application binary

Traditional approach of exec'ing `ip link add ...` commands won't work.

### Solution: vminitd gRPC API

**Key Insight:** Apple's `Container.exec()` uses vminitd gRPC API over vsock, which works without a shell. We extend vminitd with network configuration RPCs.

**Why this works:**
1. vminitd runs as PID 1 in every container VM
2. vminitd is accessible via vsock (Container.dial())
3. We control vminitd (using our fork)
4. We can add gRPC services to vminitd

**Implementation:**
```protobuf
// vminitd/extensions/vlan-service/proto/network.proto
service NetworkConfig {
  rpc CreateVLAN(CreateVLANRequest) returns (CreateVLANResponse);
  rpc DeleteVLAN(DeleteVLANRequest) returns (DeleteVLANResponse);
  rpc ConfigureIP(ConfigureIPRequest) returns (ConfigureIPResponse);
  rpc AddRoute(AddRouteRequest) returns (AddRouteResponse);
}

message CreateVLANRequest {
  string parent_interface = 1;  // "eth0"
  uint32 vlan_id = 2;            // 100
  string ip_address = 3;         // "172.18.0.5/16"
  string gateway = 4;            // "172.18.0.1"
}
```

**Benefits:**
- ✅ Works in distroless containers
- ✅ No shell required
- ✅ No `ip` command required
- ✅ Clean gRPC API
- ✅ Uses netlink library directly (no subprocess calls)

## Helper VM Architecture

### Current (OVS-based)

```
Helper VM:
├─ Alpine Linux base (~100MB)
├─ OVS/OVN processes (~50MB)
│   ├─ ovs-vswitchd
│   ├─ ovsdb-server
│   └─ ovn-controller
├─ Control API (gRPC)
│   ├─ Bridge management
│   ├─ Port management
│   └─ TAP relay
└─ Dependencies
    ├─ Python (OVN)
    ├─ Database files
    └─ Flow tables
```

**Total size:** ~150MB
**Memory usage:** ~100MB+

### New (Dual Architecture)

```
Helper VM:
├─ Alpine Linux base (~20MB)
├─ Simple Router (for bridge networks)
│   ├─ VLAN interfaces (eth0.100, eth0.200, ...)
│   ├─ iptables (NAT/firewall)
│   └─ dnsmasq (DNS/DHCP per VLAN)
├─ OVS/OVN (for overlay networks - future)
│   ├─ ovs-vswitchd
│   ├─ ovsdb-server
│   └─ ovn-controller
└─ Control API (gRPC)
    ├─ VLAN management (RouterService)
    ├─ OVS management (OVNService - future)
    └─ Network selection by driver
```

**For bridge networks only:** ~30MB, ~10MB memory
**With OVS (future):** ~150MB, ~100MB+ memory

### gRPC API Design

```protobuf
// helpervm/proto/network.proto
service NetworkService {
  // Common operations
  rpc CreateNetwork(CreateNetworkRequest) returns (CreateNetworkResponse);
  rpc DeleteNetwork(DeleteNetworkRequest) returns (DeleteNetworkResponse);
  rpc InspectNetwork(InspectNetworkRequest) returns (InspectNetworkResponse);

  // Bridge-specific (VLAN)
  rpc CreateVLAN(CreateVLANRequest) returns (CreateVLANResponse);
  rpc DeleteVLAN(DeleteVLANRequest) returns (DeleteVLANResponse);
  rpc ConfigureNAT(ConfigureNATRequest) returns (ConfigureNATResponse);
  rpc ConfigureDNS(ConfigureDNSRequest) returns (ConfigureDNSResponse);

  // Overlay-specific (OVS) - future
  rpc CreateOVSBridge(CreateOVSBridgeRequest) returns (CreateOVSBridgeResponse);
  rpc CreateOVSPort(CreateOVSPortRequest) returns (CreateOVSPortResponse);
  rpc ConfigureTunnel(ConfigureTunnelRequest) returns (ConfigureTunnelResponse);
}

message CreateNetworkRequest {
  string name = 1;
  string driver = 2;  // "bridge" or "overlay"
  string subnet = 3;
  string gateway = 4;
  map<string, string> options = 5;
}
```

## Performance Comparison

### Latency

| Path | Latency | Hops |
|------|---------|------|
| **VLAN (vmnet)** | ~0.5-1ms | 2 (vmnet → router → vmnet) |
| **TAP (vsock relay)** | ~2-5ms | 6+ (vsock → host → vsock → TAP → OVS → TAP → vsock → host → vsock) |

**Improvement:** 5-10x faster for bridge networks

### Throughput

| Path | Throughput | Bottleneck |
|------|------------|------------|
| **VLAN (vmnet)** | ~5-10 Gbps | vmnet (hardware-accelerated) |
| **TAP (vsock relay)** | ~1-2 Gbps | vsock userspace relay |

**Improvement:** 5x higher throughput for bridge networks

### Resource Usage

| Component | Bridge (VLAN) | Overlay (OVS) |
|-----------|--------------|---------------|
| **Helper VM Memory** | ~10MB | ~100MB+ |
| **Helper VM Size** | ~30MB | ~150MB |
| **CPU Overhead** | Minimal | Moderate |

**Savings:** 90% less memory for bridge networks

## VLAN ID Management

### Allocation Strategy

```swift
actor VLANAllocator {
    private var allocatedVLANs: Set<UInt16> = []
    private let minVLAN: UInt16 = 100
    private let maxVLAN: UInt16 = 4094

    func allocate() async throws -> UInt16 {
        // Find next available VLAN ID
        for vlanID in minVLAN...maxVLAN {
            if !allocatedVLANs.contains(vlanID) {
                allocatedVLANs.insert(vlanID)
                return vlanID
            }
        }
        throw NetworkError.vlanExhausted
    }

    func release(_ vlanID: UInt16) async {
        allocatedVLANs.remove(vlanID)
    }
}
```

**Capacity:**
- VLAN IDs: 1-4094 (4094 total)
- Reserved: 1-99 (for special use)
- Available: 100-4094 (3995 networks)

**Sufficient for single-host use case!**

## Docker Network Features Support

### Supported Features (VLAN)

| Feature | VLAN Support | Implementation |
|---------|-------------|----------------|
| **Network isolation** | ✅ Yes | VLAN tags provide L2 isolation |
| **Custom subnets** | ✅ Yes | Configure subnet per VLAN |
| **Custom gateway** | ✅ Yes | Gateway IP on helper VM VLAN interface |
| **Internal networks** | ✅ Yes | Skip NAT iptables rules |
| **Port mapping** | ✅ Yes | iptables DNAT on helper VM |
| **DNS resolution** | ✅ Yes | dnsmasq per VLAN |
| **IPv6** | ✅ Yes | VLAN supports both IPv4/IPv6 |
| **Network connect/disconnect** | ✅ Yes | Add/remove VLAN subinterfaces dynamically |

### Future Features (Overlay)

| Feature | Overlay Support | Implementation |
|---------|----------------|----------------|
| **Multi-host networking** | 🔮 Future | OVN tunnel protocols (VXLAN, Geneve) |
| **Service mesh** | 🔮 Future | OVN ACLs and load balancing |
| **Distributed firewall** | 🔮 Future | OVN distributed ACLs |

## Implementation Phases

### Phase 3.5.5: VLAN + Router for Bridge Networks

**Goals:**
- Implement VLAN-based bridge networking
- Extend vminitd with network configuration gRPC API
- Add simple router service to helper VM
- Maintain OVS for future overlay support

**Tasks:**

**1. vminitd Extensions (vminitd submodule)**
- [ ] Create `extensions/vlan-service/` directory
- [ ] Define `network.proto` with VLAN gRPC service
- [ ] Implement VLAN service using netlink library
- [ ] Build custom vminit:latest OCI image with extensions
- [ ] Add Makefile targets for building custom vminit

**2. Helper VM Router Service (helpervm/)**
- [ ] Create `router-service/` directory
- [ ] Implement RouterService gRPC server
- [ ] Add VLAN interface management (create/delete)
- [ ] Add iptables NAT configuration
- [ ] Add dnsmasq integration for DNS
- [ ] Update helper VM Dockerfile to include router

**3. Arca Daemon Integration (Sources/ContainerBridge/)**
- [ ] Create `VLANNetworkProvider.swift`
- [ ] Create `RouterClient.swift` for gRPC communication
- [ ] Update `NetworkManager.swift` to route by driver
- [ ] Implement VLAN ID allocation
- [ ] Update container connection logic
- [ ] Add network disconnect support

**4. Testing**
- [ ] Test bridge network creation
- [ ] Test container connection/disconnection
- [ ] Test inter-container communication
- [ ] Test network isolation
- [ ] Test distroless containers
- [ ] Test port mapping
- [ ] Test DNS resolution

**5. Documentation**
- [ ] Update IMPLEMENTATION_PLAN.md
- [ ] Add user guide for VLAN networking
- [ ] Document performance characteristics
- [ ] Add troubleshooting guide

### Phase 4+: Overlay Networks (Future)

**Goals:**
- Implement multi-host networking
- Use OVS/OVN for tunnel protocols
- Support VXLAN/Geneve encapsulation

**Not in scope for Phase 3.5.5!**

## Migration Path

### Phase 1: Keep everything working (now)
- ✅ OVS works for all networks
- ✅ TAP-over-vsock works
- ✅ Current code continues to work

### Phase 2: Add VLAN option (parallel)
- ➕ Add VLANNetworkProvider
- ➕ Add VLAN gRPC methods in helper VM and vminitd
- ➕ Add routing logic to helper VM
- ✅ Both paths available via driver selection

### Phase 3: Make VLAN default for bridge
- 🔄 `driver: "bridge"` uses VLAN path
- 🔄 `driver: "overlay"` uses OVS path
- ✅ Users get best performance automatically

### Phase 4: Overlay networks (future)
- 🔮 When we need multi-host networking
- 🔮 OVS/OVN code already there and working
- 🔮 Just extend for distributed mode

## Security Considerations

### VLAN Isolation

VLANs provide strong L2 isolation:
- ✅ Containers on different VLANs cannot communicate at L2
- ✅ Helper VM routing can enforce L3 policies
- ✅ iptables rules can implement inter-network firewall

### Attack Vectors

| Attack | Mitigation |
|--------|-----------|
| **VLAN hopping** | Use proper VLAN tagging, no VLAN 1 usage |
| **ARP spoofing** | Limited to same VLAN (isolated by design) |
| **MAC flooding** | vmnet handles MAC table, not vulnerable |
| **Container escape** | VM boundary prevents escape |

### Best Practices

1. ✅ Use VLAN IDs 100-4094 (avoid reserved ranges)
2. ✅ Implement iptables rules for inter-network traffic
3. ✅ Enable logging for suspicious traffic
4. ✅ Use internal networks (no NAT) for sensitive services

## Troubleshooting

### VLAN Interface Not Created

**Symptoms:** Container starts but no eth0.X interface

**Debugging:**
```bash
# Check if vminitd gRPC is accessible
arca exec <container-id> -- ping 172.18.0.1

# Check vminitd logs
arca logs <container-id> | grep "VLAN"

# Verify helper VM VLAN exists
arca exec helper-vm -- ip link show eth0.100
```

**Common causes:**
- vminitd extension not loaded
- VLAN ID conflict
- Incorrect subnet configuration

### No Internet Connectivity

**Symptoms:** Container can ping gateway but not internet

**Debugging:**
```bash
# Check NAT rules in helper VM
arca exec helper-vm -- iptables -t nat -L -n -v

# Check routing in container
arca exec <container-id> -- ip route

# Verify DNS
arca exec <container-id> -- cat /etc/resolv.conf
```

**Common causes:**
- Missing NAT iptables rule
- Incorrect default route
- DNS not configured

### Performance Issues

**Symptoms:** Slow network performance

**Debugging:**
```bash
# Test vmnet performance
arca exec <container-id> -- ping -c 100 172.18.0.1

# Check VLAN overhead
arca exec <container-id> -- iperf3 -c <other-container-ip>
```

**Expected performance:**
- Latency: <1ms
- Throughput: >1 Gbps

## Comparison: VLAN vs TAP vs Native

| Aspect | VLAN (New) | TAP (Current) | Native vmnet Only |
|--------|-----------|--------------|------------------|
| **Performance** | ⚡ Excellent | ⚠️ Good | ⚡ Excellent |
| **Dynamic networks** | ✅ Yes | ✅ Yes | ❌ No (requires restart) |
| **Distroless support** | ✅ Yes (via vminitd) | ✅ Yes (bind-mount binary) | ❌ No |
| **Complexity** | ⚠️ Moderate | ⚠️ Moderate | ✅ Simple |
| **Multi-host** | ❌ No | ✅ Yes (with OVS) | ❌ No |
| **Resource usage** | ✅ Low | ⚠️ High (OVS) | ✅ Low |

**Verdict:** VLAN is the best of both worlds for single-host bridge networking!

## Conclusion

The VLAN + Router architecture provides:
- ✅ Native vmnet performance (5-10x faster than TAP)
- ✅ Full Docker bridge network compatibility
- ✅ Works with distroless containers (via vminitd gRPC)
- ✅ Simpler implementation (no OVS for bridge)
- ✅ Preserves OVS option for future overlay networks
- ✅ Lower resource usage (90% less memory)

This is the recommended approach for Phase 3.5.5 and beyond!
