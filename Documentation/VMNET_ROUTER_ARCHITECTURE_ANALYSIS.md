# vmnet + Router-per-Network Architecture Analysis

## Architecture Overview

Instead of TAP-over-vsock + OVS, use Apple's native vmnet with a **router VM per Docker network**:

```
┌─────────────────────────────────────────────────────────────────┐
│ Container VMs (on Docker network "frontend")                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │ Container 1  │  │ Container 2  │  │ Container 3  │         │
│  │ 172.17.0.2   │  │ 172.17.0.3   │  │ 172.17.0.4   │         │
│  │ GW: .17.0.1  │  │ GW: .17.0.1  │  │ GW: .17.0.1  │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
└──────────┬──────────────┬──────────────┬───────────────────────┘
           │              │              │
           └──────────────┴──────────────┘
                          │
                  VZVmnetNetworkDeviceAttachment
                  (vmnet_network_ref #1)
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│ Router VM for "frontend" network                                │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ - vmnet interface: 172.17.0.1/16 (gateway)              │  │
│  │ - iptables NAT rules                                     │  │
│  │ - Port forwarding: -p 8080:80 → DNAT to container       │  │
│  │ - DNS server: dnsmasq for service discovery             │  │
│  │ - Loopback interface: 127.0.0.1 (for port mapping)      │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                          │
                  Route to macOS host
                          │
┌─────────────────────────┴───────────────────────────────────────┐
│ macOS Host                                                       │
│  - Access containers via router VM's NAT                        │
│  - Published ports: localhost:8080 → Router DNAT → Container   │
└─────────────────────────────────────────────────────────────────┘
```

### How It Works

1. **Create Docker network**: Spawn a Router VM with its own `vmnet_network_ref`
2. **Container creation**: Attach container to router's vmnet (via `config.interfaces`)
3. **Port mapping**: Configure iptables DNAT rules in Router VM
4. **DNS**: Router VM runs dnsmasq for container name resolution
5. **NAT**: Router VM forwards traffic to/from host

---

## What Would Work ✅

### 1. **Multiple Isolated Networks** ✅

Each Docker network gets its own Router VM + vmnet:

```swift
let frontendRouter = RouterVM(network: "frontend", subnet: "172.17.0.0/16")
let backendRouter = RouterVM(network: "backend", subnet: "172.18.0.0/16")

// Containers on different networks = different vmnets = isolated!
webContainer.config.interfaces = [frontendRouter.vmnet.create("web")]
dbContainer.config.interfaces = [backendRouter.vmnet.create("db")]
```

**Result**: ✅ Full L2 isolation (different vmnet_network_ref values)

### 2. **Port Mapping** ✅

Router VM handles port forwarding via iptables:

```bash
# Inside Router VM for "frontend" network
iptables -t nat -A PREROUTING -p tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80

# From host:
curl localhost:8080  # → Router VM → DNAT → Container 172.17.0.2:80
```

**Result**: ✅ `-p 8080:80` would work

### 3. **DNS and Service Discovery** ✅

Router VM runs dnsmasq:

```bash
# /etc/dnsmasq.conf in Router VM
interface=eth0
dhcp-range=172.17.0.2,172.17.0.254
address=/web.frontend.docker.internal/172.17.0.2
address=/api.frontend.docker.internal/172.17.0.3
```

Containers point to Router VM as DNS server:

```bash
# Inside container
cat /etc/resolv.conf
nameserver 172.17.0.1  # Router VM

ping web  # Resolves via Router's dnsmasq
```

**Result**: ✅ DNS-based service discovery works

### 4. **Network Aliases** ✅

Router VM's dnsmasq can map multiple names:

```bash
# Container with aliases: --network-alias api --network-alias backend
address=/api.frontend.docker.internal/172.17.0.2
address=/backend.frontend.docker.internal/172.17.0.2
```

**Result**: ✅ `--network-alias` works

### 5. **Static IP Assignment** ✅

Configure container with specific IP on vmnet:

```swift
let interface = VmnetNetwork.Interface(
    reference: routerVM.vmnetRef,
    address: "172.17.0.10/16",  // Static IP
    gateway: "172.17.0.1"
)
container.config.interfaces = [interface]
```

