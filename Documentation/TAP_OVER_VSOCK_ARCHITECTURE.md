# TAP-over-vsock Architecture

## Overview

This document provides a detailed explanation of Arca's TAP-over-vsock networking implementation, including packet flow paths, vsock communication channels, performance characteristics, and security considerations.

## Architecture Summary

Arca implements Docker-compatible bridge networking using a **TAP-over-vsock** architecture that tunnels Ethernet frames between three components:

1. **Container VMs** - Run Linux containers with TAP devices (eth0, eth1, etc.)
2. **Arca Daemon** (Host) - Relays packets between container VMs and helper VM
3. **Helper VM** - Runs OVS/OVN for bridge networking and routing

**Key Innovation**: Unlike traditional Docker networking, Arca's containers are full Linux VMs. Network interfaces cannot be dynamically added to VMs, so we use TAP devices inside containers and forward frames over vsock to achieve dynamic network attachment without VM restart.

## vsock Communication Channels

### Channel 1: vminit vsock Proxy (Container ↔ Arca Daemon)

**Purpose**: General container management and gRPC control API

- **Direction**: Container VM ↔ Arca Daemon (host)
- **Port**: 9999 (hardcoded in vminit)
- **Protocol**: gRPC over vsock
- **Implementation**: `vminit` process inside container VM proxies vsock port 9999 to Unix socket
- **Used by**:
  - ContainerManager for container lifecycle (start, stop, exec, logs)
  - TAPForwarderClient for configuring arca-tap-forwarder daemon

**How it works**:
```
Container VM (CID=X)                 Host (CID=2)
┌─────────────────────┐             ┌──────────────────┐
│  arca-tap-forwarder │             │  Arca Daemon     │
│  (gRPC client)      │             │                  │
└──────────┬──────────┘             └────────┬─────────┘
           │                                 │
           │ gRPC over vsock:9999            │
           │ (ConfigureNetwork RPC)          │
           └─────────────────────────────────┘
                 Container.dialVsock(9999)
                 via Containerization API
```

The `Container.dialVsock(9999)` call in Arca daemon returns a FileHandle that's connected to the vminit process inside the container. vminit then forwards the connection to the actual service (arca-tap-forwarder) listening on a Unix socket.

### Channel 2: TAP Packet Forwarding (Container ↔ Arca Daemon)

**Purpose**: Forward Ethernet frames from TAP devices to Arca daemon for relay

- **Direction**: Container VM ↔ Arca Daemon (host)
- **Ports**: Dynamically allocated (base 20000, incremented per network attachment)
- **Protocol**: Raw frames with 4-byte length prefix
- **Implementation**: Direct vsock connection, **bypasses vminit proxy**
- **Used by**:
  - arca-tap-forwarder (inside container) reads from TAP device, writes to vsock
  - NetworkBridge (in Arca daemon) reads from vsock, relays to helper VM

**How it works**:
```
Container VM (CID=X)                 Host (CID=2)
┌─────────────────────┐             ┌──────────────────┐
│  arca-tap-forwarder │             │  NetworkBridge   │
│  (packet forwarder) │             │  (packet relay)  │
│                     │             │                  │
│  TAP device (eth0)  │             │                  │
│         ↕           │             │                  │
│  Read/Write frames  │             │                  │
│         ↕           │             │                  │
│  vsock:20000 ←──────┼─────────────┼→ vsock listener  │
│  (direct socket)    │             │  (non-blocking)  │
└─────────────────────┘             └──────────────────┘
           ↑                                 ↓
           │                                 │
           │   Frame: [4-byte len][data]     │
           └─────────────────────────────────┘
              Raw vsock connection
              (NOT via vminit proxy)
```

**Critical Detail**: This channel does **NOT** go through vminit's vsock proxy. The arca-tap-forwarder process opens a direct vsock socket to the host's CID (2) on the allocated port (e.g., 20000).

### Channel 3: TAP Packet Forwarding (Arca Daemon ↔ Helper VM)

**Purpose**: Forward relayed frames from Arca daemon to helper VM's OVS bridge

- **Direction**: Arca Daemon (host) ↔ Helper VM
- **Ports**: Dynamically allocated (base 30000 = containerPort + 10000 offset)
- **Protocol**: Raw frames with 4-byte length prefix
- **Implementation**: Direct vsock connection
- **Used by**:
  - NetworkBridge (in Arca daemon) writes frames to helper VM
  - TAPRelay (in helper VM) reads from vsock, writes to TAP device attached to OVS bridge

**How it works**:
```
Host (CID=2)                         Helper VM (CID=3)
┌──────────────────┐                ┌──────────────────────┐
│  NetworkBridge   │                │  TAPRelay            │
│  (packet relay)  │                │  (control-api)       │
│                  │                │                      │
│  vsock:30000 ────┼────────────────┼→ vsock listener      │
│  (non-blocking)  │                │  (goroutine)         │
│                  │                │         ↕            │
│                  │                │  TAP device (port-X) │
│                  │                │         ↕            │
│                  │                │  OVS bridge (br-X)   │
└──────────────────┘                └──────────────────────┘
           ↑                                 ↓
           │                                 │
           │   Frame: [4-byte len][data]     │
           └─────────────────────────────────┘
              Raw vsock connection
```

### Channel 4: Helper VM Control API (Arca Daemon ↔ Helper VM)

**Purpose**: Control plane for network management (create/delete bridges, attach/detach containers)

- **Direction**: Arca Daemon (host) ↔ Helper VM
- **Port**: 9999 (fixed)
- **Protocol**: gRPC over vsock
- **Implementation**: OVNClient connects via `Container.dialVsock(9999)`
- **Used by**:
  - NetworkManager for bridge creation/deletion
  - NetworkBridge for attaching/detaching TAP relays

