# Phase 2.2 Implementation Plan: Multi-Network Go Service

**Status**: Planning Complete - Ready for Implementation
**Dependencies**: Phase 2.1 Complete (Proto API + Generated Code) ✅
**Estimated Effort**: ~400-500 lines of Go code

---

## Overview

Phase 2.2 implements the multi-network logic in the WireGuard service (Go). Each network gets its own WireGuard interface (wg0, wg1, wg2) with dedicated veth pair, renamed to ethN in container namespace.

**Architecture**:
```
Root namespace (vminitd):
  eth0 (vmnet) - 192.168.65.x ← UDP packets arrive here
  wg0 + veth-root0 ← network 1
  wg1 + veth-root1 ← network 2
  wg2 + veth-root2 ← network 3

Container namespace (OCI):
  eth0 (renamed from veth-cont0) ← network 1
  eth1 (renamed from veth-cont1) ← network 2
  eth2 (renamed from veth-cont2) ← network 3
```

---

## Step 1: Refactor Hub Struct (DONE ✅)

**File**: `internal/wireguard/hub.go`

**Changes Made**:
```go
// Old (single interface)
type Hub struct {
    privateKey    string
    publicKey     string
    listenPort    uint32
    interfaceName string
    netnsPath     string
    networks      map[string]*Network
    mu            sync.RWMutex
}

// New (multiple interfaces)
type Hub struct {
    netnsPath  string
    interfaces map[string]*Interface  // networkID → Interface
    mu         sync.RWMutex
}

type Interface struct {
    networkID     string
    interfaceName string  // wg0, wg1, wg2
    ethName       string  // eth0, eth1, eth2
    vethRootName  string  // veth-root0, veth-root1, veth-root2
    vethContName  string  // veth-cont0, veth-cont1, veth-cont2
    privateKey    string
    publicKey     string
    listenPort    uint32
    ipAddress     string
    networkCIDR   string
    gateway       string
    peers         map[string]*Peer  // peerPublicKey → Peer
}
```

---

## Step 2: Rewrite NewHub() (~20 lines)

**Current Implementation**:
- Creates wg0 interface
- Sets up veth pair
- Configures NAT
- ~180 lines

**New Implementation**:
```go
func NewHub() (*Hub, error) {
    log.Printf("Creating multi-network WireGuard hub...")

    netnsPath, err := findContainerNetNs()
    if err != nil {
        return nil, fmt.Errorf("failed to find container namespace: %w", err)
    }

    return &Hub{
        netnsPath:  netnsPath,
        interfaces: make(map[string]*Interface),
    }, nil
}
```

**Why Simpler**:
- No interface creation (happens in AddNetwork)
- No NAT setup (happens once in first AddNetwork)
- Just finds netns and initializes empty hub

---

## Step 3: Rewrite AddNetwork() (~300 lines)

**Signature Change**:
```go
// Old
func (h *Hub) AddNetwork(networkID, peerEndpoint, peerPublicKey,
                         ipAddress, networkCIDR, gateway string) error

// New
func (h *Hub) AddNetwork(networkID string, networkIndex uint32,
                         privateKey string, listenPort uint32,
                         peerEndpoint, peerPublicKey,
                         ipAddress, networkCIDR, gateway string) (
                         wgInterface, ethInterface, publicKey string, err error)
```

**Implementation Steps**:

### 3.1 Check if network exists
```go
h.mu.Lock()
defer h.mu.Unlock()

if _, exists := h.interfaces[networkID]; exists {
    return "", "", "", fmt.Errorf("network %s already exists", networkID)
}
```

### 3.2 Generate interface names
```go
wgName := fmt.Sprintf("wg%d", networkIndex)       // wg0, wg1, wg2
ethName := fmt.Sprintf("eth%d", networkIndex)     // eth0, eth1, eth2
vethRootName := fmt.Sprintf("veth-root%d", networkIndex)
vethContName := fmt.Sprintf("veth-cont%d", networkIndex)
```

### 3.3 Derive public key
```go
publicKey, err := derivePublicKey(privateKey)
if err != nil {
    return "", "", "", fmt.Errorf("failed to derive public key: %w", err)
}
```

