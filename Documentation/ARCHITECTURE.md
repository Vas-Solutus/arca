# Arca Architecture

This document describes the internal architecture of Arca, a Docker Engine API implementation backed by Apple's Containerization framework.

## System Overview

```mermaid
graph TB
    subgraph "Docker Ecosystem"
        CLI[Docker CLI]
        Compose[Docker Compose]
        Buildx[Docker Buildx]
    end

    subgraph "Arca Daemon"
        Socket[Unix Socket<br/>/var/run/arca.sock]
        Server[SwiftNIO Server<br/>ArcaDaemon]
        Router[Router +<br/>Middleware]

        subgraph "Handlers"
            ContainerH[Container<br/>Handlers]
            ImageH[Image<br/>Handlers]
            NetworkH[Network<br/>Handlers]
            VolumeH[Volume<br/>Handlers]
            ExecH[Exec<br/>Handlers]
        end

        subgraph "ContainerBridge"
            CM[Container<br/>Manager]
            IM[Image<br/>Manager]
            NM[Network<br/>Manager]
            VM[Volume<br/>Manager]
            EM[Exec<br/>Manager]
            SS[StateStore<br/>SQLite]
        end
    end

    subgraph "Apple Framework"
        ACF[Apple Containerization<br/>Framework]
        VMs[Linux VMs<br/>Containers]
    end

    CLI --> Socket
    Compose --> Socket
    Buildx --> Socket
    Socket --> Server
    Server --> Router
    Router --> ContainerH
    Router --> ImageH
    Router --> NetworkH
    Router --> VolumeH
    Router --> ExecH

    ContainerH --> CM
    ImageH --> IM
    NetworkH --> NM
    VolumeH --> VM
    ExecH --> EM

    CM --> ACF
    IM --> ACF
    NM --> ACF
    VM --> ACF
    EM --> ACF
    CM --> SS
    VM --> SS

    ACF --> VMs

    style Socket fill:#e1f5ff
    style Server fill:#fff4e1
    style ACF fill:#ffe1e1
    style VMs fill:#ffe1e1
    style SS fill:#e1ffe1
```

## Module Structure

```mermaid
graph LR
    subgraph "Arca (Executable)"
        Main[main.swift<br/>CLI Entry Point]
    end

    subgraph "ArcaDaemon"
        Server[Server.swift<br/>SwiftNIO]
        Router[Router.swift<br/>Request Routing]
        HTTP[HTTPHandler.swift<br/>HTTP Processing]
        MW1[RequestLogger<br/>Middleware]
        MW2[APIVersionNormalizer<br/>Middleware]
    end

    subgraph "DockerAPI"
        Models[Models/<br/>Container, Image, etc.]
        Handlers[Handlers/<br/>ContainerHandlers, etc.]
    end

    subgraph "ContainerBridge"
        Managers[Managers/<br/>Container, Image, Network, etc.]
        Backends[Network Backends/<br/>WireGuard, Vmnet]
        OverlayFS[OverlayFS/<br/>Client, Mounter, Unpacker]
        Generated[Generated/<br/>gRPC Clients]
    end

    Main --> Server
    Server --> Router
    Router --> MW1
    Router --> MW2
    Router --> Handlers
    Handlers --> Managers
    Managers --> Backends
    Managers --> OverlayFS
    Managers --> Generated

    style Main fill:#e1f5ff
    style Server fill:#fff4e1
    style Handlers fill:#ffe1ff
    style Managers fill:#e1ffe1
```

## Request Flow