**How it works**:
```
Host (CID=2)                         Helper VM (CID=3)
┌──────────────────┐                ┌──────────────────────┐
│  OVNClient       │                │  NetworkControl      │
│  (gRPC client)   │                │  (gRPC server)       │
│                  │                │                      │
│  vsock:9999 ─────┼────────────────┼→ vsock listener      │
│                  │                │                      │
└──────────────────┘                └──────────────────────┘
           │                                 │
           │ gRPC RPCs:                      │
           │ - CreateBridge                  │
           │ - DeleteBridge                  │
           │ - AttachContainer               │
           │ - DetachContainer               │
           └─────────────────────────────────┘
              Container.dialVsock(9999)
```

## Complete Packet Flow: Container to Container

Let's trace a ping packet from Container A to Container B on the same network:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CONTAINER A (VM with CID=4)                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Application Process                                                   │  │
│  │   ping 172.18.0.3                                                     │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ write()                                      │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Kernel Network Stack                                                  │  │
│  │   - IP routing: 172.18.0.3 via eth0                                  │  │
│  │   - ARP resolution: get MAC for 172.18.0.3                           │  │
│  │   - Ethernet frame: [dst_mac][src_mac][type][IP][ICMP][data]        │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ write()                                      │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAP Device (eth0)                                                     │  │
│  │   IP: 172.18.0.2/16                                                  │  │
│  │   MAC: 02:xx:xx:xx:xx:xx                                             │  │
│  │   Gateway: 172.18.0.1                                                │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ read() by arca-tap-forwarder                │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ arca-tap-forwarder (Go daemon)                                        │  │
│  │   - Read frame from TAP device (/dev/net/tun)                        │  │
│  │   - Prepend 4-byte length header                                     │  │
│  │   - Write [length][frame_data] to vsock                              │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ vsock write to CID=2:20000                  │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               │ [VSOCK HYPERVISOR TRANSPORT]
                               │ VM-to-Host communication via hypervisor
                               │
                               ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HOST (macOS, CID=2)                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ NetworkBridge Actor (Arca Daemon)                                     │  │
│  │   RELAY TASK 1: Container → Helper                                   │  │
│  │   - vsock listener on port 20000 (for Container A, eth0)            │  │
│  │   - Read with non-blocking I/O: poll + EAGAIN handling              │  │
│  │   - Read 4-byte length header                                        │  │
│  │   - Read frame_data based on length                                  │  │
│  │   - Write [length][frame_data] to helper VM vsock:30000             │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ vsock write to CID=3:30000                  │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               │ [VSOCK HYPERVISOR TRANSPORT]
                               │ Host-to-VM communication via hypervisor
                               │
                               ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HELPER VM (Linux, CID=3)                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAPRelay (control-api Go server)                                      │  │