### 3.4 Create veth pair in root namespace
```go
if err := createVethPair(vethRootName, vethContName); err != nil {
    return "", "", "", fmt.Errorf("failed to create veth pair: %w", err)
}
```

### 3.5 Move veth-contN to container namespace
```go
if err := moveInterfaceToNetNs(vethContName, h.netnsPath); err != nil {
    // Cleanup veth pair
    if link, getErr := netlink.LinkByName(vethRootName); getErr == nil {
        netlink.LinkDel(link)
    }
    return "", "", "", fmt.Errorf("failed to move %s to container namespace: %w", vethContName, err)
}
```

### 3.6 Create wgN in ROOT namespace
```go
if err := createWgInRootNs(wgName, privateKey, listenPort); err != nil {
    // Cleanup
    return "", "", "", fmt.Errorf("failed to create %s: %w", wgName, err)
}
```

### 3.7 Configure veth-rootN with gateway IP
```go
if err := configureVethRoot(vethRootName, ipAddress, gateway); err != nil {
    // Cleanup
    return "", "", "", fmt.Errorf("failed to configure %s: %w", vethRootName, err)
}
```

### 3.8 Rename veth-contN to ethN in container namespace
```go
if err := renameVethToEthN(h.netnsPath, vethContName, ethName, ipAddress, networkCIDR); err != nil {
    // Cleanup
    return "", "", "", fmt.Errorf("failed to rename %s to %s: %w", vethContName, ethName, err)
}
```

### 3.9 Configure NAT (only on first network)
```go
if networkIndex == 0 {
    if err := configureNATForInternet(); err != nil {
        log.Printf("Warning: failed to configure NAT: %v", err)
    }
}
```

### 3.10 Add peer to wgN interface
```go
if err := addPeerToInterface(wgName, peerEndpoint, peerPublicKey, []string{networkCIDR}); err != nil {
    // Cleanup
    return "", "", "", fmt.Errorf("failed to add peer: %w", err)
}
```

### 3.11 Create and store Interface object
```go
iface := &Interface{
    networkID:     networkID,
    interfaceName: wgName,
    ethName:       ethName,
    vethRootName:  vethRootName,
    vethContName:  vethContName,
    privateKey:    privateKey,
    publicKey:     publicKey,
    listenPort:    listenPort,
    ipAddress:     ipAddress,
    networkCIDR:   networkCIDR,
    gateway:       gateway,
    peers:         make(map[string]*Peer),
}

iface.peers[peerPublicKey] = &Peer{
    publicKey:  peerPublicKey,
    endpoint:   peerEndpoint,
    allowedIPs: []string{networkCIDR},
}

h.interfaces[networkID] = iface

return wgName, ethName, publicKey, nil
```

---

## Step 4: Rewrite RemoveNetwork() (~100 lines)

**New Signature**:
```go
func (h *Hub) RemoveNetwork(networkID string, networkIndex uint32) error
```

**Implementation**:

### 4.1 Find interface
```go
h.mu.Lock()
defer h.mu.Unlock()

iface, exists := h.interfaces[networkID]
if !exists {
    return fmt.Errorf("network %s not found", networkID)
}
```

### 4.2 Remove all peers from wgN
```go
for peerPubKey := range iface.peers {
    if err := removePeerFromInterface(iface.interfaceName, peerPubKey); err != nil {
        log.Printf("Warning: failed to remove peer: %v", err)
    }
}
```

### 4.3 Delete ethN in container namespace
```go
if err := deleteInterfaceInContainerNs(h.netnsPath, iface.ethName); err != nil {
    log.Printf("Warning: failed to delete %s: %v", iface.ethName, err)
}
```

### 4.4 Delete wgN in root namespace
```go
if link, err := netlink.LinkByName(iface.interfaceName); err == nil {
    if err := netlink.LinkDel(link); err != nil {
        log.Printf("Warning: failed to delete %s: %v", iface.interfaceName, err)
    }
}
```

### 4.5 Delete veth pair (deleting one side deletes both)
```go
if link, err := netlink.LinkByName(iface.vethRootName); err == nil {
    if err := netlink.LinkDel(link); err != nil {
        log.Printf("Warning: failed to delete %s: %v", iface.vethRootName, err)
    }
}
```

