# Network Architecture: OVN Native DHCP/DNS

## 🚨 ARCHITECTURAL PIVOT (In Progress)

**Status**: Migrating from custom IPAM + dnsmasq to OVN's native DHCP/DNS capabilities

**Why this change**:
- OVN has built-in DHCP server and DNS - we were reinventing the wheel
- Eliminates ~1000+ lines of custom IP allocation and DNS configuration code
- Network-scoped DNS works automatically without manual cross-network propagation
- Standard DHCP protocol means less code to maintain and debug
- Leverages solved problems instead of reimplementing them

**What's changing**:
- ❌ **Removing**: Custom Go IPAM code (PortAllocator, IP tracking maps)
- ❌ **Removing**: dnsmasq configuration and per-network instance management
- ❌ **Removing**: Manual DNS record management and cross-network DNS propagation
- ✅ **Adding**: OVN DHCP configuration via `ovn-nbctl ls-add` and `ovn-nbctl dhcp-options-create`
- ✅ **Adding**: OVN DNS records via `ovn-nbctl set logical_switch_port`
- ✅ **Adding**: Container DHCP client configuration (udhcpc/dhclient)

**What stays the same**:
- ✅ TAP-over-vsock architecture (containers ↔ helper VM communication)
- ✅ OVS bridges and OVN logical switches
- ✅ Helper VM lifecycle management
- ✅ gRPC control API (but simplified methods)

---

## Executive Summary

Arca provides **two network backends** that users can choose between via configuration:

### **1. OVS Backend (Default)** - Full Docker Compatibility
- ✅ **Complete Docker Network API** - All features work exactly like Docker
- ✅ **Dynamic network attachment** - `docker network connect/disconnect` works after container creation
- ✅ **Multi-network containers** - Attach to multiple networks (eth0, eth1, eth2...)
- ✅ **Port mapping** - Publish ports with `-p` flag (DNAT via OVS)
- ✅ **Overlay networks** - VXLAN-based multi-host networking via OVN
- ✅ **Network isolation** - True Layer 2 isolation between networks
- ⚠️ **Performance**: ~4-7ms latency (acceptable for development)

### **2. vmnet Backend (Optional)** - High Performance
- ✅ **Native Apple networking** - Uses vmnet.framework directly
- ✅ **Low latency** - ~0.5ms (10x faster than OVS)
- ✅ **Simple architecture** - No helper VM needed
- ❌ **Limited features** - Must specify `--network` at `docker run` time
- ❌ **No dynamic attachment** - Cannot use `docker network connect/disconnect`
- ❌ **Single network only** - Containers can only join ONE network
- ❌ **No port mapping** - `-p` flag not supported
- ❌ **No overlay networks** - Bridge networks only

---

## Configuration

Users select the backend via `~/.arca/config.json`:

```json
{
  "networkBackend": "ovs",  // Options: "ovs" (default) or "vmnet"
  "kernelPath": "~/.arca/vmlinux",
  "socketPath": "/var/run/arca.sock",
  "logLevel": "info"
}
```

---

## Network Driver Types

Both backends support explicit driver selection per network:

```bash
# Uses configured backend (ovs by default)
docker network create my-network

# Explicitly use OVS (always available)
docker network create --driver bridge my-network

# Explicitly use vmnet (high performance)
docker network create --driver vmnet fast-network

# Overlay networks (OVS only)
docker network create --driver overlay multi-host-network
```

---

## OVS Backend Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ macOS Host                                                          │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ Arca Daemon                                                │   │
│  │  - Docker API Server (SwiftNIO)                            │   │
│  │  - NetworkManager (OVS Backend)                            │   │
│  │  - NetworkBridge (vsock relay)                             │   │
│  │  - ContainerManager                                        │   │
│  └────────────────────────────────────────────────────────────┘   │
│           ↓ vsock relay         ↓ vsock relay                      │
│  ┌─────────────┐      ┌─────────────┐                             │
│  │ Container 1 │      │ Container 2 │                             │
│  │  TAP: eth0  │      │  TAP: eth0  │                             │
│  │  TAP: eth1  │      │  TAP: eth1  │                             │
│  └──────┬──────┘      └──────┬──────┘                             │
│         │ vsock              │ vsock                               │
│         └────────┬───────────┘                                     │
│                  ↓                                                 │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ Helper VM (Alpine Linux)                                   │   │
│  │  ┌──────────────────────────────────────────────────────┐  │   │
│  │  │ OVS Bridges                                          │  │   │
│  │  │  - br-network-a (172.18.0.0/16)                      │  │   │
│  │  │  - br-network-b (172.19.0.0/16)                      │  │   │
│  │  └──────────────────────────────────────────────────────┘  │   │
│  └────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### Components