│  │   - vsock listener on port 30000 (for Container A connection)       │  │
│  │   - Read 4-byte length header from vsock                             │  │
│  │   - Read frame_data based on length                                  │  │
│  │   - Write frame to TAP device (port-containerA)                      │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ write()                                      │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAP Device (port-containerA)                                          │  │
│  │   - Internal port attached to OVS bridge                             │  │
│  │   - No IP address (pure L2 port)                                     │  │
│  │   - MAC: 02:xx:xx:xx:xx:xx (Container A's MAC)                       │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ OVS forwarding                               │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ OVS Bridge (br-xxxxxxxxxxxx)                                          │  │
│  │   Subnet: 172.18.0.0/16                                              │  │
│  │   Gateway: 172.18.0.1 (bridge internal interface)                   │  │
│  │                                                                       │  │
│  │   MAC Learning Table:                                                 │  │
│  │   02:xx:xx:xx:xx:xx → port-containerA                                │  │
│  │   02:yy:yy:yy:yy:yy → port-containerB                                │  │
│  │                                                                       │  │
│  │   Forwarding decision:                                                │  │
│  │   - Destination MAC 02:yy:yy:yy:yy:yy → send to port-containerB     │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ OVS forwarding                               │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAP Device (port-containerB)                                          │  │
│  │   - Internal port attached to OVS bridge                             │  │
│  │   - MAC: 02:yy:yy:yy:yy:yy (Container B's MAC)                       │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ read() by TAPRelay                           │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAPRelay (for Container B)                                            │  │
│  │   - Read frame from TAP device                                       │  │
│  │   - Prepend 4-byte length header                                     │  │
│  │   - Write [length][frame_data] to vsock:30001 (Container B port)    │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ vsock write to CID=2:30001                  │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               │ [VSOCK HYPERVISOR TRANSPORT]
                               │ VM-to-Host communication via hypervisor
                               │
                               ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                         HOST (macOS, CID=2)                                 │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ NetworkBridge Actor (Arca Daemon)                                     │  │
│  │   RELAY TASK 2: Helper → Container B                                 │  │
│  │   - vsock listener on port 30001 (for Container B connection)       │  │
│  │   - Read with non-blocking I/O: poll + EAGAIN handling              │  │
│  │   - Read 4-byte length header                                        │  │
│  │   - Read frame_data based on length                                  │  │
│  │   - Write [length][frame_data] to Container B vsock:20001           │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ vsock write to CID=5:20001                  │
└──────────────────────────────┼──────────────────────────────────────────────┘
                               │
                               │ [VSOCK HYPERVISOR TRANSPORT]
                               │ Host-to-VM communication via hypervisor
                               │
                               ↓
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CONTAINER B (VM with CID=5)                         │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ arca-tap-forwarder (Go daemon)                                        │  │
│  │   - vsock listener on port 20001                                     │  │
│  │   - Read 4-byte length header from vsock                             │  │
│  │   - Read frame_data based on length                                  │  │
│  │   - Write frame to TAP device (eth0)                                 │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ write()                                      │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ TAP Device (eth0)                                                     │  │
│  │   IP: 172.18.0.3/16                                                  │  │
│  │   MAC: 02:yy:yy:yy:yy:yy                                             │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ read() by kernel                             │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Kernel Network Stack                                                  │  │
│  │   - Receive Ethernet frame                                           │  │
│  │   - Verify destination MAC matches (02:yy:yy:yy:yy:yy)              │  │
│  │   - Process IP packet                                                │  │
│  │   - Process ICMP echo request                                        │  │
│  │   - Generate ICMP echo reply                                         │  │
│  │   - Send back via eth0 (reverse path)                                │  │
│  └───────────────────────────┬──────────────────────────────────────────┘  │
│                              │ deliver to application                       │
│                              ↓                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │ Application Process (ping)                                            │  │
│  │   - Receives ICMP echo reply                                         │  │
│  │   - Displays: 64 bytes from 172.18.0.3: icmp_seq=1 ttl=64 time=5ms  │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Return Path**: The ICMP reply follows the reverse path through the same infrastructure.

## vsock vs vminit Proxy: Key Differences

### What Goes Through vminit Proxy?

**vminit's vsock proxy** (port 9999) is used for:
1. Container management control plane (start, stop, exec)
2. gRPC communication with arca-tap-forwarder for configuration
3. Any `Container.dialVsock(9999)` calls from Arca daemon

**How it works**:
```
┌──────────────────────────────────────┐
│  Container VM                        │
│  ┌────────────────────────────────┐  │
│  │ vminit process (PID 1)         │  │
│  │   vsock:9999 ←→ Unix socket    │  │
│  └────────────┬───────────────────┘  │
│               │                      │
│               │ Unix socket forward  │
│               ↓                      │
│  ┌────────────────────────────────┐  │
│  │ arca-tap-forwarder             │  │
│  │   Listening on Unix socket     │  │
│  └────────────────────────────────┘  │
└──────────────────────────────────────┘
         ↑
         │ vsock:9999
         │ Container.dialVsock(9999)
         │
┌────────┴─────────────────────────────┐
│  Arca Daemon (Host)                  │
│  TAPForwarderClient.connect()        │
└──────────────────────────────────────┘
```

### What Bypasses vminit Proxy?

**Direct vsock connections** (ports 20000+) are used for:
1. TAP packet forwarding from container to host
2. High-throughput data plane traffic

**How it works**:
```
┌──────────────────────────────────────┐
│  Container VM                        │
│  ┌────────────────────────────────┐  │
│  │ arca-tap-forwarder             │  │
│  │   Direct vsock socket          │  │
│  │   connect(CID=2, port=20000)   │  │
│  └────────────┬───────────────────┘  │
│               │ DIRECT vsock          │
│               │ (no vminit involved)  │
└───────────────┼───────────────────────┘
                │
                │ Raw vsock transport
                │ via hypervisor
                │
┌───────────────┴───────────────────────┐
│  Arca Daemon (Host, CID=2)           │
│  NetworkBridge listening on :20000   │
└──────────────────────────────────────┘
```

**Why bypass vminit for data plane?**
1. **Performance**: Direct vsock avoids Unix socket forwarding overhead
2. **Simplicity**: No need for vminit to manage thousands of dynamic ports
3. **Isolation**: Data plane and control plane are separate

## Performance Analysis

### Packet Path Breakdown

For a single packet from Container A to Container B:

| Hop | From | To | Operation | Estimated Latency |
|-----|------|----|-----------|--------------------|
| 1 | App | TAP device | Kernel write() | ~10μs |
| 2 | TAP | arca-tap-forwarder | read() from /dev/net/tun | ~20μs |
| 3 | Forwarder | Host | vsock write (VM→Host) | ~500μs |
| 4 | Host | NetworkBridge | vsock read + poll (non-blocking) | **~1000μs** |
| 5 | NetworkBridge | Helper VM | vsock write (Host→VM) | ~500μs |
| 6 | Helper VM | TAPRelay | vsock read | ~20μs |
| 7 | TAPRelay | TAP device | write() to /dev/net/tun | ~20μs |
| 8 | TAP | OVS bridge | OVS forwarding logic | ~100μs |
| 9 | OVS | TAP device | OVS forwarding output | ~20μs |
| 10 | TAP | TAPRelay | read() from /dev/net/tun | ~20μs |
| 11 | TAPRelay | Host | vsock write (VM→Host) | ~500μs |
| 12 | Host | NetworkBridge | vsock read + poll (non-blocking) | **~1000μs** |
| 13 | NetworkBridge | Container B | vsock write (Host→VM) | ~500μs |
| 14 | Container B | arca-tap-forwarder | vsock read | ~20μs |
| 15 | Forwarder | TAP device | write() to /dev/net/tun | ~20μs |
| 16 | TAP | Kernel | Kernel IP stack processing | ~50μs |
| 17 | Kernel | App | deliver to socket | ~10μs |

**Total one-way latency**: ~4.3ms
**Round-trip (ping)**: ~8-9ms (observed: 4-7ms with optimizations)

### Performance Bottlenecks

#### 1. Non-blocking I/O Polling (Major)

**Location**: NetworkBridge relay tasks (steps 4 and 12)

**Issue**:
```swift
// NetworkBridge.swift:550-580
while !Task.isCancelled {
    let bytesRead = Darwin.read(fd, &buffer, buffer.count)

    if bytesRead < 0 {
        if errno == EAGAIN || errno == EWOULDBLOCK {
            // No data available - sleep to avoid busy-wait
            try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
            continue
        }
    }
}
```

**Impact**: Each relay direction has a **~1ms average delay** due to polling sleep. With 4 relay hops (Container→Host→Helper→Host→Container), this adds **~4ms to latency**.

**Why we use polling**:
- Swift's async/await doesn't support true async I/O on file descriptors
- vsock file descriptors don't work with kqueue/epoll in Swift NIO
- Blocking reads would block Swift's cooperative thread pool
- Non-blocking + polling is the only viable approach in Swift

**Potential optimizations**:
1. **Reduce sleep time**: 1ms → 100μs (but increases CPU usage)
2. **Adaptive polling**: Use shorter sleep when traffic is active
3. **Rewrite in C/Rust**: Use epoll/kqueue for true async I/O (major effort)
4. **Batch frames**: Send multiple frames per vsock transaction

#### 2. vsock Hypervisor Overhead (Moderate)

**Location**: All vsock hops (steps 3, 5, 11, 13)

**Issue**: vsock requires hypervisor mediation for VM↔Host communication. Each vsock operation involves:
1. Guest VM syscall
2. VM exit (trap to hypervisor)
3. Hypervisor vsock handling
4. Host process wakeup
5. Context switch to host process

**Impact**: ~500μs per vsock hop (4 hops = ~2ms total)

**Comparison to native networking**:
- Linux veth pairs: ~10μs
- Docker bridge: ~50μs
- vsock: ~500μs (10-50x slower)

**Why we use vsock**:
- Only communication mechanism between VMs and host in Apple's Virtualization framework
- Secure by design (no network stack exposure)
- Simpler than implementing virtual NICs

**Not optimizable**: vsock overhead is inherent to Apple's hypervisor implementation.

#### 3. Frame Serialization (Minor)

**Location**: All packet forwarding hops

**Issue**: Each frame is prefixed with a 4-byte length header:
```go
// arca-tap-forwarder: forwarder.go:85-95
binary.BigEndian.PutUint32(lengthBuf, uint32(frameLen))
_, err := conn.Write(lengthBuf)
_, err = conn.Write(frame)
```

**Impact**: ~50μs per hop for length encoding/decoding (8 hops = ~400μs total)

**Why we use it**:
- vsock is a stream protocol (like TCP), not message-oriented
- Length prefix ensures we read complete frames
- Alternative (fixed-size frames) wastes bandwidth

**Potential optimizations**:
1. **Batch multiple frames**: Single length header for multiple frames
2. **Compression**: Reduce frame size for repeated data
3. **Zero-copy**: Use shared memory (not possible with vsock)

#### 4. OVS Forwarding (Minor)

**Location**: Helper VM OVS bridge (step 8)

**Issue**: OVS must:
1. Learn MAC addresses
2. Look up forwarding table
3. Apply flow rules
4. Update statistics

**Impact**: ~100μs per packet (negligible for MVP)

**Potential optimizations**:
1. **Flow caching**: OVS already does this
2. **Hardware offload**: Not applicable to software bridge
3. **Simpler bridge**: Replace OVS with Linux bridge (loses features)

### Performance Measurements

**Observed RTT (ping)**:
```bash
$ docker exec container-a ping -c 10 172.18.0.3
10 packets transmitted, 10 received, 0% packet loss
rtt min/avg/max/mdev = 4.213/6.847/8.932/1.127 ms
```

**Breakdown**:
- Minimum: 4.2ms (optimal path, no contention)
- Average: 6.8ms (typical with system load)
- Maximum: 8.9ms (worst case with scheduling delays)

**Comparison to Docker Desktop**:
- Docker Desktop (Mac): 0.3-0.5ms (using native bridge)
- Arca (TAP-over-vsock): 4-9ms (10-20x slower)

**Acceptable for most use cases**:
- Web services: RTT < 10ms is imperceptible
- Databases: Application-level caching dominates
- File sharing: Throughput matters more than latency

**Not suitable for**:
- High-frequency trading (requires <1ms latency)
- Real-time gaming (requires <50ms total latency)
- Latency-sensitive microservices (but why run those in local containers?)

## Security Analysis

### Threat Model

**Assumptions**:
1. Container VMs are untrusted (user-provided images)
2. Host (macOS) is trusted
3. Helper VM is trusted (Arca-controlled)
4. Hypervisor (Apple Virtualization.framework) is trusted

**Attack Vectors**:
1. Malicious container attempts to access other containers' networks
2. Malicious container attempts to escape to host
3. Malicious container attempts to DoS the network
4. Malicious container attempts to sniff other containers' traffic

### Security Boundaries

#### 1. vsock Isolation (Strong)

**Mechanism**: vsock uses Context IDs (CIDs) for addressing:
- Host: CID=2 (fixed by Apple)
- Helper VM: CID=3 (assigned by Containerization framework)
- Container VMs: CID=4,5,6,... (assigned by Containerization framework)

**Enforcement**: The hypervisor prevents VMs from:
1. Spoofing CIDs (CID is assigned by hypervisor, not guest)
2. Connecting to CIDs they don't have permission to access
3. Listening on ports in other VMs' address spaces

**Example attack prevention**:
```go
// Inside Container A (CID=4)
// Try to connect to Container B (CID=5) directly
conn, err := vsock.Dial(5, 20001)  // BLOCKED by hypervisor
// Error: "No route to host" - hypervisor prevents VM-to-VM vsock
```

**Result**: Containers cannot communicate directly via vsock. All communication must go through the host relay.

#### 2. Network Isolation (Strong)

**Mechanism**: OVS bridges are isolated by network ID
- Network "my-net-1": Bridge br-xxxxxxxxxxxx (port 172.18.0.0/16)
- Network "my-net-2": Bridge br-yyyyyyyyyyyy (port 172.19.0.0/16)

**Enforcement**: OVS only forwards frames within the same bridge. Containers on different networks cannot communicate even if they're on the same helper VM.

**Example attack prevention**:
```bash
# Container A on network "my-net-1" (172.18.0.2)
$ ping 172.19.0.2  # Container B on network "my-net-2"
# No route to host - OVS bridge isolation prevents cross-network traffic
```

**Result**: Network isolation is as strong as OVS bridge isolation (Docker-compatible).

#### 3. MAC Spoofing (Weak)

**Vulnerability**: Containers control their own TAP devices and can set arbitrary MAC addresses.

**Attack scenario**:
```bash
# Container A (172.18.0.2, MAC 02:aa:aa:aa:aa:aa)
$ ip link set eth0 address 02:bb:bb:bb:bb:bb  # Spoof Container B's MAC
# Now Container A receives Container B's traffic
```

**Impact**: Container A can hijack Container B's traffic on the same network.

**Mitigation**: OVS can be configured with MAC anti-spoofing rules:
```bash
# In helper VM control-api
ovs-vsctl set port port-containerA mac="02:aa:aa:aa:aa:aa"
```

**Status**: Not currently implemented. **TODO**: Add MAC validation to OVS ports.

#### 4. IP Spoofing (Weak)

**Vulnerability**: Containers control their own network configuration and can set arbitrary IP addresses.

**Attack scenario**:
```bash
# Container A assigned 172.18.0.2
$ ip addr add 172.18.0.3/16 dev eth0  # Spoof Container B's IP
# Now Container A can send packets claiming to be from 172.18.0.3
```

**Impact**: Container A can spoof packets from Container B, potentially bypassing firewall rules.

**Mitigation**: OVS can be configured with IP anti-spoofing rules (OpenFlow flows):
```bash
# In helper VM control-api
ovs-ofctl add-flow br-xxx "in_port=1,dl_src=02:aa:aa:aa:aa:aa,nw_src=172.18.0.2,actions=normal"
ovs-ofctl add-flow br-xxx "in_port=1,priority=0,actions=drop"  # Drop everything else
```

**Status**: Not currently implemented. **TODO**: Add IP/MAC validation flows to OVS.

#### 5. DoS via Packet Flooding (Moderate)

**Vulnerability**: A malicious container can flood the network with packets, consuming CPU/bandwidth.

**Attack scenario**:
```bash
# Container A floods network with packets
$ hping3 --flood --rand-source 172.18.0.255
# Consumes CPU in arca-tap-forwarder, NetworkBridge, TAPRelay, and OVS
```

**Impact**:
- NetworkBridge relay tasks consume host CPU (non-blocking polling)
- Helper VM CPU consumed by TAPRelay and OVS
- Other containers on same network experience degraded performance

**Mitigation**:
1. **Rate limiting**: Add token bucket rate limiting in arca-tap-forwarder
2. **QoS**: Use OVS QoS policies to limit per-container bandwidth
3. **Resource limits**: Use cgroup limits on container CPU/memory (already enforced by Containerization framework)

**Status**: Not currently implemented. **TODO**: Add rate limiting and QoS.

#### 6. Frame Injection (Strong Protection)

**Vulnerability**: Can a container inject arbitrary frames into other containers' TAP devices?

**Attack scenario**:
```
Container A tries to:
1. Connect to vsock port 20001 (Container B's TAP forwarding port)
2. Send malicious frames
```

**Protection**: Hypervisor vsock isolation prevents this:
- Container A (CID=4) cannot connect to host port 20000 (intended for Container B)
- Each container's arca-tap-forwarder listens on a unique vsock port
- Only the host (CID=2) can connect to these ports

**Result**: Strong protection via hypervisor enforcement.

### Security Recommendations

#### Immediate (High Priority)

1. **MAC anti-spoofing**: Configure OVS ports with fixed MAC addresses
2. **IP anti-spoofing**: Add OpenFlow rules to validate source IP/MAC
3. **Rate limiting**: Implement token bucket in arca-tap-forwarder

#### Medium Priority

4. **QoS policies**: Configure OVS QoS to limit per-container bandwidth
5. **Flow table limits**: Prevent containers from exhausting OVS flow table
6. **Audit logging**: Log all network operations for forensics

#### Low Priority (Future)

7. **Network policies**: Implement Kubernetes-style NetworkPolicies via OVS
8. **Encryption**: Add optional TLS/DTLS for inter-container traffic
9. **Anomaly detection**: Monitor for unusual traffic patterns

## Comparison to Alternative Architectures

### Alternative 1: Native vmnet (Apple's Virtual Network)

**How it would work**:
```
Container VM ─── VZVirtioNetworkDeviceAttachment ─── vmnet_interface
                                                            │
                                                            └─ Shared L2 network
```

**Pros**:
- Much faster (~0.5ms latency vs 5ms)
- Native Apple implementation (less code to maintain)
- No helper VM needed

**Cons**:
- **Cannot dynamically attach/detach networks** (VZVirtualMachineConfiguration is immutable)
- Requires container restart for network changes
- All containers share single vmnet (no true network isolation)
- No bridge network emulation (Docker compatibility breaks)

**Verdict**: Not suitable for Docker compatibility. See `Documentation/NATIVE_VS_CURRENT_NETWORKING.md` for full analysis.

### Alternative 2: VXLAN Tunneling

**How it would work**:
```
Container VM ─── TAP device ─── VXLAN tunnel ─── Host bridge ─── Helper VM
```

**Pros**:
- Standard protocol (interoperable with other systems)
- Could support multi-host networking in the future

**Cons**:
- VXLAN adds 50 bytes per packet (overhead)
- Requires VXLAN encap/decap on every hop (slower)
- More complex than raw frames
- No significant advantage over current design

**Verdict**: Unnecessary complexity for single-host use case.

### Alternative 3: Shared Memory

**How it would work**:
```
Container VM ─── Shared memory region ─── Host ─── Helper VM
```

**Pros**:
- Extremely fast (zero-copy possible)
- No vsock overhead

**Cons**:
- **Not supported by Apple Virtualization framework**
- Would require custom kernel modules
- Security concerns (shared memory between VMs)

**Verdict**: Not feasible with Apple's APIs.

## Current Design Trade-offs

### Why TAP-over-vsock?

✅ **Pros**:
1. **Dynamic network attachment** - No container restart needed
2. **Full Docker compatibility** - Works with all Docker networking commands
3. **Network isolation** - OVS bridges provide true network isolation
4. **No kernel modifications** - Pure userspace implementation
5. **Secure by design** - Hypervisor-enforced VM isolation

❌ **Cons**:
1. **Higher latency** - 4-7ms vs 0.5ms for native networking
2. **CPU overhead** - Non-blocking polling consumes CPU
3. **Complex architecture** - Many moving parts (forwarder, relay, helper VM)
4. **Not suitable for HPC** - Latency too high for high-performance workloads

### Is the latency acceptable?

**Yes, for most use cases**:
- **Web development**: HTTP requests take 10-100ms, network latency is negligible
- **Database development**: Query time (1-10ms) dominates network latency
- **Microservices**: Application logic (10-100ms) dominates
- **CI/CD**: Build time (seconds to minutes) dominates

**No, for specific cases**:
- **High-frequency trading**: Requires <1ms latency
- **Real-time gaming servers**: Requires <50ms total latency
- **Latency-sensitive distributed systems**: (but why develop these locally?)

**Recommendation**: For production deployments requiring low latency, use native Docker on Linux or cloud-based containers.

## Future Optimizations

### 1. Adaptive Polling (Low-hanging fruit)

**Change**:
```swift
// Current: Fixed 1ms sleep
try? await Task.sleep(nanoseconds: 1_000_000)

// Proposed: Adaptive sleep based on traffic
let sleepTime = trafficActive ? 100_000 : 1_000_000  // 100μs vs 1ms
try? await Task.sleep(nanoseconds: sleepTime)
```

**Impact**: Reduces latency to ~2-3ms under load, increases CPU usage by ~2-3%

### 2. Frame Batching (Medium effort)

**Change**: Accumulate multiple frames before sending:
```
Current:  [len1][frame1] [len2][frame2] [len3][frame3]
Proposed: [count][len1][frame1][len2][frame2][len3][frame3]
```

**Impact**: Reduces vsock syscalls by 5-10x, latency improvement ~1-2ms

### 3. eBPF Acceleration (High effort)

**Change**: Use eBPF XDP programs in helper VM to bypass kernel networking:
```
Container → vsock → Host → vsock → eBPF → OVS (via AF_XDP)
```

**Impact**: Reduces helper VM overhead by ~50%, latency improvement ~500μs

### 4. Rewrite Relay in Rust (High effort)

**Change**: Replace NetworkBridge relay tasks with Rust using tokio + epoll:
```rust
let mut events = mio::Events::with_capacity(1024);
loop {
    poll.poll(&mut events, None)?;
    for event in &events {
        // True async I/O, no polling sleep
    }
}
```

**Impact**: Eliminates polling overhead (~2ms improvement), but requires rewriting Swift bridge code

## arca-tap-forwarder vs TAPRelay: Are They The Same?

### TL;DR: Similar Purpose, Different Directions

**Short answer**: Yes, they're essentially mirror images of each other - both forward packets between TAP devices and vsock connections. The key difference is **what they're attached to**:

- **arca-tap-forwarder** (container): TAP device → vsock connection **to host**
- **TAPRelay** (helper VM): vsock connection **from host** → TAP device → OVS bridge

### Detailed Comparison

| Aspect | arca-tap-forwarder (Container) | TAPRelay (Helper VM) |
|--------|--------------------------------|----------------------|
| **Location** | Inside container VM (CID=4,5,6...) | Inside helper VM (CID=3) |
| **Language** | Go | Go |
| **Package** | `arca-tap-forwarder-go/` | `helpervm/control-api/tap_relay.go` |
| **TAP Device Type** | Regular TAP (`/dev/net/tun`) with IP config | OVS internal port (no IP, pure L2) |
| **TAP Device Purpose** | Container's network interface (eth0, eth1) | Bridge port for packet relay |
| **TAP Device IP** | Has IP (e.g., 172.18.0.2) | No IP (L2 only) |
| **TAP Device Gateway** | Configured (e.g., 172.18.0.1) | N/A |
| **vsock Role** | **Listener** - waits for host to connect | **Dialer** - not used (host connects to it) |
| **vsock Port** | Listens on 20000, 20001, etc. (one per network) | Listens on 30000, 30001, etc. (one per container) |
| **vsock Direction** | Container ← Host (host initiates) | Helper VM ← Host (host initiates) |
| **Control API** | gRPC server (port 5555) for AttachNetwork | Part of main NetworkControl gRPC service |
| **Startup** | Launched by container.exec() from host | Started by AttachContainer RPC |
| **Management** | Managed by NetworkBridge via TAPForwarderClient | Managed by TAPRelayManager |
| **Lifecycle** | Runs as daemon, one instance per container | One relay goroutine per container attachment |
| **OVS Integration** | None - just a TAP device | Creates OVS port, attaches to bridge |
| **Multiple Networks** | Manages multiple TAP devices (eth0, eth1, eth2) | One relay per container, one port per container |

### Architectural Symmetry

```
┌───────────────────────────────────────────────────────────────────┐
│                    CONTAINER VM (e.g., CID=4)                     │
│                                                                   │
│  Application → Kernel → TAP (eth0)                                │
│                           ↕                                       │
│                   arca-tap-forwarder                              │
│                    - Creates TAP device                           │
│                    - Configures IP: 172.18.0.2                   │
│                    - Listens on vsock:20000                       │
│                    - Forwards: TAP ↔ vsock                        │
│                           ↕                                       │
└───────────────────────────┼───────────────────────────────────────┘
                            │ vsock connection
                   ┌────────┴────────┐
                   │  HOST (CID=2)   │
                   │  NetworkBridge  │
                   │  Relay Task     │
                   └────────┬────────┘
                            │ vsock connection
┌───────────────────────────┼───────────────────────────────────────┐
│                    HELPER VM (CID=3)                              │
│                           ↕                                       │
│                      TAPRelay                                     │
│                    - Listens on vsock:30000                       │
│                    - Creates OVS internal port                    │
│                    - No IP address (L2 only)                      │
│                    - Forwards: vsock ↔ TAP                        │
│                           ↕                                       │
│                   TAP (port-containerA)                           │
│                           ↕                                       │
│                    OVS Bridge (br-xxx)                            │
│                      172.18.0.0/16                                │
│                                                                   │
└───────────────────────────────────────────────────────────────────┘
```

### Code Structure Comparison

#### arca-tap-forwarder Structure

```go
// arca-tap-forwarder-go/cmd/arca-tap-forwarder/main.go
type server struct {
    forwarder *forwarder.Forwarder
}

// arca-tap-forwarder-go/internal/forwarder/forwarder.go
type Forwarder struct {
    attachments map[string]*NetworkAttachment  // device -> attachment
}

type NetworkAttachment struct {
    Device    string      // eth0, eth1, etc.
    VsockPort uint32      // 20000, 20001, etc.
    IPAddress string      // 172.18.0.2
    Gateway   string      // 172.18.0.1
    MAC       string      // 02:xx:xx:xx:xx:xx

    tap       *tap.TAP          // TAP device with IP config
    vsockConn net.Conn          // Connection from host
    cancel    context.CancelFunc
}

// Key methods:
func (f *Forwarder) AttachNetwork(device, vsockPort, ipAddress, gateway, netmask)
func (a *NetworkAttachment) forwardTAPtoVsock()
func (a *NetworkAttachment) forwardVsockToTAP()
```

#### TAPRelay Structure

```go
// helpervm/control-api/tap_relay.go
type TAPRelayManager struct {
    listeners map[uint32]*vsock.Listener  // port -> listener
    relays    map[uint32]chan struct{}    // port -> stop channel
}

// Key methods:
func (m *TAPRelayManager) StartRelay(port, bridgeName, networkID, containerID, macAddress)
func (m *TAPRelayManager) handleConnection(conn, bridgeName, networkID, containerID, macAddress, port)

// Inside handleConnection:
// - Creates OVS internal port (port-containerID)
// - Opens TAP device (OVS port as raw socket)
// - Starts two goroutines:
//   - vsock -> TAP (packets from host to bridge)
//   - TAP -> vsock (packets from bridge to host)
```

### Key Differences Explained

#### 1. TAP Device Type

**arca-tap-forwarder**:
```go
// Creates a regular TAP device using /dev/net/tun
tapDev, err := tap.Create(device)  // eth0, eth1, etc.
tapDev.SetIP(ipAddress, netmask)   // 172.18.0.2/16
tapDev.BringUp()

// Result: Fully configured network interface
// $ ip addr show eth0
// eth0: <BROADCAST,MULTICAST,UP> mtu 1500
//     inet 172.18.0.2/16 brd 172.18.255.255 scope global eth0
```

**TAPRelay**:
```go
// Creates OVS internal port (appears as network interface)
exec.Command("ovs-vsctl", "add-port", bridgeName, portName,
    "--", "set", "interface", portName, "type=internal")

// Opens as raw packet socket (no IP address)
iface, _ := net.InterfaceByName(portName)
fd, _ := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW,
    int(htons(syscall.ETH_P_ALL)))
syscall.Bind(fd, &syscall.SockaddrLinklayer{
    Protocol: htons(syscall.ETH_P_ALL),
    Ifindex:  iface.Index,
})

// Result: L2-only interface attached to OVS
// $ ip addr show port-abc123
// port-abc123: <BROADCAST,MULTICAST,UP> mtu 1500
//     link/ether 02:xx:xx:xx:xx:xx brd ff:ff:ff:ff:ff:ff
// (no IP address - pure L2 forwarding)
```

#### 2. vsock Connection Initiation

**arca-tap-forwarder**:
```go
// LISTENER: Waits for host to connect
listener, err := vsock.Listen(vsockPort, nil)
conn, err := listener.Accept()  // Blocks until host connects

// Host (NetworkBridge) initiates connection
```

**TAPRelay**:
```go
// LISTENER: Waits for host to connect
listener, err := vsock.Listen(port, nil)
conn, err := listener.Accept()  // Blocks until host connects

// Host (NetworkBridge) initiates connection
```

**Wait, they're the same!** Both are listeners. The asymmetry is:
- Container's forwarder listens on **port 20000+** (container CID)
- Helper VM's relay listens on **port 30000+** (helper VM CID)
- Host's NetworkBridge **connects to both** as a relay

#### 3. Packet Direction Handling

**arca-tap-forwarder**:
```go
// TAP -> vsock (container sending)
func (a *NetworkAttachment) forwardTAPtoVsock() {
    for {
        n, _ := a.tap.Read(buf)           // Read from TAP (eth0)
        a.vsockConn.Write(buf[:n])        // Write to host
    }
}

// vsock -> TAP (container receiving)
func (a *NetworkAttachment) forwardVsockToTAP() {
    for {
        n, _ := a.vsockConn.Read(buf)     // Read from host
        a.tap.Write(buf[:n])              // Write to TAP (eth0)
    }
}
```

**TAPRelay**:
```go
// vsock -> TAP (host to bridge)
go func() {
    for {
        n, _ := conn.Read(buffer)         // Read from host
        tapFile.Write(buffer[:n])         // Write to OVS port
    }
}()

// TAP -> vsock (bridge to host)
go func() {
    for {
        n, _ := tapFile.Read(buffer)      // Read from OVS port
        conn.Write(buffer[:n])            // Write to host
    }
}()
```

**They're mirror images!** Both forward bidirectionally, just with different endpoints:
- Container forwarder: TAP (with IP) ↔ vsock (to host)
- Helper VM relay: vsock (from host) ↔ TAP (OVS port, no IP)

#### 4. Management API

**arca-tap-forwarder**:
```go
// gRPC service on vsock:5555 (goes through vminit proxy at :9999)
service TAPForwarder {
    rpc AttachNetwork(AttachNetworkRequest) returns (AttachNetworkResponse);
    rpc DetachNetwork(DetachNetworkRequest) returns (DetachNetworkResponse);
    rpc ListNetworks(ListNetworksRequest) returns (ListNetworksResponse);
    rpc GetStatus(GetStatusRequest) returns (GetStatusResponse);
}

// Host calls via TAPForwarderClient:
client.AttachNetwork(device="eth0", vsockPort=20000, ip="172.18.0.2")
```

**TAPRelay**:
```go
// Part of main NetworkControl service on vsock:9999
service NetworkControl {
    rpc CreateBridge(...);
    rpc DeleteBridge(...);
    rpc AttachContainer(...);  // This starts a TAPRelay!
    rpc DetachContainer(...);  // This stops a TAPRelay!
}

// Host calls via OVNClient:
client.AttachContainer(networkID, containerID, vsockPort=30000, ...)
// Internally calls: tapRelayManager.StartRelay(30000, bridgeName, ...)
```

### Why Two Separate Components?

**Why not just one "packet forwarder" component?**

1. **Different TAP device types**:
   - Container needs L3 TAP with IP addressing (acts as network interface)
   - Helper VM needs L2 TAP without IP (acts as bridge port)

2. **Different OVS integration**:
   - Container has no OVS, just forwards to host
   - Helper VM integrates with OVS bridge

3. **Different lifecycles**:
   - Container forwarder runs as a daemon, manages multiple networks
   - Helper VM relay is per-container-attachment, ephemeral

4. **Different deployment**:
   - Container forwarder is a 14MB static binary bind-mounted
   - Helper VM relay is compiled into control-api server

5. **Separation of concerns**:
   - Container side: Network interface emulation
   - Helper VM side: Bridge port emulation

### Could They Be Unified?

**Theoretically yes**, but it would require:

```go
// Hypothetical unified forwarder
type PacketForwarder struct {
    mode string  // "container" or "helper"
}

func (f *PacketForwarder) Forward() {
    if f.mode == "container" {
        // Create TAP with IP, configure routes, etc.
    } else {
        // Create OVS port, attach to bridge, etc.
    }

    // Common forwarding logic
    forwardBidirectional(tapDevice, vsockConn)
}
```

**But this is worse because**:
1. Adds complexity for little benefit
2. Container and helper VM have different dependencies
3. Different error handling requirements
4. Different management APIs
5. Harder to optimize each side independently

### The Real Role: NetworkBridge is the Key

**The critical insight**: Both forwarders are **stateless packet pumps**. The **real intelligence** is in NetworkBridge (host):

```
Container Forwarder     NetworkBridge (Host)      Helper VM Relay
     (passive)            (active relay)            (passive)
        ↓                       ↓                       ↓
   Listens on              Connects to both        Listens on
   vsock:20000             vsock:20000 AND         vsock:30000
        ↓                   vsock:30000                 ↓
   Forwards TAP                  ↓                 Forwards to
   frames blindly          Relays packets          OVS blindly
        ↓                   between them                ↓
   No routing                    ↓                  No routing
   No filtering           All logic here          No filtering
   No state               State management        No state
```

**NetworkBridge is the brains**:
- Allocates vsock ports
- Establishes connections to both sides
- Relays packets with non-blocking I/O
- Tracks connection state
- Handles errors and cleanup

**Forwarders are just I/O pipes**:
- Read from TAP, write to vsock
- Read from vsock, write to TAP
- That's it!

## Conclusion

Arca's TAP-over-vsock architecture is a **pragmatic trade-off** between Docker compatibility, dynamic networking, and implementation complexity. The 4-7ms latency is acceptable for the vast majority of development use cases, and the architecture provides strong security isolation through hypervisor-enforced vsock boundaries.

**Key takeaways**:
1. **vsock data plane bypasses vminit** - Direct connections for performance
2. **Control plane uses vminit proxy** - gRPC configuration via port 9999
3. **Latency dominated by non-blocking I/O polling** - ~2ms overhead from 1ms sleep × 2 relay directions
4. **Security relies on hypervisor isolation** - Strong VM-to-VM protection, weak MAC/IP spoofing protection
5. **Performance acceptable for development** - Not suitable for HPC or latency-critical production
6. **arca-tap-forwarder and TAPRelay are mirror images** - Different TAP types, same forwarding logic
7. **NetworkBridge is the orchestrator** - Both forwarders are passive I/O pipes

**Next steps**:
1. Implement MAC/IP anti-spoofing in OVS
2. Add rate limiting to prevent DoS
3. Consider adaptive polling for latency optimization
4. Benchmark with iperf3 for formal performance documentation