### 4.6 Remove from interfaces map
```go
delete(h.interfaces, networkID)
log.Printf("Network removed: networkID=%s interface=%s", networkID, iface.interfaceName)
```

---

## Step 5: Update Helper Functions

### 5.1 Generalize veth pair creation
```go
// Old: createVethPair() - hardcoded "veth-root" and "veth-cont"
// New:
func createVethPair(rootName, contName string) error {
    veth := &netlink.Veth{
        LinkAttrs: netlink.LinkAttrs{
            Name: rootName,
        },
        PeerName: contName,
    }
    return netlink.LinkAdd(veth)
}
```

### 5.2 Generalize WireGuard interface creation
```go
// Old: createWg0InRootNs() - hardcoded "wg0"
// New:
func createWgInRootNs(ifName, privateKey string, listenPort uint32) error {
    // Parse private key
    privKey, err := wgtypes.ParseKey(privateKey)
    if err != nil {
        return fmt.Errorf("failed to parse private key: %w", err)
    }

    // Create WireGuard interface
    wg := &netlink.Wireguard{
        LinkAttrs: netlink.LinkAttrs{
            Name: ifName,
        },
    }
    if err := netlink.LinkAdd(wg); err != nil {
        return fmt.Errorf("failed to create interface: %w", err)
    }

    // Configure WireGuard
    wgClient, err := wgctrl.New()
    if err != nil {
        netlink.LinkDel(wg)
        return fmt.Errorf("failed to create wgctrl client: %w", err)
    }
    defer wgClient.Close()

    cfg := wgtypes.Config{
        PrivateKey: &privKey,
        ListenPort: (*int)(unsafe.Pointer(&listenPort)),
    }
    if err := wgClient.ConfigureDevice(ifName, cfg); err != nil {
        netlink.LinkDel(wg)
        return fmt.Errorf("failed to configure device: %w", err)
    }

    // Bring interface up
    if err := netlink.LinkSetUp(wg); err != nil {
        netlink.LinkDel(wg)
        return fmt.Errorf("failed to bring interface up: %w", err)
    }

    return nil
}
```

### 5.3 Generalize veth rename
```go
// Old: renameVethToEth0InContainerNs() - hardcoded "veth-cont" → "eth0"
// New:
func renameVethToEthN(netnsPath, oldName, newName, ipAddress, networkCIDR string) error {
    return executeInNetNs(netnsPath, func() error {
        // Get interface by old name
        link, err := netlink.LinkByName(oldName)
        if err != nil {
            return fmt.Errorf("failed to find %s: %w", oldName, err)
        }

        // Rename to ethN
        if err := netlink.LinkSetName(link, newName); err != nil {
            return fmt.Errorf("failed to rename to %s: %w", newName, err)
        }

        // Get renamed interface
        ethLink, err := netlink.LinkByName(newName)
        if err != nil {
            return fmt.Errorf("failed to find %s after rename: %w", newName, err)
        }

        // Parse IP address
        addr, err := netlink.ParseAddr(ipAddress + "/32")
        if err != nil {
            return fmt.Errorf("failed to parse address: %w", err)
        }

        // Assign IP
        if err := netlink.AddrAdd(ethLink, addr); err != nil {
            return fmt.Errorf("failed to add address: %w", err)
        }

        // Bring interface up
        if err := netlink.LinkSetUp(ethLink); err != nil {
            return fmt.Errorf("failed to bring interface up: %w", err)
        }

        // Add default route (gateway is first IP in network)
        _, ipNet, _ := net.ParseCIDR(networkCIDR)
        gatewayIP := ipNet.IP
        gatewayIP[len(gatewayIP)-1] = 1

        route := &netlink.Route{
            LinkIndex: ethLink.Attrs().Index,
            Gw:        gatewayIP,
            Scope:     netlink.SCOPE_UNIVERSE,
        }
        if err := netlink.RouteAdd(route); err != nil {
            // Ignore "file exists" - multiple networks may add routes
            if !strings.Contains(err.Error(), "file exists") {
                return fmt.Errorf("failed to add route: %w", err)
            }
        }

        return nil
    })
}
```

---

## Step 6: Update GetStatus() (~50 lines)