```mermaid
sequenceDiagram
    participant CLI as Docker CLI
    participant Socket as Unix Socket
    participant Server as SwiftNIO Server
    participant Router as Router
    participant Middleware as Middleware Pipeline
    participant Handler as ContainerHandlers
    participant Manager as ContainerManager
    participant Apple as Apple Containerization
    participant VM as Linux VM

    CLI->>Socket: POST /v1.51/containers/create
    Socket->>Server: HTTP Request
    Server->>Router: Parse & Route
    Router->>Middleware: /v1.51/containers/create
    Middleware->>Middleware: Strip version prefix
    Middleware->>Handler: /containers/create
    Handler->>Manager: createContainer()
    Manager->>Apple: Create VM
    Apple->>VM: Start Linux VM
    VM-->>Apple: VM Running
    Apple-->>Manager: Container UUID
    Manager->>Manager: Generate Docker ID<br/>Store ID mapping
    Manager-->>Handler: Container created
    Handler-->>Middleware: JSON Response
    Middleware->>Middleware: Log response
    Middleware-->>Router: Response
    Router-->>Server: Response
    Server-->>Socket: HTTP 201 Created
    Socket-->>CLI: {"Id": "abc123..."}
```

## Networking Architecture

```mermaid
graph TB
    subgraph "Arca Daemon"
        NM[NetworkManager<br/>Facade]
        WGB[WireGuardNetworkBackend<br/>Default Driver]
        VNB[VmnetNetworkBackend<br/>Optional Driver]
        WGC[WireGuardClient<br/>gRPC Client]
        IPAM[IPAMAllocator<br/>IP Management]
    end

    subgraph "Container A VM"
        WGA[arca-wireguard-service<br/>vsock:51820]
        WG1[WireGuard Interface<br/>wg0: 172.20.0.2]
        Eth1A[eth0 mapped to wg0]
    end

    subgraph "Container B VM"
        WGB2[arca-wireguard-service<br/>vsock:51820]
        WG2[WireGuard Interface<br/>wg0: 172.20.0.3]
        Eth1B[eth0 mapped to wg0]
    end

    subgraph "Container C VM"
        WGC2[arca-wireguard-service<br/>vsock:51820]
        WG3[WireGuard Interface<br/>wg0: 172.20.0.4]
        Eth1C[eth0 mapped to wg0]
    end

    NM --> WGB
    NM --> VNB
    WGB --> WGC
    WGB --> IPAM

    WGC -->|gRPC/vsock| WGA
    WGC -->|gRPC/vsock| WGB2
    WGC -->|gRPC/vsock| WGC2

    WGA --> WG1
    WGB2 --> WG2
    WGC2 --> WG3

    WG1 --> Eth1A
    WG2 --> Eth1B
    WG3 --> Eth1C

    WG1 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG2
    WG1 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG3
    WG2 -.->|Peer-to-Peer<br/>Encrypted Tunnel| WG3

    style NM fill:#e1f5ff
    style WGB fill:#e1ffe1
    style WGC fill:#fff4e1
    style WGA fill:#ffe1e1
    style WGB2 fill:#ffe1e1
    style WGC2 fill:#ffe1e1
```

### WireGuard Full Mesh Topology

Each container on a network has WireGuard peers to all other containers on that network:

```mermaid
graph LR
    A[Container A<br/>172.20.0.2]
    B[Container B<br/>172.20.0.3]
    C[Container C<br/>172.20.0.4]
    D[Container D<br/>172.20.0.5]

    A <-->|WireGuard Peer| B
    A <-->|WireGuard Peer| C
    A <-->|WireGuard Peer| D
    B <-->|WireGuard Peer| C
    B <-->|WireGuard Peer| D
    C <-->|WireGuard Peer| D

    style A fill:#e1f5ff
    style B fill:#ffe1ff
    style C fill:#e1ffe1
    style D fill:#fff4e1
```

## Volume Architecture

```mermaid
graph TB
    subgraph "Arca Daemon"
        VM[VolumeManager]
        SS[StateStore<br/>SQLite]
    end

    subgraph "Volume Storage ~/.arca/volumes/"
        LocalVol[mydata/<br/>├── data/<br/>│   └── files]
        BlockVol[mydb/<br/>├── volume.img<br/>   EXT4 filesystem]
    end

    subgraph "Container VM"
        subgraph "VirtioFS Shares"
            BindMount[/host-data<br/>macOS directory]
            LocalMount[/app-data<br/>~/.arca/volumes/mydata/data]
        end

        subgraph "Block Device"
            BlockMount[/var/lib/db<br/>EXT4 block device]
        end
    end

    VM -->|Manages| LocalVol
    VM -->|Manages| BlockVol
    VM -->|Metadata| SS

    LocalVol -.->|VirtioFS| LocalMount
    BlockVol -.->|EXT4 Mount| BlockMount

    style VM fill:#e1f5ff
    style SS fill:#e1ffe1
    style LocalVol fill:#fff4e1
    style BlockVol fill:#ffe1ff
    style BindMount fill:#e1ffe1
    style LocalMount fill:#fff4e1
    style BlockMount fill:#ffe1ff
```

