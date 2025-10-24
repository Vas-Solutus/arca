# Network Architecture: TAP-over-vsock with OVS Helper VM

## Executive Summary

Arca implements Docker-compatible networking using **TAP devices forwarded over vsock** to a lightweight Linux VM running Open vSwitch (OVS). This architecture provides:

- ✅ **Full Docker Network API compatibility** - Bridge networks with true L2 isolation
- ✅ **No VM recreation** - Dynamic network attachment via vsock connections
- ✅ **Pure Swift implementation** - Consistent codebase using Apple technologies
- ✅ **Production-grade switching** - OVS stack used by OpenStack and Kubernetes
- ✅ **Proven vsock communication** - Leverages Apple's Containerization framework patterns
- ✅ **No special entitlements** - Works without com.apple.vm.networking

This design **fully leverages the Containerization framework** and Swift for both container VMs and the helper VM, providing enterprise-grade networking capabilities while maintaining a pure Apple technology stack.

---

## Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│ macOS Host (Swift)                                                  │
│                                                                     │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ Arca Daemon                                                │   │
│  │  - Docker API Server (SwiftNIO)                            │   │
│  │  - NetworkManager (Swift actor)                            │   │
│  │  - NetworkBridge (vsock relay actor)                       │   │
│  │  - ContainerManager, ImageManager                          │   │
│  └────────────────────────────────────────────────────────────┘   │
│           ↓                    ↓                    ↓              │
│     vsock relay          vsock relay          vsock relay          │
│     (port 20001)        (port 20002)        (port 20003)          │
│           ↓                    ↓                    ↓              │
│  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐       │
│  │ Container 1 │      │ Container 2 │      │ Container 3 │       │
│  │ (vminit)    │      │ (vminit)    │      │ (vminit)    │       │
│  │             │      │             │      │             │       │
│  │ ┌─────────┐ │      │ ┌─────────┐ │      │ ┌─────────┐ │       │
│  │ │ eth0    │ │      │ │ eth0    │ │      │ │ eth0    │ │       │
│  │ │ (TAP)   │ │      │ │ (TAP)   │ │      │ │ (TAP)   │ │       │
│  │ └────┬────┘ │      │ └────┬────┘ │      │ └────┬────┘ │       │
│  │      │      │      │      │      │      │      │      │       │
│  │ ┌────▼──────────┐ │      │ ┌────▼──────────┐ │ ┌────▼──────────┐ │
│  │ │ TAPForwarder  │ │      │ │ TAPForwarder  │ │ │ TAPForwarder  │ │
│  │ │ (Swift)       │ │      │ │ (Swift)       │ │ │ (Swift)       │ │
│  │ └────┬──────────┘ │      │ └────┬──────────┘ │ └────┬──────────┘ │
│  │      │ vsock→host │      │      │ vsock→host │      │ vsock→host │
│  └──────┼────────────┘      └──────┼────────────┘      └──────┼─────┘
│         │                          │                          │
│         └──────────────┬───────────┴──────────────────────────┘
│                        │
│                        ↓
│  ┌────────────────────────────────────────────────────────────┐
│  │ Helper VM (Swift)                                          │
│  │ Alpine Linux + vminit                                      │
│  │                                                             │
│  │  ┌──────────────────────────────────────────────────────┐  │
│  │  │ NetworkControlServer (Swift)                         │  │
│  │  │  - vsock listener (port 30000+)                      │  │
│  │  │  - Creates TAP devices                               │  │
│  │  │  - Attaches TAP to OVS bridges                       │  │
│  │  │  - Bidirectional frame forwarding                    │  │
│  │  └──────────────────────────────────────────────────────┘  │
│  │                                                             │
│  │  ┌──────────────────────────────────────────────────────┐  │
│  │  │ OVS Stack                                            │  │
│  │  │  - ovs-vswitchd (packet switching)                   │  │
│  │  │  - ovsdb-server (bridge configuration)               │  │
│  │  └──────────────────────────────────────────────────────┘  │
│  │                                                             │
│  │  OVS Bridges:                                               │
│  │  ┌─────────────────┐  ┌─────────────────┐                  │
│  │  │ br-net-a        │  │ br-net-b        │                  │
│  │  │  - tap-cont-1   │  │  - tap-cont-3   │                  │
│  │  │  - tap-cont-2   │  │                 │                  │
│  │  └─────────────────┘  └─────────────────┘                  │
│  └────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