**Implementation**:
```go
func (h *Hub) GetStatus() []InterfaceStatus {
    h.mu.RLock()
    defer h.mu.RUnlock()

    statuses := make([]InterfaceStatus, 0, len(h.interfaces))

    for _, iface := range h.interfaces {
        peers := make([]PeerStatus, 0, len(iface.peers))

        // Query actual WireGuard stats from kernel
        wgClient, err := wgctrl.New()
        if err == nil {
            defer wgClient.Close()

            device, err := wgClient.Device(iface.interfaceName)
            if err == nil {
                for _, peer := range device.Peers {
                    pubKey := peer.PublicKey.String()
                    allowedIPs := make([]string, len(peer.AllowedIPs))
                    for i, ip := range peer.AllowedIPs {
                        allowedIPs[i] = ip.String()
                    }

                    peers = append(peers, PeerStatus{
                        InterfaceName:       iface.interfaceName,
                        PublicKey:           pubKey,
                        Endpoint:            peer.Endpoint.String(),
                        AllowedIPs:          allowedIPs,
                        LatestHandshake:     uint64(peer.LastHandshakeTime.Unix()),
                        BytesReceived:       uint64(peer.ReceiveBytes),
                        BytesSent:           uint64(peer.TransmitBytes),
                        PersistentKeepalive: uint32(peer.PersistentKeepaliveInterval.Seconds()),
                    })
                }
            }
        }

        status := InterfaceStatus{
            NetworkID:     iface.networkID,
            InterfaceName: iface.interfaceName,
            EthName:       iface.ethName,
            PublicKey:     iface.publicKey,
            ListenPort:    int(iface.listenPort),
            IPAddress:     iface.ipAddress,
            NetworkCIDR:   iface.networkCIDR,
            Peers:         peers,
        }
        statuses = append(statuses, status)
    }

    return statuses
}
```

---

## Step 7: Update main.go gRPC Handlers (~50 lines)

### 7.1 Remove CreateHub handler
```go
// DELETE this entire function
func (s *server) CreateHub(ctx context.Context, req *pb.CreateHubRequest) (*pb.CreateHubResponse, error) {
    // ...
}
```

### 7.2 Update AddNetwork handler
```go
func (s *server) AddNetwork(ctx context.Context, req *pb.AddNetworkRequest) (*pb.AddNetworkResponse, error) {
    s.mu.Lock()

    // Create hub if it doesn't exist
    if s.hub == nil {
        hub, err := wireguard.NewHub()
        if err != nil {
            s.mu.Unlock()
            return &pb.AddNetworkResponse{
                Success: false,
                Error:   fmt.Sprintf("failed to create hub: %v", err),
            }, nil
        }
        s.hub = hub
    }
    s.mu.Unlock()

    // Add network
    wgIface, ethIface, pubKey, err := s.hub.AddNetwork(
        req.NetworkId,
        req.NetworkIndex,
        req.PrivateKey,
        req.ListenPort,
        req.PeerEndpoint,
        req.PeerPublicKey,
        req.IpAddress,
        req.NetworkCidr,
        req.Gateway,
    )

    if err != nil {
        return &pb.AddNetworkResponse{
            Success: false,
            Error:   err.Error(),
        }, nil
    }

    s.mu.RLock()
    totalNetworks := uint32(len(s.hub.GetInterfaces()))
    s.mu.RUnlock()

    return &pb.AddNetworkResponse{
        Success:       true,
        TotalNetworks: totalNetworks,
        WgInterface:   wgIface,
        EthInterface:  ethIface,
        PublicKey:     pubKey,
    }, nil
}
```

### 7.3 Update RemoveNetwork handler
```go
func (s *server) RemoveNetwork(ctx context.Context, req *pb.RemoveNetworkRequest) (*pb.RemoveNetworkResponse, error) {
    s.mu.RLock()
    hub := s.hub
    s.mu.RUnlock()

    if hub == nil {
        return &pb.RemoveNetworkResponse{
            Success: false,
            Error:   "hub not initialized",
        }, nil
    }

    if err := hub.RemoveNetwork(req.NetworkId, req.NetworkIndex); err != nil {
        return &pb.RemoveNetworkResponse{
            Success: false,
            Error:   err.Error(),
        }, nil
    }

    s.mu.RLock()
    remaining := uint32(len(hub.GetInterfaces()))
    s.mu.RUnlock()

    return &pb.RemoveNetworkResponse{
        Success:           true,
        RemainingNetworks: remaining,
    }, nil
}
```