### Volume Driver Comparison

| Feature | Local Driver (Default) | Block Driver (Optional) |
|---------|----------------------|------------------------|
| **Storage** | VirtioFS directory | EXT4 block device |
| **Location** | `~/.arca/volumes/{name}/data/` | `~/.arca/volumes/{name}/volume.img` |
| **Sharing** | ✅ Multiple containers | ❌ Exclusive access |
| **Use Case** | General purpose | Databases, high I/O |
| **Performance** | Good | Better for heavy I/O |
| **Creation** | `docker volume create mydata` | `docker volume create --driver block mydata` |

## Container Persistence

```mermaid
stateDiagram-v2
    [*] --> Created: docker create
    Created --> Running: docker start
    Running --> Paused: docker pause
    Paused --> Running: docker unpause
    Running --> Stopped: docker stop
    Running --> Exited: Process exits
    Stopped --> Running: docker start
    Exited --> Running: docker start<br/>(if restart policy)
    Stopped --> Removed: docker rm
    Exited --> Removed: docker rm
    Created --> Removed: docker rm
    Removed --> [*]

    note right of Created
        State persisted to SQLite:
        - Container config
        - Network attachments
        - Volume mounts
        - Restart policy
    end note

    note right of Running
        Monitoring goroutine:
        - Waits for exit
        - Records exit code
        - Updates database
        - Handles restart policy
    end note

    note right of Exited
        Daemon restart:
        - VM destroyed (ephemeral)
        - State in SQLite survives
        - docker start recreates VM
    end note
```

### Restart Policy Behavior

```mermaid
graph TD
    Exit[Container Exits]

    Exit --> CheckPolicy{Restart<br/>Policy?}

    CheckPolicy -->|no| StayExited[Stays Exited]
    CheckPolicy -->|always| Restart1[Always Restart]
    CheckPolicy -->|unless-stopped| CheckStopped{Explicitly<br/>stopped?}
    CheckPolicy -->|on-failure| CheckCode{Exit<br/>code?}

    CheckStopped -->|Yes| StayExited
    CheckStopped -->|No| Restart2[Restart]

    CheckCode -->|0| StayExited
    CheckCode -->|non-zero| Restart3[Restart]

    Restart1 --> Running[Back to Running]
    Restart2 --> Running
    Restart3 --> Running

    style Exit fill:#ffe1e1
    style Running fill:#e1ffe1
    style StayExited fill:#e1f5ff
```

## Image Management

```mermaid
graph TB
    subgraph "Image Pull Flow"
        CLI[docker pull nginx]
        IM[ImageManager]
        Registry[Docker Hub<br/>registry-1.docker.io]

        CLI --> IM
        IM -->|1. Fetch manifest| Registry
        Registry -->|2. Manifest JSON| IM
        IM -->|3. Parse layers| IM
        IM -->|4. Download blobs<br/>Up to 8 parallel| Registry
        Registry -->|5. Layer data| IM
        IM -->|6. Store in OCI layout| Storage
    end

    subgraph "OCI Image Layout ~/.arca/images/"
        Storage[blobs/<br/>├── sha256/<br/>│   ├── abc123...<br/>│   ├── def456...<br/>│   └── ...]
        Index[index.json]
        Manifests[manifests/<br/>└── nginx/latest]
    end

    IM -.->|Progress events| Progress[Docker CLI<br/>Progress bars]

    Storage --> Index
    Index --> Manifests

    style CLI fill:#e1f5ff
    style IM fill:#fff4e1
    style Registry fill:#ffe1ff
    style Storage fill:#e1ffe1
```

