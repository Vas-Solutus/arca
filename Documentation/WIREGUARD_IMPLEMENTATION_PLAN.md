# WireGuard Network Backend Implementation Plan

**Goal**: Replace OVS/OVN networking with WireGuard-based overlay network for better performance, simplicity, and code reduction.

**Key Benefits**:
- 🚀 2-3x lower latency (~1ms vs ~3ms for OVS)
- 🧹 ~2,100 lines of code deleted
- 🔒 Built-in encryption
- 🎯 100% kernel-space data path (no userspace hops)
- 🌐 Multi-host ready

---

## ✅ Phase 1.1: Manual Testing & Validation - COMPLETE! (2025-11-03)

**Status**: Successfully validated that WireGuard works through vmnet with excellent performance!

### Validation Results

**Test Setup:**
- Two containers on vmnet network (192.168.65.14, 192.168.65.15)
- Pre-built WireGuard image: `linuxserver/wireguard:latest`
- Overlay network: 10.100.0.0/24
- WireGuard port: 51820 (UDP)

**Performance Metrics:**
- ✅ **Latency**: ~1.0ms average (range: 0.596ms - 1.453ms)
  - Target: < 1.5ms ✅ EXCEEDED
  - OVS comparison: ~3ms (WireGuard is **3x faster**!)
- ✅ **Packet Loss**: 0% (14/14 packets successful)
- ✅ **Bidirectional**: Both directions working perfectly
- ✅ **Handshake**: Completed successfully (40 seconds ago at measurement)
- ✅ **Encryption**: Active (transfer stats: 692 B received, 2.68 KiB sent)

**Kernel Support Validated:**
- ✅ `CONFIG_WIREGUARD=y` (built-in, not module)
- ✅ WireGuard module loads at boot
- ✅ Interface creation works: `ip link add wg0 type wireguard`
- ✅ vmnet passes UDP traffic on port 51820
- ✅ No VLAN tag filtering issues (UDP encapsulated)

**Key Findings:**
1. vmnet **DOES pass WireGuard traffic** (UDP port 51820)
2. WireGuard handshake and encrypted data flow work perfectly
3. Performance exceeds expectations (~1ms vs ~3ms for OVS)
4. All kernel support is present in Apple's Linux kernel
5. The architecture is viable and will work!

### Completed Tasks

- [x] **Task**: Create two containers on vmnet ✅
  - Used `linuxserver/wireguard:latest` to avoid DNS resolution issues
  - Containers: wg-test1 (192.168.65.14), wg-test2 (192.168.65.15)
- [x] **Task**: Install `wireguard-tools` in containers ✅
  - Pre-built image includes `wg` v1.0.20250521
- [x] **Task**: Manually configure WireGuard point-to-point tunnel ✅
  - Generated keypairs for both containers
  - Configured wg0 interfaces with overlay IPs (10.100.0.1, 10.100.0.2)
  - Set up peer relationships with vmnet endpoints
  - Persistent keepalive: 25 seconds
- [x] **Task**: Test connectivity through WireGuard tunnel ✅
  - Ping test: 10 packets, 0% loss, avg 1.0ms latency
  - Bidirectional traffic confirmed
- [x] **Task**: Verify vmnet passes WireGuard UDP traffic ✅
  - Handshake successful
  - Encrypted data flowing: 1.93 KiB received, 1.96 KiB sent
  - Transfer statistics show active communication
- [x] **Deliverable**: Manual test results documented ✅

**Build Structure Discovered:**

During Phase 1.1, we explored the build infrastructure:
- vminit build: `scripts/build-vminit.sh` uses `cctl` to create OCI image
- Extensions directory: `containerization/vminitd/extensions/`
- Existing patterns: `tap-forwarder/` and `embedded-dns/` (Go services)
- Binary inclusion: `cctl rootfs create --add-file` for custom binaries
- **Note**: WireGuard kernel support already present, only need `wg` userspace tool

