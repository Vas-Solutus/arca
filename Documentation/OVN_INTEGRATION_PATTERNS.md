# OVN Integration Patterns for Arca

**Date**: 2025-10-28
**Status**: Research Phase

## Current Architecture (Hybrid)

### What We Have

1. **br-int** - Integration bridge (manually created with netdev datapath)
   - Location: `helpervm/scripts/startup.sh:104-141`
   - Already using OVN-style naming
   - Managed manually, not by ovn-controller

2. **Multiple per-network bridges** - Manual creation
   - Created in `helpervm/control-api/server.go:CreateBridge()`
   - Named: `br-{md5hash}` (e.g., `br-abc123def456`)
   - Each network gets its own OVS bridge
   - TAP relay connects to specific bridge names

3. **OVN logical switches** - Created but not fully utilized
   - Created with `ovn-nbctl ls-add <network-id>`
   - Used for DHCP IP allocation only
   - NOT used for actual port bindings or packet forwarding

### Problems

- **Non-idempotent**: CreateBridge fails if logical switch exists in OVN DB
- **State sync complexity**: Must track bridges in Go memory + OVN DB + SQLite
- **No persistence**: Manual bridges vanish on container restart (new network namespace)
- **Not OVN-native**: Bypassing OVN's actual network management capabilities

## Target Architecture (Proper OVN)

### OVN Integration Bridge Pattern

**Key Concept**: Use single `br-int` with VLAN tags for network isolation.

```
┌─────────────────────────────────────────┐
│        OVN Control Plane VM             │
│                                         │
│  ┌───────────────────────────────────┐ │
│  │         br-int (OVN-managed)      │ │
│  │                                   │ │
│  │  ┌────────┐  ┌────────┐          │ │
│  │  │ VLAN   │  │ VLAN   │          │ │
│  │  │  100   │  │  101   │  ...     │ │
│  │  └────────┘  └────────┘          │ │
│  │      ↓            ↓               │ │
│  │    TAP0        TAP1               │ │
│  └─────│────────────│────────────────┘ │
│        │            │                  │
│    vsock:5555  vsock:5556              │
└────────│────────────│───────────────────┘
         │            │
    ┌────┴────┐  ┌───┴─────┐
    │ nginx   │  │ postgres│
    │ (VM)    │  │ (VM)    │
    └─────────┘  └─────────┘
```

### VLAN Tagging Strategy

1. **Network → VLAN mapping**
   - Store VLAN tag in OVN logical switch external_ids
   - Allocate VLANs sequentially: 100, 101, 102...
   - Range: 100-4095 (VLAN 1-99 reserved, 4096 max)

2. **TAP device attachment**
   ```bash
   # Instead of: ovs-vsctl add-port br-abc123 tap0
   # Use:        ovs-vsctl add-port br-int tap0 tag=100
   ```

3. **Isolation**
   - OVS automatically isolates traffic by VLAN
   - Containers on VLAN 100 cannot reach VLAN 101
   - No manual ACLs needed for basic isolation

### Chassis Registration

**Purpose**: Register control plane as OVN chassis for port binding.

**Command**:
```bash
ovn-sbctl chassis-add arca-control-plane geneve 127.0.0.1
```

**Benefits**:
- Enables OVN logical switch port (LSP) binding
- Foundation for future multi-host (Geneve tunnels)
- OVN can track which ports are on which chassis

**For single-host**: Use 127.0.0.1 (no actual tunneling)
**For multi-host** (future): Use real host IP for Geneve tunnels

### Localnet Ports (NOT NEEDED for us)

**What they are**: Bridge OVN logical switches to physical networks.

**Example**:
```bash
ovn-nbctl lsp-add <network> <network>-localnet
ovn-nbctl lsp-set-type <network>-localnet localnet
ovn-nbctl lsp-set-options <network>-localnet network_name=physnet
ovn-nbctl lsp-set-addresses <network>-localnet unknown
ovn-nbctl set logical_switch_port <network>-localnet tag=100
```

**Why we don't need them**:
- We're not bridging to physical networks
- All containers are VMs communicating via vsock
- TAP-over-vsock already provides connectivity
- Using VLAN tags on br-int directly is simpler

## Implementation Plan