### Image Progress Reporting

```mermaid
sequenceDiagram
    participant IM as ImageManager
    participant Apple as Apple Framework
    participant CLI as Docker CLI

    Note over IM: Parse manifest,<br/>get layer digests

    IM->>CLI: Layer abc123: Pulling fs layer
    IM->>CLI: Layer def456: Pulling fs layer
    IM->>CLI: Layer ghi789: Pulling fs layer

    Apple->>IM: add-size: 1024 bytes
    Note over IM: Distribute progress<br/>proportionally by size
    IM->>CLI: Layer abc123: Downloading [=>   ] 512B/2KB
    IM->>CLI: Layer def456: Downloading [>    ] 256B/4KB

    Apple->>IM: add-items: 1
    Note over IM: Estimate completion<br/>by size ratios
    IM->>CLI: Layer abc123: Pull complete

    Apple->>IM: add-size: 2048 bytes
    IM->>CLI: Layer def456: Downloading [===> ] 2KB/4KB

    Apple->>IM: add-items: 1
    IM->>CLI: Layer def456: Pull complete

    Note over IM,CLI: Aggregate progress accurate,<br/>per-layer progress estimated
```

## Container Lifecycle Integration

```mermaid
graph TB
    subgraph "Arca ContainerManager"
        Create[createContainer]
        Start[startContainer]
        Monitor[Monitoring Goroutine]
        StateStore[(StateStore<br/>SQLite)]
    end

    subgraph "Apple Containerization Framework"
        ACF[Containerization API]
        VM[Linux VM<br/>Ephemeral]
    end

    subgraph "WireGuard Service"
        WGS[arca-wireguard-service<br/>vsock:51820]
        WG[WireGuard<br/>Interfaces]
    end

    Create -->|1. Save config| StateStore
    Create -->|2. Create VM| ACF
    ACF -->|3. VM object| VM

    Start -->|4. Configure network| WGS
    WGS -->|5. Setup WireGuard| WG
    Start -->|6. Start process| VM
    Start -->|7. Start monitoring| Monitor

    Monitor -->|Wait for exit| VM
    VM -->|Exit code| Monitor
    Monitor -->|8. Record exit| StateStore
    Monitor -->|9. Check restart policy| Monitor
    Monitor -.->|If restart| Start

    style StateStore fill:#e1ffe1
    style VM fill:#ffe1e1
    style Monitor fill:#fff4e1
```

## vminitd Custom Fork

```mermaid
graph TB
    subgraph "Arca Repository"
        Submodule[containerization/<br/>Git Submodule]
    end

    subgraph "arca-vminitd Fork"
        Upstream[Apple's upstream<br/>containerization repo]
        Extensions[vminitd/extensions/<br/>Arca-specific code]

        subgraph "Extensions"
            WG[wireguard-service/<br/>WireGuard management]
            FS[filesystem-service/<br/>OverlayFS operations]
        end
    end

    subgraph "Built vminit:latest Image ~/.arca/vminit/"
        Binary[/sbin/vminitd<br/>PID 1 in containers]
        WGBin[/usr/local/bin/<br/>arca-wireguard-service]
        FSBin[/usr/local/bin/<br/>arca-filesystem-service]
    end

    Submodule -.->|Points to| Upstream
    Submodule --> Extensions

    Extensions --> WG
    Extensions --> FS

    WG -->|Built into| WGBin
    FS -->|Built into| FSBin
    Upstream -->|Built into| Binary

    Binary -.->|Runs| WGBin
    Binary -.->|Runs| FSBin

    style Submodule fill:#e1f5ff
    style Extensions fill:#fff4e1
    style WG fill:#ffe1ff
    style FS fill:#ffe1ff
    style Binary fill:#e1ffe1
```

## HTTP Streaming