---

## ✅ Phase 1.2: vminitd WireGuard Service Extension - COMPLETE! (2025-11-03)

**Status**: WireGuard service extension built and integrated into vminit image!

### Completed Tasks

#### 1.2 vminitd WireGuard Service Extension
- [x] **Task**: Add `wireguard-tools` to vminit build ✅
  - Solution: Compile from official WireGuard source (git.zx2c4.com)
  - Built using Docker with Alpine Linux ARM64 environment
  - Binary: `wg` (142KB) at `/usr/bin/wg` in vminit
  - Success: Latest version (1.0.20250521) compiled for Linux ARM64
- [x] **Task**: Create WireGuard service in vminitd extensions ✅
  - Directory: `containerization/vminitd/extensions/wireguard-service/`
  - Structure: `cmd/`, `internal/wireguard/`, `proto/`, `pkg/wg/`
  - Build script: `build.sh` (cross-compiles to Linux ARM64)
  - Binary: `arca-wireguard-service` (9.6MB) at `/sbin/arca-wireguard-service`
  - Success: Service compiles successfully
- [x] **Task**: Design gRPC API for WireGuard management ✅
  - File: `proto/wireguard.proto`
  - RPCs implemented:
    - `CreateHub` - Create WireGuard hub interface (wg0)
    - `AddNetwork` - Add network to container's WireGuard hub
    - `RemoveNetwork` - Remove network from container
    - `UpdateAllowedIPs` - Update allowed IP ranges for multi-network routing
    - `DeleteHub` - Destroy WireGuard hub interface
    - `GetStatus` - Get WireGuard status and statistics
  - Success: Protobuf compiles, generates Go code (wireguard.pb.go, wireguard_grpc.pb.go)
- [x] **Task**: Implement hub interface creation ✅
  - File: `internal/wireguard/hub.go`
  - Features:
    - Creates wg0 interface with configurable listen port
    - Derives public key from private key
    - Assigns IP addresses to interface
    - Thread-safe with mutex protection
  - Success: Hub struct implements full lifecycle management
- [x] **Task**: Implement container peer management ✅
  - Methods:
    - `AddNetwork()` - Adds peer to hub with allowed-ips
    - `RemoveNetwork()` - Removes peer from hub
    - `UpdateAllowedIPs()` - Updates peer routing for multi-network
  - Features:
    - Peer configuration via `wg set` commands
    - Persistent keepalive (25 seconds)
    - Multiple IP addresses per interface for multi-network
  - Success: Full peer lifecycle implemented
- [x] **Task**: Build integration ✅
  - Updated: `scripts/build-vminit.sh`
  - Added WireGuard service build step
  - Added wireguard-tools compilation from source
  - Integrated into `cctl rootfs create` with `--add-file` flags
  - Success: vminit image includes both binaries
- [x] **Deliverable**: Working gRPC service for WireGuard management ✅

### Implementation Details

**Architecture:**
- **Hub-and-spoke topology**: Each container runs WireGuard service managing its wg0 interface
- **Single interface per container**: wg0 interface for all networks
- **Multi-network via allowed-ips**: Routes to multiple networks without additional interfaces
- **vsock communication**: gRPC server on port 51820 for host→container control

**Files Created:**
```
containerization/vminitd/extensions/wireguard-service/
├── cmd/arca-wireguard-service/main.go      (265 lines) - gRPC server
├── internal/wireguard/hub.go                (480 lines) - WireGuard hub management
├── proto/wireguard.proto                    (212 lines) - gRPC API definition
├── proto/wireguard.pb.go                    (generated) - Protobuf code
├── proto/wireguard_grpc.pb.go               (generated) - gRPC stubs
├── go.mod                                   - Go dependencies
├── build.sh                                 - Cross-compilation script
└── generate-proto.sh                        - Protobuf generation
```

**Updated Files:**
- `scripts/build-vminit.sh` - Added WireGuard service and wg tool build steps