### Phase 1: Keep br-int, Stop Creating Extra Bridges

1. **Modify CreateBridge** (Go control API)
   - Remove: `ovs-vsctl add-br br-{hash}`
   - Remove: IP assignment to bridge
   - Remove: ethtool TX offload disabling
   - Keep: `ovn-nbctl ls-add <network-id>`
   - Add: Assign VLAN tag via external_ids

2. **Remove Bridge Tracking**
   - Delete: `NetworkServer.bridges` map
   - Replace: Query OVN for network state

3. **Update TAP Relay**
   - Get VLAN from OVN: `ovn-nbctl get logical_switch <net> external_ids:vlan_tag`
   - Attach to br-int: `ovs-vsctl add-port br-int tap0 tag=<vlan>`

### Phase 2: Add Chassis Registration

1. **Startup script**: Add chassis registration after ovn-controller starts
2. **Chassis name**: Use control plane container ID (unique, stable within lifetime)
3. **Encap IP**: 127.0.0.1 for now (multi-host later)

### Phase 3: OVN Port Binding (Optional Enhancement)

**Current**: TAP devices attach directly to br-int with VLAN tags
**OVN-native**: Create logical switch ports and bind to chassis

**Benefits**: Better OVN integration, prepare for advanced features
**Cost**: Additional complexity, more OVN API calls
**Decision**: Defer to future phase (current TAP approach works)

## Key Decisions

### Decision 1: VLAN Tags vs Multiple Bridges

**Chosen**: VLAN tags on single br-int

**Rationale**:
- OVN-native approach
- Simpler state management (no bridge tracking)
- Better performance (single bridge, hardware offload)
- Industry standard (OpenStack, Kubernetes use this)

### Decision 2: Chassis Registration Now or Later

**Chosen**: Register now

**Rationale**:
- Simple addition (~5 lines)
- Foundation for multi-host
- Enables future OVN features
- No downside (works fine in single-host mode)

### Decision 3: Localnet Ports

**Chosen**: NOT using localnet ports

**Rationale**:
- Not needed for VM-to-VM communication
- TAP-over-vsock already provides connectivity
- Adds unnecessary complexity
- Localnet is for bridging to physical networks

### Decision 4: OVN LSP Binding

**Chosen**: Defer to future phase

**Rationale**:
- Current TAP + VLAN approach works
- LSP binding adds complexity
- Want to ship Phase 3.8 quickly
- Can add later without breaking changes

## Testing Strategy

### Test 1: VLAN Isolation

```bash
# Create two networks
docker network create net-a
docker network create net-b

# Start containers
docker run -d --name web --network net-a nginx
docker run -d --name db --network net-b postgres

# Inside control plane:
ovs-vsctl show
# Should show: br-int with two ports (tap0 tag=100, tap1 tag=101)

# Test isolation
docker exec web ping -c 1 db
# Should FAIL (different VLANs)
```

### Test 2: Persistence

```bash
# Create network
docker network create my-net

# Stop control plane
docker stop arca-control-plane

# Start control plane
docker start arca-control-plane

# Verify
docker network ls | grep my-net
# Should exist

# Inside control plane:
ovn-nbctl list logical_switch
# Should show my-net with VLAN tag
```

### Test 3: Chassis Registration

```bash
# Inside control plane after startup:
ovn-sbctl show
# Should show: chassis "arca-control-plane" with encap geneve 127.0.0.1
```

## References

- [OVN Architecture Manual](https://www.ovn.org/support/dist-docs/ovn-architecture.7.html)
- [OVN Southbound Schema](https://man7.org/linux/man-pages/man8/ovn-sbctl.8.html)
- [OpenStack OVN Provider Networks](https://docs.openstack.org/networking-ovn/pike/admin/refarch/provider-networks.html)
- [OVN VLAN Support Patch](https://lists.linuxfoundation.org/pipermail/ovs-dev/2015-October/304325.html)

## Next Steps

1. ✅ Research complete - document findings
2. ⏳ Create VLAN tagging prototype
3. ⏳ Test VLAN isolation
4. ⏳ Implement chassis registration
5. ⏳ Refactor CreateBridge
6. ⏳ Update TAP relay
7. ⏳ Test persistence