```mermaid
sequenceDiagram
    participant CLI as Docker CLI
    participant Handler as ImageHandlers
    participant Writer as HTTPStreamWriter
    participant Manager as ImageManager
    participant Apple as Apple Framework

    CLI->>Handler: POST /images/create?fromImage=nginx
    Handler->>Manager: pullImage("nginx")
    Handler-->>Writer: Return streaming response

    Note over Handler,Writer: HTTP/1.1 200 OK<br/>Transfer-Encoding: chunked<br/>Content-Type: application/json

    loop For each progress event
        Apple->>Manager: Progress event
        Manager->>Writer: JSON + newline
        Writer->>CLI: {"status":"Downloading",...}\n
    end

    Manager-->>Writer: Pull complete
    Writer->>CLI: {"status":"Pull complete"}\n
    Writer-->>CLI: Close stream
```

## Code Signing & Entitlements

```mermaid
graph LR
    Source[Swift Source Code]
    Build[swift build]
    Binary[Arca Binary]
    Sign[codesign]
    Entitled[Signed Binary<br/>with Entitlements]
    Run[Execute]

    Source --> Build
    Build --> Binary
    Binary --> Sign
    Sign --> Entitled
    Entitled --> Run

    Entitlements[Arca.entitlements<br/>- Virtualization<br/>- Network Client<br/>- Network Server]

    Entitlements -.->|Applied during| Sign

    Run -->|Access| Apple[Apple Containerization<br/>Framework]

    style Entitlements fill:#ffe1e1
    style Apple fill:#ffe1e1
    style Entitled fill:#e1ffe1
```

## Performance Characteristics

| Component | Metric | Value | Notes |
|-----------|--------|-------|-------|
| **Container Startup** | Time | 1-3 seconds | VM initialization overhead |
| **Memory per Container** | RAM | 50-100 MB | VM overhead vs namespace isolation |
| **Network Latency** | WireGuard | ~1 ms | Peer-to-peer tunnels |
| **Network Latency** | vmnet | ~0.5 ms | Native Apple networking |
| **Image Pull** | Parallelism | 8 concurrent | Apple's parallel downloader |
| **Image Storage** | Type | Content-addressable | Layer deduplication |

## Key Design Decisions

### 1. WireGuard for Default Networking
**Why?** Full Docker API compatibility, dynamic network operations, multi-network support
**Trade-off:** Slightly higher latency (~1ms vs ~0.5ms for vmnet) but much more flexible

### 2. Container Persistence via SQLite
**Why?** Containers survive daemon restarts, Docker-compatible behavior
**Trade-off:** Added complexity, database maintenance

### 3. VirtioFS for Default Volumes
**Why?** Simple, reliable, shareable across containers
**Trade-off:** Some filesystem features limited vs native Linux

### 4. Buildx Integration (Not Custom Build API)
**Why?** Full feature coverage, zero maintenance, future-proof
**Trade-off:** Requires buildx installed, can't customize build internals

### 5. VM per Container (Apple's Model)
**Why?** Strong isolation, required by Apple's framework
**Trade-off:** Higher resource usage vs namespace-based containers

## Development Architecture

```mermaid
graph LR
    subgraph "Development Tools"
        Make[Makefile<br/>Build orchestration]
        Scripts[scripts/<br/>Helper scripts]
        Tests[Tests/<br/>Integration tests]
    end

    subgraph "Build Process"
        SwiftBuild[swift build]
        CodeSign[codesign<br/>Apply entitlements]
        Binary[Arca Binary]
    end

    subgraph "Runtime"
        Daemon[Arca Daemon<br/>/tmp/arca.sock]
        DockerCLI[Docker CLI<br/>DOCKER_HOST=unix:///tmp/arca.sock]
    end

    Make --> SwiftBuild
    Make --> Scripts
    SwiftBuild --> CodeSign
    CodeSign --> Binary
    Binary --> Daemon

    DockerCLI --> Daemon
    Tests --> DockerCLI

    style Make fill:#e1f5ff
    style Binary fill:#e1ffe1
    style Daemon fill:#fff4e1
```

---

For more information, see:
- **OVERVIEW.md** - High-level project introduction
- **LIMITATIONS.md** - Known differences from Docker
- **Source code** - `Sources/` directories with inline documentation