**Result**: ✅ Static IPs work

### 6. **Inter-Network Routing** ✅

Router VMs can route between networks:

```bash
# Router VM for "frontend" has route to "backend" Router VM
ip route add 172.18.0.0/16 via <backend-router-IP>

# Or use macOS host as router
# Each Router VM routes through host
```

**Result**: ✅ Cross-network communication possible (if configured)

### 7. **NAT and Internet Access** ✅

Router VM provides NAT:

```bash
# iptables in Router VM
iptables -t nat -A POSTROUTING -o eth1 -j MASQUERADE

# Containers can reach internet via Router VM
```

**Result**: ✅ Internet access works

---

## What Would NOT Work ❌

### 1. **Dynamic Network Attachment** ❌❌❌ **DEALBREAKER**

```bash
docker run -d --name web nginx              # Starts on default bridge
docker network connect my-network web       # Try to add another network
```

**Problem**: `config.interfaces` is set at VM creation and is **immutable**.

**What would be required**:
1. Stop container VM
2. Modify `config.interfaces` to add new vmnet interface
3. **Destroy and recreate VM** (VZVirtualMachineConfiguration is immutable)
4. Restart container

**Impact**: ❌ Every `docker network connect/disconnect` requires container restart

**This breaks Docker semantics**: Connecting a running container to a network should NOT restart it.

### 2. **Hot-Plug Network Interfaces** ❌❌❌ **FUNDAMENTAL LIMITATION**

Apple's Virtualization.framework does not support hot-plugging virtio devices:

```swift
// VZVirtualMachineConfiguration
let config = VZVirtualMachineConfiguration()
config.networkDevices = [device1, device2]  // Set ONCE at creation

let vm = VZVirtualMachine(configuration: config)
try await vm.start()

// CANNOT modify config.networkDevices now!
// VZVirtualMachineConfiguration is READ-ONLY after VM creation
```

**Apple's limitation**: There is no API to add/remove network devices to a running VM.

**Workarounds**:
- ❌ TAP devices inside VM? Still requires packet relay (back to our current architecture)
- ❌ Software bridges inside container? Doesn't solve hot-plug issue
- ❌ VLAN tagging on single interface? Complex, requires Router VM support

**Impact**: ❌ Cannot add interfaces to running containers

### 3. **Multiple Networks per Container - Initial Attachment Only** ⚠️ **PARTIAL**

```bash
# Works at creation time:
docker run --network net1 --network net2 --name multi alpine

# Does NOT work at runtime:
docker network connect net3 multi  # ❌ Requires restart
```

**What works**: ✅ Specify multiple networks at `docker run` time
**What doesn't**: ❌ Add/remove networks after container starts

**Impact**: ⚠️ Multi-network is static, not dynamic

### 4. **Container Pause/Unpause with Network Changes** ❌

Docker allows:
```bash
docker pause container
docker network connect my-net container  # Add network while paused
docker unpause container
```