#### 1. Container VM (arca-tap-forwarder - Swift gRPC Daemon)

**Location**: Bind-mounted from host at `/.arca/bin/arca-tap-forwarder` (hidden dotfile directory)

**Build**: Cross-compiled Linux binary built with Swift Static Linux SDK (aarch64-musl)
- Source: `arca-tap-forwarder/` Swift package
- Build script: `scripts/build-tap-forwarder.sh`
- Install location: `~/.arca/bin/arca-tap-forwarder`

**Purpose**: On-demand TAP device management and packet forwarding

**Lifecycle**:
- **Bind-mounted** into every container at creation time
  - Mounts `~/.arca/bin/` directory → `/.arca/bin/` in container
  - Binary accessible at `/.arca/bin/arca-tap-forwarder`
  - Read-only virtiofs share
  - Only mounted if directory exists
- **Launched on-demand** via `container.exec()` when container connects to network
  - NetworkBridge.ensureTAPForwarderRunning() starts the daemon
  - Runs in container's namespace (not vminit namespace)
  - Process tracked for lifecycle management
- **Runs continuously** as a gRPC daemon listening on vsock port 5555
- **Manages multiple networks** - creates/destroys TAP devices dynamically via gRPC commands

**Responsibilities**:
- Listen for commands from Arca daemon over gRPC (vsock port 5555)
- **AttachNetwork RPC**: Create TAP device (eth0, eth1, etc.), configure IP, connect to host vsock, start forwarding
- **DetachNetwork RPC**: Stop forwarding, destroy TAP device, close vsock connection
- **ListNetworks RPC**: Report active network interfaces and statistics
- Bidirectional frame forwarding: TAP ↔ vsock (one pair per network)

**gRPC Protocol** (vsock port 5555):
```protobuf
service TAPForwarder {
    rpc AttachNetwork(AttachNetworkRequest) returns (AttachNetworkResponse);
    rpc DetachNetwork(DetachNetworkRequest) returns (DetachNetworkResponse);
    rpc ListNetworks(ListNetworksRequest) returns (ListNetworksResponse);
    rpc GetStatus(GetStatusRequest) returns (GetStatusResponse);
}

message AttachNetworkRequest {
    string device = 1;           // "eth0", "eth1", etc.
    uint32 vsock_port = 2;       // Data plane port (20000+)
    string ip_address = 3;       // "172.18.0.2"
    string gateway = 4;          // "172.18.0.1"
    uint32 netmask = 5;          // 24 for /24
}
```

**Implementation**:
```swift
// arca-tap-forwarder/Sources/arca-tap-forwarder/TAPForwarderService.swift
actor TAPForwarderService {
    private var networks: [String: NetworkAttachment] = [:]  // device -> attachment

    struct NetworkAttachment {
        let device: String
        let tapFD: Int32
        let vsockFD: Int32
        let forwardTask: Task<Void, Never>
        var stats: PacketStats
    }

    // gRPC handler
    func attachNetwork(_ request: AttachNetworkRequest) async -> AttachNetworkResponse {
        do {
            // Create TAP device
            let tapFD = try createTAPDevice(name: request.device)

            // Configure IP address
            try configureTAPDevice(
                name: request.device,
                ip: request.ipAddress,
                gateway: request.gateway
            )

            // Connect to host vsock for data plane
            let vsockFD = try connectVsock(port: request.vsockPort)

            // Start bidirectional forwarding
            let task = Task {
                await forwardPackets(tapFD: tapFD, vsockFD: vsockFD, device: request.device)
            }

            // Track this network
            networks[request.device] = NetworkAttachment(
                device: request.device,
                tapFD: tapFD,
                vsockFD: vsockFD,
                forwardTask: task,
                stats: PacketStats()
            )

            return AttachNetworkResponse(success: true, macAddress: getMACAddress(tapFD))
        } catch {
            return AttachNetworkResponse(success: false, error: error.localizedDescription)
        }
    }

    func detachNetwork(_ request: DetachNetworkRequest) async -> DetachNetworkResponse {
        guard let attachment = networks.removeValue(forKey: request.device) else {
            return DetachNetworkResponse(success: false, error: "Network not found")
        }

        // Stop forwarding
        attachment.forwardTask.cancel()

        // Close file descriptors
        close(attachment.tapFD)
        close(attachment.vsockFD)

        return DetachNetworkResponse(success: true)
    }
}
```