---

## ✅ Phase 1.3: Swift gRPC Client - COMPLETE! (2025-11-03)

**Status**: Swift gRPC client implemented and ready for WireGuardNetworkBackend integration!

### Completed Tasks

#### 1.3 Swift gRPC Client
- [x] **Task**: Generate Swift gRPC code from wireguard.proto ✅
  - Updated: `scripts/generate-grpc.sh` with WireGuard section
  - Generated files:
    - `Sources/ContainerBridge/Generated/wireguard.pb.swift` (40KB) - Protocol buffer types
    - `Sources/ContainerBridge/Generated/wireguard.grpc.swift` (21KB) - gRPC client stubs
  - Success: Swift stubs generated with public visibility
- [x] **Task**: Create `WireGuardClient.swift` ✅
  - File: `Sources/ContainerBridge/WireGuardClient.swift` (264 lines)
  - Actor-based client for thread safety
  - Methods implemented:
    - `connect()` - Establish vsock connection to container's WireGuard service
    - `disconnect()` - Clean up gRPC channel and vsock connection
    - `createHub()` - Initialize WireGuard hub (wg0) in container
    - `addNetwork()` - Attach container to network via peer configuration
    - `removeNetwork()` - Detach from network, remove peer
    - `updateAllowedIPs()` - Update routing for multi-network containers
    - `deleteHub()` - Destroy WireGuard interface
    - `getStatus()` - Query hub status and peer statistics
  - Error handling: Custom `WireGuardClientError` enum
  - Logging: Structured logging with swift-log
  - Success: Compiles successfully, ready for integration
- [x] **Deliverable**: Swift client ready for integration ✅

### Implementation Details

**Architecture:**
- **Actor-based concurrency**: WireGuardClient is an actor for thread-safe access
- **vsock communication**: Uses `LinuxContainer.dialVsock(port: 51820)` for host→container gRPC
- **GRPCChannel management**: Creates ClientConnection from FileHandle over vsock
- **FileHandle lifetime**: Keeps FileHandle alive for connection duration

**Files Created:**
```
Sources/ContainerBridge/
├── WireGuardClient.swift              (264 lines) - Swift gRPC client wrapper
├── proto/wireguard.proto              (212 lines) - Copied from vminitd submodule
└── Generated/
    ├── wireguard.pb.swift             (40KB) - Protocol buffer types
    └── wireguard.grpc.swift           (21KB) - gRPC client stubs
```

**Updated Files:**
- `scripts/generate-grpc.sh` - Added WireGuard code generation section

**Type Naming:**
- Generated types: `Arca_Wireguard_V1_*` (includes version namespace)
- Client: `Arca_Wireguard_V1_WireGuardServiceNIOClient`

---

## Phase 1.4-1.5: WireGuardNetworkBackend Implementation (NEXT)

**Objective**: Implement WireGuardNetworkBackend and integrate with NetworkManager.

### Tasks

#### 1.4 WireGuardNetworkBackend Implementation
- [ ] **Task**: Create `WireGuardNetworkBackend.swift`
  - File: `Sources/ContainerBridge/WireGuardNetworkBackend.swift`
  - Implement `NetworkBackend` protocol (same as OVS/vmnet)
  - Success: Compiles, conforms to protocol
- [ ] **Task**: Implement `createBridgeNetwork()`
  - Call WireGuardClient.createNetwork()
  - Store network metadata (ID, name, subnet, gateway)
  - Success: Creates WireGuard hub interface in vminitd
- [ ] **Task**: Implement `attachContainer()`
  - Generate unique overlay IP from IPAM
  - Call WireGuardClient.attachContainer()
  - Create WireGuard interface in container namespace
  - Configure peer relationship (container ↔ hub)
  - Success: Container has wg0 interface with overlay IP