#### 1. arca-tap-forwarder (Container Init System)
- **Location**: Embedded in custom vminit:latest image
- **Build**: Go binary cross-compiled to Linux ARM64
- **Purpose**: Create TAP devices dynamically, forward packets over vsock
- **gRPC API**: Listens on vsock:5555 for AttachNetwork/DetachNetwork commands
- **Data Plane**: Bidirectional forwarding between TAP devices and vsock

#### 2. NetworkBridge (Host Relay)
- **Location**: Arca daemon
- **Purpose**: Relay packets between containers and helper VM
- **Pattern**: Container ←vsock→ Host ←vsock→ Helper VM
- **Port Allocation**: 20000+ for containers, 30000+ for helper VM

#### 3. Helper VM (OVS/OVN)
- **Image**: Alpine Linux + OVS + OVN stack
- **Kernel**: Custom build with CONFIG_TUN=y
- **Control API**: Go gRPC server on vsock:9999
- **Features**: Bridge networks, SNAT, routing, firewalls, VXLAN overlays

### Packet Flow: Container A → Container B

```
Container A eth0 (TAP)
    ↓ arca-tap-forwarder reads
Container A vsock:20001 → Host NetworkBridge
    ↓ relay
Host → Helper VM vsock:30001
    ↓ TAPRelay writes to OVS port
OVS Bridge br-network-a
    ↓ MAC learning/forwarding
OVS Port for Container B
    ↓ TAPRelay reads
Helper VM vsock:30002 → Host NetworkBridge
    ↓ relay
Host vsock:20002 → Container B
    ↓ arca-tap-forwarder writes
Container B eth0 (TAP) → Application
```

**Latency**: ~4-7ms round-trip (4 vsock hops + OVS switching)

### Features

✅ Dynamic network attach/detach
✅ Multi-network containers
✅ Port mapping via OVS DNAT
✅ Network isolation via separate OVS bridges
✅ SNAT for internet access
✅ DNS resolution (via OVN native DNS)
✅ DHCP (via OVN native DHCP server)
✅ Future: VXLAN overlay networks

---

## OVN Native DHCP/DNS Design

### Overview

Instead of custom IPAM and dnsmasq, Arca leverages OVN's built-in DHCP and DNS capabilities:

**OVN DHCP Server**:
- Each OVN logical switch has DHCP options configured
- Containers use standard DHCP client (udhcpc/dhclient)
- DHCP packets flow through TAP-over-vsock like all other traffic
- OVN responds to DHCP DISCOVER/REQUEST with IP lease

**OVN DNS**:
- DNS records stored in OVN Northbound database
- Network-scoped automatically (each logical switch has own DNS)
- Records added via `ovn-nbctl set logical_switch_port` commands
- DNS queries resolved by OVN's built-in DNS responder

### DHCP Flow

```
1. Container boots
   ↓
2. DHCP client (udhcpc) sends DHCP DISCOVER broadcast
   ↓ TAP device → arca-tap-forwarder → vsock
   ↓ NetworkBridge relay → Helper VM vsock
   ↓ TAPRelay → OVS port
   ↓
3. OVN logical switch receives DHCP DISCOVER
   ↓ OVN checks DHCP options for this logical switch
   ↓ Allocates IP from subnet range (or uses reservation)
   ↓
4. OVN sends DHCP OFFER
   ↓ OVS port → TAPRelay → vsock
   ↓ NetworkBridge relay
   ↓ TAP device → container
   ↓
5. Container sends DHCP REQUEST
   ↓ (same path as step 2)
   ↓
6. OVN sends DHCP ACK with IP configuration
   ↓ IP address, subnet mask, gateway, DNS server
   ↓ Container configures interface
```

### DNS Flow

```
Container: nslookup container2
   ↓ DNS query to nameserver (OVN logical switch IP)
   ↓ TAP → arca-tap-forwarder → vsock → NetworkBridge
   ↓ Helper VM → TAPRelay → OVS port
   ↓
OVN Logical Switch DNS Responder
   ↓ Looks up "container2" in logical switch DNS records
   ↓ Returns IP address (network-scoped)
   ↓
Response flows back through same path
```

### OVN Configuration Commands