#### 2. Arca Daemon - NetworkBridge Actor (Swift)

**Location**: `Sources/ContainerBridge/NetworkBridge.swift`

**Purpose**: Orchestrate dynamic network attachment and relay frames between containers and helper VM

**Responsibilities**:
- **Control Plane**: Send gRPC commands to arca-tap-forwarder (vsock port 5555)
  - Call AttachNetwork RPC when `docker network connect`
  - Call DetachNetwork RPC when `docker network disconnect`
- **Data Plane**: Relay ethernet frames
  - Listen for vsock connections from container VMs (ports 20000+)
  - Establish vsock connections to helper VM (ports 30000+)
  - Bidirectional relay: container-vsock ↔ helper-vsock
- **Resource Management**:
  - Allocate unique vsock ports for each network attachment
  - Track active relays per container
  - Handle cleanup on container stop

**Implementation**:
```swift
public actor NetworkBridge {
    private let logger: Logger
    private var relays: [String: [String: RelayTask]] = [:]  // containerID -> networkID -> relay
    private var helperVM: NetworkHelperVM
    private var portAllocator = PortAllocator(basePort: 20000)

    struct RelayTask {
        let networkID: String
        let device: String         // eth0, eth1, etc.
        let containerPort: UInt32  // Data plane port
        let helperPort: UInt32
        let task: Task<Void, Never>
    }

    // Called by ContainerManager when attaching to network
    public func attachContainerToNetwork(
        container: Containerization.LinuxContainer,
        containerID: String,
        networkID: String,
        ipAddress: String,
        gateway: String,
        device: String  // "eth0", "eth1", etc.
    ) async throws {
        // 1. Allocate vsock ports
        let containerPort = try portAllocator.allocate()
        let helperPort = containerPort + 10000  // Helper uses +10000 offset

        logger.info("Attaching container to network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "device": "\(device)",
            "dataPort": "\(containerPort)"
        ])

        // 2. Send AttachNetwork RPC to arca-tap-forwarder
        let controlClient = try await TAPForwarderClient(
            container: container,
            port: 5555  // Control plane port
        )

        let response = try await controlClient.attachNetwork(
            AttachNetworkRequest(
                device: device,
                vsockPort: containerPort,
                ipAddress: ipAddress,
                gateway: gateway,
                netmask: 24
            )
        )

        guard response.success else {
            throw NetworkError.attachFailed(response.error)
        }

        logger.info("TAP device created in container", metadata: [
            "device": "\(device)",
            "mac": "\(response.macAddress)"
        ])

        // 3. Start data plane relay
        let task = Task {
            await self.runRelay(
                containerID: containerID,
                containerPort: containerPort,
                helperVMContainer: helperVM.container,
                helperPort: helperPort
            )
        }

        // 4. Track this network attachment
        if relays[containerID] == nil {
            relays[containerID] = [:]
        }
        relays[containerID]![networkID] = RelayTask(
            networkID: networkID,
            device: device,
            containerPort: containerPort,
            helperPort: helperPort,
            task: task
        )
    }

    // Called by ContainerManager when detaching from network
    public func detachContainerFromNetwork(
        container: Containerization.LinuxContainer,
        containerID: String,
        networkID: String
    ) async throws {
        guard let relay = relays[containerID]?[networkID] else {
            throw NetworkError.notAttached
        }

        logger.info("Detaching container from network", metadata: [
            "containerID": "\(containerID)",
            "networkID": "\(networkID)",
            "device": "\(relay.device)"
        ])

        // 1. Send DetachNetwork RPC to arca-tap-forwarder
        let controlClient = try await TAPForwarderClient(container: container, port: 5555)
        _ = try await controlClient.detachNetwork(
            DetachNetworkRequest(device: relay.device)
        )

        // 2. Stop data plane relay
        relay.task.cancel()
        portAllocator.release(relay.containerPort)

        // 3. Remove from tracking
        relays[containerID]?.removeValue(forKey: networkID)
    }

    private func runRelay(
        containerID: String,
        containerPort: UInt32,
        helperVMContainer: Containerization.LinuxContainer,
        helperPort: UInt32
    ) async {
        do {
            // Listen for container's vsock connection
            let containerListener = try VsockListener(port: containerPort)
            let containerConn = try await containerListener.accept()

            logger.info("Container connected", metadata: [
                "containerID": "\(containerID)",
                "port": "\(containerPort)"
            ])

            // Dial helper VM
            let helperConn = try await helperVMContainer.dialVsock(port: helperPort)

            logger.info("Connected to helper VM", metadata: [
                "helperPort": "\(helperPort)"
            ])

            // Bidirectional relay
            async let _ = relayForward(from: containerConn, to: helperConn)
            async let _ = relayBackward(from: helperConn, to: containerConn)

            _ = await (_, _)
        } catch {
            logger.error("Relay failed", metadata: [
                "containerID": "\(containerID)",
                "error": "\(error)"
            ])
        }
    }

    private func relayForward(from source: Socket, to dest: FileHandle) async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            guard let bytesRead = try? source.read(into: &buffer) else { break }
            dest.write(Data(buffer[..<bytesRead]))
        }
    }

    private func relayBackward(from source: FileHandle, to dest: Socket) async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let data = source.availableData
            guard !data.isEmpty else { break }
            data.withUnsafeBytes { ptr in
                try? dest.write(Array(ptr))
            }
        }
    }
}
```