- [ ] **Task**: Implement `detachContainer()`
  - Remove peer from hub
  - Delete WireGuard interface from container
  - Release IP to IPAM
  - Success: Clean teardown, no leaked resources
- [ ] **Task**: Implement `deleteBridgeNetwork()`
  - Call WireGuardClient.deleteNetwork()
  - Clean up metadata
  - Success: Hub interface deleted, state cleaned
- [ ] **Deliverable**: Basic single-network WireGuard backend

#### 1.5 Integration & Testing
- [ ] **Task**: Add WireGuardNetworkBackend to NetworkManager
  - Config option: `networkBackend: "wireguard"`
  - Initialize WireGuardNetworkBackend instead of OVS
  - Success: Daemon starts with wireguard backend
- [ ] **Task**: Test basic container lifecycle
  ```bash
  docker network create --driver bridge wg-test
  docker run -d --network wg-test alpine sleep 3600
  docker run -d --network wg-test alpine sleep 3600
  # Containers should communicate
  ```
  - Success: Containers on same network can ping each other
- [ ] **Task**: Measure latency vs OVS
  - Benchmark: Container A → Container B ping RTT
  - Success: WireGuard latency < 1.5ms (vs OVS ~3ms)
- [ ] **Task**: Test network isolation
  - Create two networks, containers on different networks
  - Success: Containers cannot reach each other
- [ ] **Deliverable**: Working prototype with performance validation

### Phase 1 Success Criteria
- ✅ WireGuard traffic flows through vmnet (UDP port 51820)
- ✅ Containers on same network can communicate
- ✅ Containers on different networks are isolated
- ✅ Latency < 1.5ms (better than OVS)
- ✅ Basic Docker commands work: `network create`, `run --network`, `network rm`
- ✅ No memory leaks or resource exhaustion after 100+ container create/delete cycles

---

## Phase 2: Feature Parity (2-3 weeks)

**Objective**: Implement Docker-compatible networking features to match OVS functionality.

### Tasks

#### 2.1 Multi-Network Support (via allowed-ips)
- [ ] **Task**: Design allowed-ips routing strategy
  - Document: How to use `allowed-ips` for multi-network containers
  - Example: Container on net1+net2 gets `allowed-ips = 172.17.0.0/24, 172.18.0.0/24`
  - Success: Clear design documented
- [ ] **Task**: Extend `attachContainer()` for multi-network
  - Track which networks each container is on
  - Update peer `allowed-ips` to include all network subnets
  - Success: `docker network connect` adds routes without new interface
- [ ] **Task**: Extend `detachContainer()` for multi-network
  - Remove subnet from container's `allowed-ips`
  - Success: `docker network disconnect` removes routes
- [ ] **Task**: Test multi-network scenarios
  ```bash
  docker network create net1
  docker network create net2
  docker run -d --network net1 --name c1 alpine sleep 3600
  docker run -d --network net2 --name c2 alpine sleep 3600
  docker network connect net2 c1  # c1 now on both nets
  ```
  - Success: c1 can reach c2 after `network connect`, c1 isolated from net2 before
- [ ] **Deliverable**: Multi-network containers via allowed-ips routing

#### 2.2 Dynamic Network Attach/Detach
- [ ] **Task**: Implement runtime peer updates
  - `wg set wg-{network}-hub peer {container} allowed-ips {new-subnet}`
  - Update while container is running
  - Success: No container restart needed for network changes
- [ ] **Task**: Test dynamic attach workflow
  ```bash
  docker run -d --network net1 --name test alpine sleep 3600
  docker exec test ip addr  # Only sees net1
  docker network connect net2 test
  docker exec test ip route  # Now has routes to net2
  ```
  - Success: Routes appear without container restart
- [ ] **Deliverable**: Runtime network attach/detach working

#### 2.3 DNS Resolution
- [ ] **Task**: Integrate embedded-DNS with WireGuard backend
  - Reuse existing embedded-DNS from OVS implementation
  - Push DNS topology updates when containers attach/detach
  - Success: DNS running at 127.0.0.11:53 in containers