**Create network with DHCP**:
```bash
# Create logical switch
ovn-nbctl ls-add <network-id>

# Create DHCP options
ovn-nbctl dhcp-options-create <subnet>

# Set DHCP options (IP range, gateway, DNS)
ovn-nbctl dhcp-options-set-options <uuid> \
  lease_time=3600 \
  router=<gateway-ip> \
  server_id=<gateway-ip> \
  server_mac=<gateway-mac> \
  dns_server=<gateway-ip>

# Link DHCP options to logical switch
ovn-nbctl set logical_switch <network-id> \
  other_config:subnet=<subnet> \
  other_config:exclude_ips=<gateway-ip>
```

**Attach container with DNS record**:
```bash
# Create logical switch port
ovn-nbctl lsp-add <network-id> <container-port-name>

# Set port type and addresses (optional static IP)
ovn-nbctl lsp-set-addresses <container-port-name> \
  "<mac-address> <ip-address>"  # Or "dynamic" for DHCP

# Add DNS record for container hostname
ovn-nbctl set logical_switch <network-id> \
  dns_records='{"<hostname>": "<ip-address>"}'

# Enable DHCP on port
ovn-nbctl lsp-set-dhcpv4-options <container-port-name> <dhcp-options-uuid>
```

**DHCP Reservation** (for containers with explicit IP):
```bash
# Reserve specific IP for MAC address
ovn-nbctl dhcp-options-add-option <uuid> \
  reserved_addresses="{<mac-address>=<ip-address>}"
```

### Multi-Network Containers

When a container joins multiple networks:

1. **Each network has its own DHCP scope**
   - eth0 gets DHCP from network-a
   - eth1 gets DHCP from network-b

2. **DNS is network-scoped**
   - Query via network-a's DNS → returns IPs from network-a
   - Query via network-b's DNS → returns IPs from network-b

3. **No cross-network DNS propagation needed**
   - OVN handles network isolation automatically
   - Each logical switch maintains its own DNS records

### Migration from Custom IPAM/dnsmasq

**Code to Remove**:
- `helpervm/control-api/server.go:dnsEntries` map
- `helpervm/control-api/server.go:containerIPs` map
- `helpervm/control-api/server.go:writeDnsmasqConfig()`
- `helpervm/control-api/server.go:configureDNS()`
- All dnsmasq process management code
- `Sources/ContainerBridge/IPAMAllocator.swift` (entire file)
- `Sources/ContainerBridge/OVSNetworkBackend.swift:portAllocator`

**Code to Add**:
- `ovn-nbctl dhcp-options-create` in CreateBridge
- `ovn-nbctl lsp-add` and `lsp-set-dhcpv4-options` in AttachContainer
- `ovn-nbctl set logical_switch dns_records` for DNS
- Container DHCP client configuration (udhcpc in Alpine-based containers)

**Swift Changes**:
- `OVSNetworkBackend.attachToNetwork()`: Remove static IP assignment, let DHCP handle it
- `NetworkHelperVM`: Remove dnsmasq startup code
- `OVNClient`: Add methods for DHCP options and DNS record management

---

## vmnet Backend Architecture

### High-Level Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│ macOS Host                                                          │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ Arca Daemon                                                │   │
│  │  - NetworkManager (vmnet Backend)                          │   │
│  │  - VmnetNetworkBackend                                     │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  VmnetNetwork: network-a (172.18.0.0/16)                           │
│         ↓             ↓                                             │
│  ┌─────────────┐  ┌─────────────┐                                 │
│  │ Container 1 │  │ Container 2 │                                 │
│  │  eth0 via   │  │  eth0 via   │                                 │
│  │  vmnet IF   │  │  vmnet IF   │                                 │
│  └─────────────┘  └─────────────┘                                 │
│                                                                     │
│  VmnetNetwork: network-b (172.19.0.0/16)                           │
│         ↓                                                           │
│  ┌─────────────┐                                                   │
│  │ Container 3 │                                                   │
│  │  eth0 via   │                                                   │
│  │  vmnet IF   │                                                   │
│  └─────────────┘                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### Components

#### 1. VmnetNetworkBackend
- **Purpose**: Create and manage VmnetNetwork instances
- **Pattern**: One `SharedVmnetNetwork` per Docker network
- **Interface Allocation**: Each container gets one `Interface` from its network's vmnet
- **Limitations**: Interfaces must be configured at container creation time