With vmnet + Router architecture:
- ❌ Still requires VM recreation (pause doesn't help)

### 5. **Network-Scoped Operations During Container Lifetime** ❌

Scenarios that fail:

```bash
# Scenario 1: Network gets destroyed while container is running
docker network create temp-net
docker run -d --network temp-net --name worker alpine sleep 3600
docker network rm temp-net  # What happens to running container?

# With vmnet: Router VM gets destroyed
# Container's vmnet interface becomes orphaned
# No graceful degradation possible
```

```bash
# Scenario 2: Network subnet changes (hypothetical)
docker network create my-net --subnet 172.20.0.0/16
docker run -d --network my-net --name web nginx
# Later: admin wants to expand subnet to /8
# With vmnet: Would require destroying Router VM and all attached containers
```

### 6. **Container Migration** ❌

Docker Swarm / Kubernetes scenarios:

```bash
# Move container from node1 to node2 with network preserved
docker checkpoint create web checkpoint1
# Transfer checkpoint to node2
docker checkpoint restore web checkpoint1 --network my-net

# With vmnet: Network interfaces are VM-specific
# Cannot preserve vmnet attachments across restarts
```

**Impact**: ❌ Live migration not possible with vmnet

---

## Detailed Comparison: vmnet+Router vs Current Architecture

| Feature | vmnet + Router VM | Arca (TAP+OVS) | Winner |
|---------|-------------------|----------------|--------|
| **Network Lifecycle** |
| Create network | ✅ Spawn Router VM | ✅ Create OVS bridge | Tie |
| Delete network | ✅ Destroy Router VM | ✅ Delete OVS bridge | Tie |
| Network isolation | ✅ Separate vmnets | ✅ Separate OVS bridges | Tie |
| **Container Attachment** |
| Static (at creation) | ✅ config.interfaces | ✅ config.interfaces | Tie |
| Dynamic (at runtime) | ❌ **Requires restart** | ✅ **No restart** | **Arca** |
| Multi-network (creation) | ✅ Yes | ✅ Yes | Tie |
| Multi-network (runtime) | ❌ **Static only** | ✅ **Dynamic** | **Arca** |
| **DNS & Service Discovery** |
| Container name resolution | ✅ dnsmasq in Router | ✅ dnsmasq in Helper VM | Tie |
| Network aliases | ✅ dnsmasq config | ✅ dnsmasq config | Tie |
| Custom DNS servers | ✅ Via Router VM | ✅ Via Helper VM | Tie |
| **Port Mapping** |
| `-p 8080:80` | ✅ iptables in Router | ✅ OVS flows | Tie |
| Dynamic port allocation | ✅ Router manages | ✅ OVS manages | Tie |
| Host port binding | ✅ Via Router NAT | ✅ Via OVS NAT | Tie |
| **Advanced Features** |
| QoS/Rate limiting | ⚠️ tc in Router VM | ✅ OVS QoS | **Arca** |
| Traffic mirroring | ⚠️ Complex | ✅ OVS mirror | **Arca** |
| ACLs/Security groups | ⚠️ iptables | ✅ OVN ACLs | **Arca** |
| VLAN support | ❌ Not practical | ✅ OVS VLANs | **Arca** |
| Load balancing | ⚠️ Custom haproxy | ✅ OVN LB | **Arca** |
| **Performance** |
| Latency | ⚡ ~0.1-0.5ms | ⚠️ ~4-7ms | **vmnet+Router** |
| Throughput | ⚡ ~5-10 Gbps | ⚠️ ~1-2 Gbps | **vmnet+Router** |
| CPU overhead | ⚠️ Moderate (Router VM) | ⚠️ Moderate (relay) | Tie |
| Memory overhead | ⚠️ ~100MB per network | ⚠️ ~50MB (single Helper VM) | **Arca** |
| **Operational** |
| Setup complexity | ⚠️ Spawn Router per net | ⚠️ Spawn Helper VM once | **Arca** |
| Resource usage | ⚠️ N Router VMs | ✅ 1 Helper VM | **Arca** |
| Debugging | ⚠️ Per-Router logs | ✅ Centralized logs | **Arca** |
| **Docker Compatibility** |
| `docker network connect` | ❌ **Restart needed** | ✅ **No restart** | **Arca** |
| `docker network disconnect` | ❌ **Restart needed** | ✅ **No restart** | **Arca** |
| Multi-network runtime | ❌ **Static** | ✅ **Dynamic** | **Arca** |

**Critical Difference**: Dynamic network attachment requires **no container restart** with Arca, but **requires restart** with vmnet+Router.

---

## Resource Usage Analysis

### vmnet + Router-per-Network

**Per Docker network**:
- 1 Router VM: ~100MB RAM, 1 vCPU
- vmnet overhead: ~10MB (kernel structures)

**Example: 10 Docker networks**:
- Total RAM: 10 × 100MB = 1GB
- Total vCPUs: 10 × 1 = 10 vCPUs

### Arca Current (TAP+OVS)

**Total (all networks)**:
- 1 Helper VM: ~50MB RAM, 1 vCPU
- OVS overhead: ~5MB per bridge
- Example: 10 networks = 50MB + (10 × 5MB) = 100MB total

**Resource Efficiency**: Arca uses **~10x less memory** for many networks.

---

## Workarounds for Dynamic Attachment (None Work Well)

### Attempt 1: Keep VM Running, Recreate Networking?

```bash
# Idea: Don't restart VM, just reconfigure networking inside it
docker network connect my-net container

# Process:
1. VM is running
2. Somehow add new vmnet interface? ❌ NOT POSSIBLE (Virtualization.framework)
3. Fallback: Add route/tunnel inside VM? → Back to TAP devices (our current arch)
```

**Verdict**: ❌ Can't add vmnet interface to running VM

### Attempt 2: Pre-allocate Multiple vmnet Interfaces?

```bash
# Idea: Create VM with 10 vmnet interfaces, activate as needed
container.config.interfaces = [
    dummy1, dummy2, dummy3, dummy4, dummy5,  // Pre-allocated
    dummy6, dummy7, dummy8, dummy9, dummy10
]

# When connecting to network:
# - Pick an unused interface
# - Reconfigure its IP inside VM
```

**Problems**:
- ❌ Wastes resources (10 interfaces × N containers)
- ❌ Hard limit on max networks per container
- ❌ Still requires stopping VM to add more if limit reached
- ❌ Complex tracking of which interfaces are in use

**Verdict**: ❌ Hacky, wasteful, doesn't scale

### Attempt 3: Single vmnet, Software Bridges Inside Container?

```bash
# Idea: One vmnet interface, multiple VLANs/bridges inside VM
container.config.interfaces = [vmnetInterface]  // Single interface

# Inside VM: Create software bridges for each Docker network
ip link add br-net1 type bridge
ip link add br-net2 type bridge
# Tag traffic with VLANs?
```

**Problems**:
- ❌ All containers on same vmnet = no true isolation
- ❌ Requires VLAN support in Router VM
- ❌ Complex setup, defeats purpose of multiple vmnets
- ❌ Essentially recreates OVS inside each container

**Verdict**: ❌ Defeats purpose, adds complexity

---

## Performance Comparison: Detailed Analysis

### Latency Breakdown

**vmnet + Router**:
```
Container → vmnet (virtio-net) → Router VM → iptables DNAT → Target
   0.05ms         +          0.1ms        +      0.2ms       = 0.35ms
```

**Arca Current**:
```
Container → TAP → vsock → Host relay → vsock → Helper VM → OVS → Target
   0.1ms     0.5ms   2ms       0.5ms       2ms      0.5ms    1ms   = 6.6ms
```

**Arca Optimized (kqueue/epoll)**:
```
Container → TAP → vsock → Host relay → vsock → Helper VM → OVS → Target
   0.1ms     0.1ms   0.1ms     0.1ms       0.1ms    0.1ms    0.2ms = 0.7ms
```

**Comparison**:
- vmnet+Router: **0.35ms** (native performance)
- Arca Current: **6.6ms** (acceptable)
- Arca Optimized: **0.7ms** (2x vmnet, good enough)

### Throughput Breakdown

**vmnet + Router**:
- vmnet: 10+ Gbps (native virtio-net)
- Router iptables: ~5 Gbps (single CPU)
- **Effective**: ~5 Gbps

**Arca Current**:
- vsock: ~2 Gbps (vsock limitation)
- Relay: ~1.5 Gbps (polling overhead)
- **Effective**: ~1.5 Gbps

**Arca Optimized**:
- vsock: ~2 Gbps (vsock limitation)
- Relay: ~2 Gbps (event-driven)
- **Effective**: ~2 Gbps

**Comparison**:
- vmnet+Router: **5 Gbps** (better)
- Arca Current: **1.5 Gbps** (adequate)
- Arca Optimized: **2 Gbps** (good enough)

---

## Real-World Docker Use Cases

### Use Case 1: Web Application with Microservices

```bash
docker network create frontend
docker network create backend

docker run -d --name web --network frontend nginx
docker run -d --name api --network frontend --network backend api-server
docker run -d --name db --network backend postgres

# Later: Add monitoring
docker run -d --name monitor alpine
docker network connect frontend monitor  # ← Requires dynamic attachment
docker network connect backend monitor   # ← Requires dynamic attachment
```

**vmnet+Router**: ❌ Must restart `monitor` container twice
**Arca**: ✅ No restart needed

### Use Case 2: Development Environment

```bash
# Start containers
docker-compose up -d

# Developer wants to debug network issues
docker network create debug-net
docker network connect debug-net web  # Attach debugger to web container
docker network connect debug-net db   # Attach debugger to db container

# Run tcpdump on debug-net
docker run --network debug-net --rm nicolaka/netshoot tcpdump
```

**vmnet+Router**: ❌ Must restart web and db containers
**Arca**: ✅ Attach debug network without disruption

### Use Case 3: CI/CD Pipeline

```bash
# Spin up test environment
docker network create test-net
docker run -d --name app --network test-net myapp
docker run -d --name db --network test-net postgres

# Run tests
docker run --network test-net --rm test-runner

# Tests fail, need to add monitoring
docker network create monitoring
docker network connect monitoring app  # ← Add monitoring without restart
docker run --network monitoring prometheus
```

**vmnet+Router**: ❌ Restarting app loses test state
**Arca**: ✅ Add monitoring without affecting running tests

---

## Decision Matrix

| Requirement | Importance | vmnet+Router | Arca (TAP+OVS) |
|-------------|-----------|--------------|----------------|
| Docker API compatibility | **CRITICAL** | ❌ Partial | ✅ Full |
| Dynamic network attach | **CRITICAL** | ❌ Restart | ✅ No restart |
| DNS service discovery | **HIGH** | ✅ Yes | ✅ Yes |
| Port mapping | **HIGH** | ✅ Yes | ✅ Yes |
| Network isolation | **HIGH** | ✅ Yes | ✅ Yes |
| Performance (<1ms) | **MEDIUM** | ✅ Yes | ⚠️ With optimization |
| Resource efficiency | **MEDIUM** | ⚠️ N Router VMs | ✅ 1 Helper VM |
| Operational simplicity | **MEDIUM** | ⚠️ Many VMs | ✅ Single VM |
| Advanced features | **LOW** | ⚠️ Limited | ✅ Full OVS/OVN |

**Conclusion**: Arca wins on **critical requirements** (Docker compatibility, dynamic attachment).

---

## Recommendation

### DO NOT use vmnet + Router-per-Network Architecture

**Why**:
1. ❌ **Critical flaw**: Cannot dynamically attach/detach networks (requires container restart)
2. ❌ **Docker incompatibility**: `docker network connect/disconnect` semantics broken
3. ❌ **Resource inefficiency**: N Router VMs vs. 1 Helper VM
4. ❌ **Operational complexity**: Managing many Router VMs
5. ❌ **No real benefit**: Performance gain doesn't justify Docker incompatibility

### KEEP Current TAP-over-vsock + OVS Architecture

**Why**:
1. ✅ **Full Docker compatibility**: All networking features work as expected
2. ✅ **Dynamic network management**: Connect/disconnect without restart
3. ✅ **Resource efficient**: Single Helper VM for all networks
4. ✅ **Adequate performance**: Can optimize to <1ms if needed
5. ✅ **Feature-rich**: OVS/OVN provide advanced capabilities

---

## Alternative: Hybrid for Performance-Critical Cases?

**Could we use vmnet for specific high-performance containers?**

### Scenario: Database Container Needs <0.5ms Latency

```bash
# High-performance DB on vmnet
docker run --network-driver vmnet --name db postgres

# Normal containers on OVS
docker run --network my-net --name web nginx

# Problem: db and web can't communicate!
# - db is on vmnet
# - web is on OVS bridge
# - No L2 connectivity between vmnet and OVS
```

**Verdict**: ❌ Not practical due to connectivity issues

---

## Conclusion

**vmnet + Router-per-Network architecture CANNOT provide dynamic network attachment**, which is a **fundamental Docker requirement**.

The **inability to hot-plug vmnet interfaces** is a **Virtualization.framework limitation**, not something we can work around without essentially rebuilding our current TAP-based architecture.

**Keep Arca's current TAP-over-vsock + OVS architecture**:
- ✅ Meets all Docker requirements
- ✅ Dynamic network attachment works
- ✅ Resource efficient
- ✅ Performance is adequate (and optimizable)
- ✅ No architectural compromises