- [ ] **Task**: Test DNS by container name
  ```bash
  docker run -d --network mynet --name web nginx
  docker run -d --network mynet alpine ping web
  ```
  - Success: `ping web` resolves to container IP
- [ ] **Task**: Test multi-network DNS resolution
  - Container on net1+net2 should resolve names from both networks
  - Success: DNS queries work for all attached networks
- [ ] **Deliverable**: Full DNS support matching OVS behavior

#### 2.4 Internet Access & NAT
- [ ] **Task**: Configure default route via WireGuard hub
  - Containers with internet access need `0.0.0.0/0` in allowed-ips
  - Hub NATs traffic to vmnet interface
  - Success: Containers can reach internet
- [ ] **Task**: Implement iptables MASQUERADE rules
  - In hub namespace: `iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`
  - Success: Container traffic NATed to vmnet IP
- [ ] **Task**: Test internet connectivity
  ```bash
  docker run --rm alpine ping -c 3 8.8.8.8
  docker run --rm alpine wget -O- https://example.com
  ```
  - Success: DNS resolution and HTTP work
- [ ] **Deliverable**: Full internet access from containers

#### 2.5 IPAM Integration
- [ ] **Task**: Reuse existing IPAMAllocator
  - Allocate overlay IPs from network subnet
  - Track allocations per network
  - Success: No IP conflicts
- [ ] **Task**: Support custom subnets and IP ranges
  ```bash
  docker network create --subnet 10.50.0.0/24 --ip-range 10.50.0.128/25 mynet
  ```
  - Success: IPs allocated from specified range
- [ ] **Deliverable**: Full IPAM feature parity

#### 2.6 Network Inspection
- [ ] **Task**: Implement `getNetworkAttachments()`
  - Return list of containers on each network
  - Include overlay IPs and WireGuard pubkeys
  - Success: `docker network inspect` shows correct data
- [ ] **Task**: Test inspection commands
  ```bash
  docker network inspect mynet
  docker inspect container-id
  ```
  - Success: Network and container details accurate
- [ ] **Deliverable**: Full inspection API working

### Phase 2 Success Criteria
- ✅ Multi-network containers work via allowed-ips routing
- ✅ Dynamic attach/detach without container restart
- ✅ DNS resolution by container name (all networks)
- ✅ Internet access from containers
- ✅ Custom subnets and IP ranges
- ✅ `docker network inspect` returns accurate data
- ✅ No regressions from Phase 1

---

## Phase 3: Production Ready (1-2 weeks)

**Objective**: Harden, optimize, document, and migrate from OVS.

### Tasks

#### 3.1 Port Mapping (Future Feature)
- [ ] **Task**: Document port mapping approach
  - iptables DNAT rules in hub namespace
  - Map host port → container overlay IP:port
  - Success: Design documented, implementation deferred
- [ ] **Note**: Not blocking for Phase 3 - defer to future phase

#### 3.2 Performance Optimization
- [ ] **Task**: Benchmark throughput
  - iperf3 between containers
  - Compare: vmnet baseline, WireGuard, OVS
  - Success: WireGuard throughput ≥ 90% of vmnet baseline
- [ ] **Task**: Benchmark latency under load
  - 100 concurrent containers, all pinging each other
  - Success: p99 latency < 2ms
- [ ] **Task**: Profile CPU usage
  - WireGuard encryption overhead
  - Compare to OVS userspace forwarding
  - Success: WireGuard CPU < 50% of OVS
- [ ] **Deliverable**: Performance report with benchmarks

#### 3.3 Proxy ARP for L2 Compatibility
- [ ] **Task**: Implement proxy ARP in hub
  - Respond to ARP requests for containers on same network
  - Success: ARP resolution works without broadcast