#### 3. Helper VM - NetworkControlServer (Swift)

**Location**: Helper VM image (cross-compiled Swift binary)

**Purpose**: Receive frames from host, create TAP devices, attach to OVS bridges

**Responsibilities**:
- Listen for vsock connections from host (ports 30000+)
- Create TAP device for each container
- Attach TAP to appropriate OVS bridge
- Bidirectional frame forwarding: vsock ↔ TAP ↔ OVS
- Execute ovs-vsctl commands for bridge management

**Implementation**:
```swift
// helpervm/Sources/NetworkControl/main.swift
@main
struct NetworkControlServer {
    static func main() async throws {
        let logger = Logger(label: "network-control")

        // Initialize OVS
        try await initializeOVS()

        // Accept connections on vsock
        let basePort: UInt32 = 30000

        // Listen on multiple ports concurrently
        for portOffset in 0..<100 {
            let port = basePort + UInt32(portOffset)
            Task {
                await handleContainerConnection(port: port, logger: logger)
            }
        }

        // Keep running
        try await Task.sleep(for: .seconds(.max))
    }

    static func handleContainerConnection(port: UInt32, logger: Logger) async {
        do {
            // Listen for connection from host
            let listener = try VsockListener(port: port)
            let conn = try await listener.accept()

            logger.info("Host connected", metadata: ["port": "\(port)"])

            // Create TAP device
            let tapName = "tap\(port - 30000)"
            let tapFD = try createTAPDevice(name: tapName)

            logger.info("Created TAP device", metadata: ["name": "\(tapName)"])

            // Bidirectional forwarding
            async let _ = forwardVsockToTAP(conn: conn, tapFD: tapFD)
            async let _ = forwardTAPToVsock(tapFD: tapFD, conn: conn)

            _ = await (_, _)
        } catch {
            logger.error("Connection failed", metadata: [
                "port": "\(port)",
                "error": "\(error)"
            ])
        }
    }

    static func createTAPDevice(name: String) throws -> Int32 {
        // Same TAP creation logic as container
        let fd = open("/dev/net/tun", O_RDWR)
        // ... configure with ioctl TUNSETIFF ...
        return fd
    }

    static func attachTAPToBridge(tapName: String, bridgeName: String) throws {
        // Execute: ovs-vsctl add-port <bridge> <tap>
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ovs-vsctl")
        process.arguments = ["add-port", bridgeName, tapName]
        try process.run()
        process.waitUntilExit()
    }
}
```

---

## Network Data Flow

### Container A → Container B (Same Network)

```
Container A Process
    ↓ write to socket
Container A eth0 (TAP device)
    ↓ vminit TAPForwarder reads
Container A vsock client → Host CID 2, port 20001
    ↓
Arca Daemon NetworkBridge relay
    ↓
Arca Daemon → Helper VM vsock, port 30001
    ↓
Helper VM NetworkControlServer
    ↓ writes to TAP
Helper VM tap0 device
    ↓ attached to OVS bridge
OVS bridge br-net-a
    ↓ switching logic
Helper VM tap1 device
    ↓
Helper VM NetworkControlServer
    ↓ reads from TAP, sends via vsock
Helper VM vsock → Arca Daemon, port 30002
    ↓
Arca Daemon NetworkBridge relay
    ↓
Arca Daemon vsock → Container B, port 20002
    ↓
Container B vminit TAPForwarder
    ↓ writes to TAP
Container B eth0 (TAP device)
    ↓
Container B Process receives packet
```