#### 2. SharedVmnetNetwork
- **Purpose**: Wrapper around `Containerization.ContainerManager.VmnetNetwork`
- **Thread Safety**: Uses NSLock for synchronized IP allocation
- **Reason**: VmnetNetwork is a struct; copies get independent allocators causing IP conflicts

### Packet Flow: Container A → Container B (Same Network)

```
Container A eth0 (virtio-net backed by vmnet Interface)
    ↓ kernel networking stack
vmnet.framework (kernel-level L2 switch)
    ↓ MAC learning/forwarding
Container B eth0 (virtio-net backed by vmnet Interface)
    ↓ kernel networking stack
Container B Application
```

**Latency**: ~0.5ms round-trip (native kernel switching)

### Limitations

❌ **No dynamic attach** - `VZVirtualMachineConfiguration` is immutable after `vm.start()`
❌ **Single network only** - Containers can only have ONE interface
❌ **No port mapping** - No NAT/DNAT functionality
❌ **Subnet-based isolation only** - Networks isolated by IP ranges, not true L2 separation
❌ **No overlay networks** - Bridge networks only

### When to Use vmnet Backend

✅ **Low-latency requirements** - Microservices with tight latency budgets
✅ **Simple use cases** - Single network per container
✅ **Performance testing** - Benchmarking network-intensive applications
✅ **No dynamic networking** - Containers don't change networks during lifetime

---

## Backend Comparison

| Feature | OVS Backend | vmnet Backend |
|---------|-------------|---------------|
| **Latency** | ~4-7ms | ~0.5ms |
| **Dynamic attach** | ✅ Yes | ❌ No |
| **Multi-network** | ✅ Yes | ❌ No |
| **Port mapping** | ✅ Yes | ❌ No |
| **Overlay networks** | ✅ Yes | ❌ No |
| **Network isolation** | ✅ L2 (OVS bridges) | ⚠️ L3 (subnets) |
| **Helper VM required** | ✅ Yes | ❌ No |
| **Custom vminit** | ✅ Required | ⚠️ Optional (stock works) |
| **Resource usage** | Higher (helper VM) | Lower (no helper VM) |
| **Docker compatibility** | ✅ 100% | ⚠️ Limited |
| **Setup complexity** | Higher | Lower |

---

## Implementation Details

### OVS Backend Components

**Files:**
- `Sources/ContainerBridge/OVSNetworkBackend.swift` - OVS backend implementation
- `Sources/ContainerBridge/NetworkBridge.swift` - vsock relay actor
- `Sources/ContainerBridge/NetworkHelperVM.swift` - Helper VM lifecycle
- `Sources/ContainerBridge/OVNClient.swift` - gRPC client for OVS control
- `arca-tap-forwarder-go/` - TAP device forwarder (Go, embedded in vminit)
- `helpervm/` - Alpine Linux + OVS/OVN image

**Prerequisites:**
- Custom vminit:latest with arca-tap-forwarder (`make vminit`)
- Custom kernel with CONFIG_TUN=y (`make kernel`)
- Helper VM image (`make helpervm`)

### vmnet Backend Components

**Files:**
- `Sources/ContainerBridge/VmnetNetworkBackend.swift` - vmnet backend implementation
- `Sources/ContainerBridge/SharedVmnetNetwork.swift` - Thread-safe vmnet wrapper
- `Sources/ContainerBridge/NetworkManager.swift` - Backend selection logic

**Prerequisites:**
- None (uses stock Apple Containerization framework)

---

## User Experience Examples

### OVS Backend (Default)

```bash
# Full Docker compatibility
docker network create frontend
docker network create backend

docker run -d --name web nginx
docker network connect frontend web  # ✅ Works!
docker network connect backend web   # ✅ Works! (eth1 created)

docker run -d --name db -p 5432:5432 postgres  # ✅ Port mapping works!
```

### vmnet Backend (High Performance)

```bash
# Configure vmnet backend
cat > ~/.arca/config.json <<EOF
{
  "networkBackend": "vmnet"
}
EOF

arca daemon stop && arca daemon start

# Create network
docker network create fast-network

# Must specify network at creation
docker run -d --network fast-network --name web nginx  # ✅ Works!

# Try dynamic attach
docker network connect other-network web
# ❌ Error: "vmnet backend does not support dynamic network attachment.
#           Recreate container with --network flag."

# Try port mapping
docker run -d --network fast-network -p 8080:80 --name app nginx
# ❌ Error: "vmnet backend does not support port mapping"
```

### Mixed Mode (Best of Both)