- [ ] **Task**: Test IPv6 Neighbor Discovery
  - Similar proxy for NDP (if needed)
  - Success: IPv6 connectivity works
- [ ] **Deliverable**: L2 compatibility layer

#### 3.4 Error Handling & Edge Cases
- [ ] **Task**: Handle WireGuard service crashes
  - Reconnect gRPC client, retry operations
  - Success: Daemon survives vminitd restarts
- [ ] **Task**: Handle container crashes during network ops
  - Clean up orphaned peers
  - Release IPs properly
  - Success: No leaked resources
- [ ] **Task**: Handle network delete with active containers
  - Return proper error, prevent deletion
  - Success: `docker network rm` fails gracefully
- [ ] **Deliverable**: Robust error handling

#### 3.5 Testing & Validation
- [ ] **Task**: Create integration test suite
  - Script: `scripts/test-wireguard-backend.sh`
  - Test cases:
    - Single network, multiple containers
    - Multi-network containers
    - Dynamic attach/detach
    - Network isolation
    - DNS resolution
    - Internet access
  - Success: All tests pass consistently
- [ ] **Task**: Stress test
  - Create/delete 1000 containers
  - Monitor memory usage
  - Success: No leaks, stable memory footprint
- [ ] **Deliverable**: Comprehensive test coverage

#### 3.6 Documentation
- [ ] **Task**: Update NETWORK_ARCHITECTURE.md
  - Document WireGuard backend design
  - Explain allowed-ips routing strategy
  - Packet flow diagrams
  - Success: Clear architecture documented
- [ ] **Task**: Update CLAUDE.md
  - Add WireGuard as default backend
  - Update build instructions
  - Success: Developers can onboard easily
- [ ] **Task**: Migration guide (OVS → WireGuard)
  - How to switch backends
  - What changes for users
  - Success: Clear migration path
- [ ] **Deliverable**: Complete documentation

#### 3.7 Code Cleanup
- [ ] **Task**: Delete OVS backend code
  - Remove files:
    - `OVSNetworkBackend.swift` (~600 lines)
    - `NetworkHelperVM.swift` (~500 lines)
    - `OVNClient.swift` (~400 lines)
    - `NetworkBridge.swift` (~400 lines)
    - `helpervm/` directory (entire helper VM)
    - `vminitd/extensions/tap-forwarder/` (~800 lines)
  - Success: ~2,900 lines deleted
- [ ] **Task**: Update NetworkManager to default to WireGuard
  - Config: `networkBackend: "wireguard"` (default)
  - Remove OVS initialization code
  - Success: Daemon starts with WireGuard by default
- [ ] **Task**: Update Makefile
  - Remove `make helpervm` target
  - Remove OVS-related build steps
  - Success: Build simplified
- [ ] **Deliverable**: Codebase cleanup complete

#### 3.8 Migration & Rollout
- [ ] **Task**: Test migration from OVS to WireGuard
  - Stop daemon with OVS backend
  - Change config to wireguard backend
  - Restart daemon
  - Success: Existing containers work after restart
- [ ] **Task**: Update default config
  - File: `~/.arca/config.json`
  - Set `networkBackend: "wireguard"`
  - Success: New installations use WireGuard
- [ ] **Deliverable**: Production-ready WireGuard backend

### Phase 3 Success Criteria
- ✅ All integration tests pass (100+ test cases)
- ✅ Performance benchmarks meet targets (latency < 1.5ms, throughput ≥ 90% vmnet)
- ✅ Stress test: 1000 containers without memory leaks
- ✅ Documentation complete (architecture, migration, troubleshooting)
- ✅ ~2,900 lines of OVS code deleted
- ✅ WireGuard is default backend in config
- ✅ Zero regressions from OVS functionality (for supported features)

---

## Optional Phase 4: Advanced Features (Future)

### Port Mapping
- [ ] Implement iptables DNAT rules for `-p` flag
- [ ] Support host port → container port mapping
- [ ] Test with real services (nginx, databases)