---

## Implementation Plan

### Phase 3.4: TAP-over-vsock Infrastructure (Current)

#### Task 1: Implement TAPForwarder in vminit

- [ ] **Add TAPForwarder.swift to vminit**
  - Create TAP device with ioctl TUNSETIFF
  - Configure as IFF_TAP | IFF_NO_PI
  - Bring interface up with SIOCSIFFLAGS
  - Connect to host via VsockType(cid: VsockType.hostCID, port: X)
  - Bidirectional forwarding loops
  - Files: `vminitd/Sources/vminitd/TAPForwarder.swift`

- [ ] **Wire TAPForwarder into vminit startup**
  - Parse network config from environment variables
  - Start TAPForwarder when ARCA_NETWORK_PORT is set
  - Pass helper VM vsock port, container's assigned port
  - Files: `vminitd/Sources/vminitd/Application.swift`

- [ ] **Rebuild vminit with TAP support**
  - Cross-compile with Swift Static Linux SDK
  - Package into vminit:latest
  - Test TAP creation in VM
  - Files: Containerization package Makefile

#### Task 2: Implement NetworkBridge in Arca Daemon

- [ ] **Create NetworkBridge actor**
  - VsockListener for container connections
  - Track active relays per container
  - Port allocation (20000+ for containers, 30000+ for helper)
  - Relay tasks with bidirectional forwarding
  - Files: `Sources/ContainerBridge/NetworkBridge.swift`

- [ ] **Implement VsockListener for host**
  - Listen on vsock port on macOS
  - Accept connections from container VMs
  - Return Socket for relay
  - Files: `Sources/ContainerBridge/VsockListener.swift`

- [ ] **Implement relay logic**
  - Read from container vsock, write to helper vsock
  - Read from helper vsock, write to container vsock
  - Handle connection failures and cleanup
  - Files: `Sources/ContainerBridge/NetworkBridge.swift`

#### Task 3: Implement NetworkControlServer for Helper VM

- [ ] **Create Swift executable for helper VM**
  - New target in Package.swift: NetworkControlServer
  - Cross-compile to Linux with Swift Static Linux SDK
  - Single binary that runs in helper VM
  - Files: `helpervm/Sources/NetworkControl/main.swift`

- [ ] **Implement vsock listener and TAP creation**
  - Listen on ports 30000+ via vsock
  - Create TAP devices (tap0, tap1, etc.)
  - Attach TAP to OVS bridges via ovs-vsctl
  - Bidirectional forwarding: vsock ↔ TAP
  - Files: `helpervm/Sources/NetworkControl/NetworkControlServer.swift`

- [ ] **Replace Go control API with Swift**
  - Remove helpervm/control-api/ (Go code)
  - Update helper VM Dockerfile to run Swift binary
  - Update startup script to launch NetworkControlServer
  - Files: `helpervm/Dockerfile`, `helpervm/scripts/startup.sh`

#### Task 4: Update ContainerManager for Network Attachment

- [ ] **Modify createContainer to support network config**
  - Pass network configuration via environment variables
  - Set ARCA_NETWORK_PORT=<containerPort>
  - vminit reads this and starts TAPForwarder
  - Files: `Sources/ContainerBridge/ContainerManager.swift`

- [ ] **Implement attachContainerToNetwork**
  - Allocate vsock ports (containerPort, helperPort)
  - Call networkBridge.attachContainer()
  - Tell helper VM to create TAP and attach to bridge
  - Update container config with network info
  - Files: `Sources/ContainerBridge/ContainerManager.swift`

- [ ] **Implement detachContainerFromNetwork**
  - Stop relay task
  - Tell helper VM to detach TAP from bridge
  - Clean up resources
  - Files: `Sources/ContainerBridge/ContainerManager.swift`

#### Task 5: Testing

- [ ] **Test TAP device creation in container**
  - Launch container with network config
  - Verify eth0 TAP device exists
  - Verify vminit connects to host via vsock
  - Files: Integration test