```bash
# Use OVS by default
cat > ~/.arca/config.json <<EOF
{
  "networkBackend": "ovs"
}
EOF

# Create OVS network (default backend)
docker network create app-network

# Create vmnet network explicitly
docker network create --driver vmnet fast-network

# OVS container - full features
docker run -d --name web nginx
docker network connect app-network web  # ✅ Works!

# vmnet container - high performance
docker run -d --network fast-network --name db postgres
```

---

## Migration Guide

### From OVS to vmnet (for performance)

**Before:**
```bash
docker network create my-network
docker run -d --name app1 myapp
docker network connect my-network app1
```

**After:**
```bash
# Change config to vmnet backend
cat > ~/.arca/config.json <<EOF
{"networkBackend": "vmnet"}
EOF

# Restart daemon
arca daemon stop && arca daemon start

# Create network
docker network create my-network

# MUST specify network at creation
docker run -d --network my-network --name app1 myapp
# Cannot use docker network connect anymore!
```

### From vmnet to OVS (for features)

**Before:**
```bash
# vmnet mode
docker run -d --network my-network --name app myapp
```

**After:**
```bash
# Change config to ovs backend
cat > ~/.arca/config.json <<EOF
{"networkBackend": "ovs"}
EOF

# Build prerequisites
make kernel     # Custom kernel with TUN support
make vminit     # Custom vminit with arca-tap-forwarder
make helpervm   # Helper VM image

# Restart daemon
arca daemon stop && arca daemon start

# Now you can use dynamic attachment!
docker run -d --name app myapp
docker network connect my-network app  # ✅ Works!
docker network connect other-network app  # ✅ Works! (eth1)
```

---

## Troubleshooting

### OVS Backend Issues

**Helper VM won't start:**
```bash
# Check if custom kernel exists
ls -lh ~/.arca/vmlinux

# Rebuild if missing
make kernel

# Check helper VM image
container image ls | grep arca-network-helper

# Rebuild if missing
make helpervm
```

**Containers can't communicate:**
```bash
# Check helper VM status
docker exec <container> ip addr  # Should see eth0 with IP

# Check OVS bridges in helper VM
# (requires attaching to helper VM console - future feature)
```

### vmnet Backend Issues

**"Dynamic attach not supported" error:**
```
This is expected with vmnet backend. You must specify --network at docker run time.
Either:
1. Recreate container with --network flag
2. Switch to OVS backend for dynamic networking
```

**IP conflicts:**
```bash
# Check if Apple's container CLI is using same subnet
container network ls

# Change Arca network subnet to avoid collisions
docker network create --subnet 10.0.100.0/24 my-network
```

---

## Performance Tuning

### OVS Backend Optimizations

**Current latency: ~4-7ms** (1ms polling sleep in NetworkBridge relay)

**Reduce latency** (increases CPU usage):
```swift
// Sources/ContainerBridge/NetworkBridge.swift
// Change sleep from 1ms to 100μs
try? await Task.sleep(nanoseconds: 100_000)  // Was: 1_000_000
```

**Expected improvement**: ~2-3ms latency, ~2-3% higher CPU usage

### vmnet Backend Optimizations

**Already optimal** - Native kernel switching, no further tuning needed

---

## Future Enhancements

### OVS Backend Roadmap

- [ ] **Overlay networks** - VXLAN tunneling for multi-host networking
- [ ] **Network policies** - Kubernetes-style NetworkPolicies via OVS flows
- [ ] **QoS** - Bandwidth limits and traffic shaping
- [ ] **Port mirroring** - Debug container traffic
- [ ] **IPv6 support** - Dual-stack networking

### vmnet Backend Roadmap

- [ ] **VZFileHandleNetworkDeviceAttachment** - Use socket pairs for lower latency (~2-3ms)
- [ ] **Userspace L2 switch** - Implement QEMU-style hub for multi-network support
- [ ] **Port mapping** - Userspace NAT implementation (complex)

---

## Summary

Arca provides **two network backends** to balance Docker compatibility and performance:

**Default: OVS Backend**
- Full Docker Network API compatibility
- Dynamic network attachment
- Multi-network containers
- Port mapping
- ~4-7ms latency (acceptable for development)

**Optional: vmnet Backend**
- Native Apple networking
- 10x lower latency (~0.5ms)
- Simple architecture (no helper VM)
- Limited features (no dynamic attach, single network, no port mapping)

**Recommendation**: Use **OVS backend** (default) for Docker compatibility. Switch to **vmnet backend** only if profiling shows networking is a bottleneck and you can accept the limitations.