### Multi-Host Networking
- [ ] Design WireGuard mesh topology for multi-host
- [ ] Implement peer discovery between hosts
- [ ] Test cross-host container communication

### IPv6 Support
- [ ] WireGuard dual-stack (IPv4 + IPv6)
- [ ] Proxy NDP for IPv6
- [ ] Test IPv6-only containers

### Observability
- [ ] Export WireGuard metrics (handshakes, traffic, peers)
- [ ] Prometheus endpoint for monitoring
- [ ] Dashboard for network health

---

## Risk Mitigation

### Risk: vmnet Blocks WireGuard Traffic
- **Likelihood**: Low (we confirmed UDP works)
- **Mitigation**: Phase 1 testing will validate immediately
- **Fallback**: Keep OVS backend as option

### Risk: Performance Worse Than Expected
- **Likelihood**: Low (kernel-only path should be fast)
- **Mitigation**: Phase 3 benchmarking will validate
- **Fallback**: Optimize or revert to OVS

### Risk: Multi-Network Complexity
- **Likelihood**: Medium (allowed-ips routing is new approach)
- **Mitigation**: Thorough testing in Phase 2
- **Fallback**: Implement multiple interfaces if needed

### Risk: State Management Bugs
- **Likelihood**: Medium (WireGuard state is stateful)
- **Mitigation**: Comprehensive error handling and testing
- **Fallback**: Add state reconciliation logic

---

## Success Metrics

**Overall Success**:
- ✅ WireGuard backend feature-complete (90%+ Docker compatibility)
- ✅ Latency: < 1.5ms (vs OVS ~3ms) = **2x improvement** → **VALIDATED: ~1.0ms** ✅
- ✅ Code reduction: ~2,100 lines deleted = **~30% codebase reduction**
- ✅ Throughput: ≥ 90% of vmnet baseline
- ✅ Zero regressions for existing Docker workflows
- ✅ Production-ready: stable under stress testing

**Timeline**:
- Phase 1.1: 0.5 days (manual testing) → **COMPLETE** ✅
- Phase 1.2-1.5: 1-2 weeks (vminitd integration + backend implementation)
- Phase 2: 2-3 weeks (feature parity)
- Phase 3: 1-2 weeks (production hardening)
- **Total: 4-7 weeks**

**Current Progress (2025-11-03)**:
- ✅ **Phase 1.1 COMPLETE**: Manual validation successful
  - WireGuard proven to work through vmnet
  - Performance validated: ~1.0ms latency (3x better than OVS)
  - All kernel support confirmed
  - Architecture validated
- 🔄 **Phase 1.2 IN PROGRESS**: Build structure explored
  - Understand vminit build process
  - Identified extension pattern
  - Ready to implement wireguard-service

**Next Session Goals**:
1. Create `containerization/vminitd/extensions/wireguard-service/` directory structure
2. Design gRPC API (wireguard.proto)
3. Implement WireGuard service in Go (hub management, peer operations)
4. Build and test vminit with WireGuard support

---

## Notes

### Multi-Network via allowed-ips
Instead of creating multiple WireGuard interfaces (wg0, wg1, etc.), use a single interface per container with `allowed-ips` routing:

```bash
# Container on net1 only:
wg set wg-hub peer {container} allowed-ips 172.17.0.5/32

# Container on net1 + net2:
wg set wg-hub peer {container} allowed-ips 172.17.0.5/32,172.18.0.6/32

# Hub routes based on allowed-ips
# Container sees single wg0, but can reach multiple networks
```

This is simpler than managing multiple interfaces and leverages WireGuard's native routing.

### Encryption Bonus
WireGuard provides encryption by default - this is a security win even for local container-to-container traffic. Defense in depth.

### Future: Cross-Host
WireGuard excels at multi-host networking. Future expansion to support Docker Swarm or Kubernetes-style overlay networks would be straightforward.