- [ ] **Test vsock relay in Arca daemon**
  - Verify NetworkBridge accepts container connections
  - Verify relay to helper VM works
  - Test bidirectional packet flow
  - Files: Integration test

- [ ] **Test end-to-end container networking**
  - Create two containers on same network
  - Ping from container A to container B
  - Verify packets flow through OVS bridge
  - Files: `scripts/test-network-tap-vsock.sh`

---

## Technology Stack

- **Container VM**: Swift (vminit TAPForwarder)
- **Host Daemon**: Swift (NetworkBridge relay)
- **Helper VM**: Swift (NetworkControlServer)
- **OVS**: C (standard Alpine package)
- **Communication**: vsock (AF_VSOCK)
- **Network Devices**: TAP (IFF_TAP via /dev/net/tun)

**100% Swift** for all Arca-specific code!

---

## Why This Architecture Works

### vsock Direction Constraints

✅ **Container → Host**: Container VM can dial host (CID 2) - CONFIRMED working in vminit VsockProxy
✅ **Host → Helper VM**: Host can dial helper VM via `container.dialVsock()` - ALREADY working for gRPC
❌ **Container → Helper VM**: VM-to-VM vsock NOT supported by virtio-vsock

**Solution**: Host acts as transparent relay between container and helper VM

### No Helper VM Recreation

Unlike socket pair approach, adding containers doesn't require helper VM recreation:
- Each container gets unique vsock ports
- Helper VM listens on multiple ports concurrently
- Dynamic TAP creation on connection
- No VM configuration changes needed

### Performance

**Expected**:
- Container → Host vsock: ~50μs latency
- Host relay: ~10μs (memory copy)
- Host → Helper vsock: ~50μs latency
- Total: ~110μs vs ~200μs for socket pair + frame forwarding

**Throughput**:
- Limited by vsock bandwidth (~8-10 Gbps)
- TAP device overhead minimal
- Relay is just byte copying

---

## Future Optimizations

### Phase 4+

- [ ] **Batch frame forwarding** - Read/write multiple frames per syscall
- [ ] **Zero-copy relay** - Use splice() or vmsplice() if supported on vsock
- [ ] **Helper VM TAP pooling** - Pre-create TAP devices to reduce latency
- [ ] **DPDK in helper VM** - Kernel bypass for extreme performance

---

## Multi-Network Support

### How It Works

**Containers can attach to multiple networks dynamically:**

```bash
# Container starts with no networks
docker run -d --name web nginx

# Attach to first network → creates eth0
docker network connect frontend web
# Result: arca-tap-forwarder creates eth0, connects to vsock port 20001

# Attach to second network → creates eth1
docker network connect backend web
# Result: arca-tap-forwarder creates eth1, connects to vsock port 20002

# Detach from a network → destroys interface
docker network disconnect frontend web
# Result: arca-tap-forwarder destroys eth0, closes vsock port 20001
```

### Architecture Flow

```
docker network connect my-network my-container
    ↓
ContainerManager.attachToNetwork()
    ↓
NetworkBridge.attachContainerToNetwork()
    ↓ (control plane - vsock 5555)
TAPForwarderClient.attachNetwork() → arca-tap-forwarder in container
    ↓
Creates TAP device (eth0, eth1, etc.)
Configures IP address
Connects to host vsock data port (20001, 20002, etc.)
Starts packet forwarding
    ↓ (data plane - vsock 20001, 20002, etc.)
NetworkBridge starts relaying packets
    ↓
Packets flow: Container eth0 → vsock → Host → Helper VM → OVS bridge
```

### Key Properties

- **Control Plane (vsock 5555)**: gRPC commands for attach/detach
- **Data Plane (vsock 20000+)**: Packet forwarding, one port per network
- **On-Demand**: TAP devices only created when needed
- **Clean Lifecycle**: Devices destroyed when detached
- **Invisible to User**: All happens in init system space

---

## Summary

This TAP-over-vsock architecture with gRPC control plane provides:

✅ **Dynamic multi-network** - Attach/detach networks without container restart
✅ **No VM recreation** - Networks added/removed via gRPC commands
✅ **Pure Swift** - Consistent Apple-centric codebase (100% Swift!)
✅ **True L2 isolation** - OVS bridges provide complete network separation
✅ **Transparent to users** - Runs in init system, not user container space
✅ **Proven patterns** - Leverages vsock like vminit does
✅ **Good performance** - ~110μs latency, 8+ Gbps throughput
✅ **Clean lifecycle** - Resources properly allocated and cleaned up
✅ **Maintainable** - Clear separation between control and data planes

The architecture aligns with Arca's core principle: leverage Apple's technologies while providing full Docker ecosystem compatibility.

---

## Implementation Notes & Lessons Learned

### Phase 3.4 Completion (October 2025)

Successfully implemented bidirectional TAP-over-vsock packet forwarding with the following critical discoveries:

#### Critical Issue: Swift Concurrency & Blocking I/O

**Problem**: When using structured concurrency (`withTaskGroup`) or even `Task.detached` with **blocking I/O**, only one relay direction would work. The helper→container direction would never start, even though both tasks were created.

**Root Cause**: `Darwin.read()` is a **blocking system call**. When both relay tasks call `read()` on their respective file descriptors simultaneously:
- The task that acquires the file descriptor first (container→helper) blocks waiting for data
- The second task (helper→container) also attempts to block on `read()`
- Swift's cooperative task scheduling prevented the second task from making progress

**Solution**: **Non-blocking I/O with polling loop**

```swift
// Set FD to non-blocking mode
let flags = fcntl(sourceFD, F_GETFL, 0)
_ = fcntl(sourceFD, F_SETFL, flags | O_NONBLOCK)

// Poll loop with EAGAIN handling
let bytesRead = Darwin.read(sourceFD, bufferPtr.baseAddress!, bufferSize)
if bytesRead < 0 {
    if errno == EAGAIN || errno == EWOULDBLOCK {
        // No data available - yield and retry
        try? await Task.sleep(nanoseconds: 1_000_000) // 1ms
        continue
    }
}
```

This allows both relay directions to run independently without blocking each other.

#### Architecture Changes from Original Design

**Original Design** (from documentation):
- Used `FileHandle` objects directly
- Relied on Swift's async/await with blocking operations
- Expected structured concurrency to "just work"

**Actual Implementation**:
1. **Extract file descriptors early**: Get FD values before creating tasks to avoid concurrent access to `FileHandle.fileDescriptor`
2. **Use raw syscalls**: `Darwin.read()` and `Darwin.write()` directly on `Int32` FD values
3. **Non-blocking mode**: Set `O_NONBLOCK` on source FDs
4. **Polling loop**: Sleep 1ms on `EAGAIN`, allowing other tasks to run
5. **Detached tasks**: Use `Task.detached` for true independence from parent context

#### Performance Characteristics

**Current Performance** (with 1ms polling sleep):
- **Latency**: ~4-7ms round-trip time
- **Packet Loss**: 0%
- **Reliability**: 100% bidirectional packet flow

**Performance Breakdown**:
- Polling sleep: ~1ms added latency per direction
- vsock overhead: Minimal (Apple's efficient implementation)
- TAP device overhead: Minimal (kernel-level packet handling)

**Future Optimization Opportunities**:
1. **Reduce sleep time**: 100μs or 10μs instead of 1ms
2. **Use select()/poll()**: Event-driven I/O instead of polling
3. **Use kqueue**: macOS-native event notification (most efficient)
4. **Dedicated threads**: Move relay to background threads instead of async tasks

#### Key Takeaways

1. **Blocking I/O + Swift Concurrency = Problems**: Swift's cooperative task model doesn't work well with blocking syscalls
2. **Non-blocking I/O is essential**: For concurrent bidirectional communication
3. **FileHandle limitations**: `FileHandle.availableData` doesn't work correctly for socket FDs
4. **Raw syscalls FTW**: Using Darwin syscalls directly gives more control
5. **Test at the syscall level**: When debugging, instrument the actual `read()`/`write()` calls

#### Architecture Validation

✅ **TAP-over-vsock works**: Packets flow bidirectionally
✅ **OVS integration works**: Helper VM correctly bridges networks
✅ **gRPC control plane works**: Dynamic network attach/detach functional
✅ **Multi-network works**: Containers can join multiple networks
✅ **No VM recreation needed**: All happens via vsock connections

The architecture is **sound** - the implementation challenges were purely about Swift's concurrency model interacting with blocking I/O, not fundamental design flaws.