### 7.4 Update GetStatus handler
```go
func (s *server) GetStatus(ctx context.Context, req *pb.GetStatusRequest) (*pb.GetStatusResponse, error) {
    s.mu.RLock()
    hub := s.hub
    s.mu.RUnlock()

    if hub == nil {
        return &pb.GetStatusResponse{
            Version:      "1.0.0",
            NetworkCount: 0,
            Interfaces:   []*pb.InterfaceStatus{},
            Peers:        []*pb.PeerStatus{},
        }, nil
    }

    statuses := hub.GetStatus()

    pbInterfaces := make([]*pb.InterfaceStatus, 0, len(statuses))
    var allPeers []*pb.PeerStatus

    for _, status := range statuses {
        pbInterfaces = append(pbInterfaces, &pb.InterfaceStatus{
            NetworkId:   status.NetworkID,
            Name:        status.InterfaceName,
            PublicKey:   status.PublicKey,
            ListenPort:  uint32(status.ListenPort),
            IpAddresses: []string{status.IPAddress},
        })

        for _, peer := range status.Peers {
            allPeers = append(allPeers, &pb.PeerStatus{
                NetworkId:     status.NetworkID,
                InterfaceName: peer.InterfaceName,
                PublicKey:     peer.PublicKey,
                Endpoint:      peer.Endpoint,
                AllowedIps:    peer.AllowedIPs,
                LatestHandshake: peer.LatestHandshake,
                Stats: &pb.TransferStats{
                    BytesReceived:       peer.BytesReceived,
                    BytesSent:           peer.BytesSent,
                    PersistentKeepalive: peer.PersistentKeepalive,
                },
            })
        }
    }

    return &pb.GetStatusResponse{
        Version:      "1.0.0",
        NetworkCount: uint32(len(statuses)),
        Interfaces:   pbInterfaces,
        Peers:        allPeers,
    }, nil
}
```

---

## Step 8: Testing Strategy

### 8.1 Unit Tests (Go)
```bash
# Test interface name generation
TestInterfaceNaming()

# Test veth pair creation/deletion
TestVethPairLifecycle()

# Test WireGuard interface creation
TestWgInterfaceCreation()

# Test peer management
TestPeerAddRemove()
```

### 8.2 Integration Tests (with vminit)
```bash
# Build updated vminit
cd /Users/kiener/code/arca
make vminit

# Test single network (existing functionality)
docker network create --driver wireguard wg-net1
docker run -d --network wg-net1 --name c1 alpine sleep 3600
docker exec c1 ip addr  # Should show eth0

# Test multi-network
docker network create --driver wireguard wg-net2
docker network connect wg-net2 c1
docker exec c1 ip addr  # Should show eth0 + eth1

# Test isolation
docker run -d --network wg-net2 --name c2 alpine sleep 3600
docker exec c1 ping <c2-ip-on-net2>  # Should work via eth1
docker exec c1 ping <c2-ip-on-net1>  # Should fail (different network)
```

---

## Summary

**Files to Modify**:
1. `internal/wireguard/hub.go` - Core multi-network logic (~400 lines)
2. `internal/wireguard/netns.go` - Generalize helper functions (~100 lines)
3. `cmd/arca-wireguard-service/main.go` - Update gRPC handlers (~50 lines)

**Total Estimated Lines**: ~550 lines

**Implementation Order**:
1. Refactor helper functions in netns.go (generalize names)
2. Rewrite NewHub() and AddNetwork() in hub.go
3. Rewrite RemoveNetwork() and GetStatus()
4. Update main.go handlers
5. Test with docker commands
6. Fix any issues found during testing

**Success Criteria**:
- ✅ Container can join multiple networks
- ✅ Each network creates separate wgN/ethN interfaces
- ✅ Networks are isolated (separate peer meshes)
- ✅ Dynamic attach/detach works
- ✅ No regressions from Phase 1.7
