# Arca Overview

**Arca** implements the Docker Engine API backed by Apple's Containerization framework, enabling the Docker ecosystem to work with Apple's VM-per-container architecture on macOS.

Part of the Vas Solutus project - freeing containers on macOS.

## What is Arca?

Arca is a Docker Engine API server that runs on macOS and uses Apple's native Containerization framework instead of traditional Linux containers. This means:

- Your existing Docker CLI works without modification
- Docker Compose files work as expected
- Docker Buildx integration for building images
- Native Apple Silicon performance
- Each container runs in its own lightweight Linux VM for strong isolation

## Why Arca?

**Native macOS Integration**: Uses Apple's official Containerization framework instead of requiring a separate Linux VM (like Docker Desktop's LinuxKit approach).

**Strong Isolation**: VM-per-container architecture provides better security isolation than namespace-based containers.

**Docker Compatibility**: Standard Docker tools (CLI, Compose, buildx) work without modification.

**Coexistence**: Runs alongside Docker Desktop - switch between them by setting `DOCKER_HOST`.

**Open Source**: Fully open source, hackable, and extendable.

## Quick Start

### Prerequisites

- macOS 14.0+ (Sonoma or later)
- Apple Silicon (M1/M2/M3) or Intel Mac with Virtualization support
- Xcode Command Line Tools

### Installation

```bash
# Clone the repository
git clone https://github.com/your-org/arca.git
cd arca

# Initialize submodules (for custom vminit)
git submodule update --init --recursive

# Build and install
make
sudo make install

# Start the daemon
arca daemon start
```

### Using Arca

```bash
# Configure Docker CLI to use Arca
export DOCKER_HOST=unix:///var/run/arca.sock

# Verify connection
docker version
docker info

# Run a container
docker run -d --name web nginx
docker ps
docker logs web

# Create a network
docker network create mynet
docker run --network mynet --name app alpine ping -c 3 app

# Create a volume
docker volume create mydata
docker run -v mydata:/data alpine sh -c 'echo hello > /data/test.txt'

# Use Docker Compose
docker compose up -d
```

### Switch Back to Docker Desktop

```bash
unset DOCKER_HOST
docker ps  # Now talking to Docker Desktop
```

## Key Features

### ✅ Implemented

- **Container Lifecycle**: create, start, stop, restart, pause, unpause, kill, remove, rename
- **Container Operations**: logs, stats, top, attach, wait, inspect
- **Exec API**: Run commands in running containers with full TTY support
- **Image Operations**: pull, list, inspect, remove, tag, history
- **Networking**: Create networks, attach/detach containers dynamically, full mesh WireGuard networking
- **Volumes**: Named volumes (VirtioFS directories), bind mounts, read-only mounts
- **Events**: Real-time event stream for container, network, and volume events
- **Container Persistence**: Containers survive daemon restarts with restart policies

### ⚠️ Partially Implemented

- **Build API**: Not directly implemented, use `docker buildx` instead (fully functional)
- **Embedded DNS**: Container name resolution (127.0.0.11:53) not yet implemented

### ❌ Not Implemented

- **Swarm Mode**: Not supported (use Kubernetes or other orchestrators)
- **Plugins**: Plugin system not implemented
- **Secrets/Configs**: Swarm secrets not supported

## Architecture Highlights

### VM-per-Container Isolation

Each container runs in its own lightweight Linux VM:

```
Container A ← Linux VM ← Apple Virtualization Framework
Container B ← Linux VM ← Apple Virtualization Framework
Container C ← Linux VM ← Apple Virtualization Framework
```

**Benefits:**
- Strong security isolation (hypervisor-based)
- Full Linux kernel per container
- Hardware virtualization features

**Trade-offs:**
- Higher memory usage (~50-100MB per container)
- Slower startup (~1-3s for VM initialization)
- More resource overhead vs namespace containers

### WireGuard Networking

Default bridge networks use WireGuard peer-to-peer tunnels:

```
Container A (172.20.0.2) ←→ WireGuard ←→ Container B (172.20.0.3)
Container A (172.20.0.2) ←→ WireGuard ←→ Container C (172.20.0.4)
Container B (172.20.0.3) ←→ WireGuard ←→ Container C (172.20.0.4)
```

**Benefits:**
- Full Docker Network API compatibility
- Dynamic network attach/detach
- Multi-network containers
- Network isolation
- ~1ms latency

**Alternative:** Use `--driver vmnet` for native Apple networking (~0.5ms latency, limited features)

### Volume Types

**Named Volumes** (default: `local` driver):
- VirtioFS-based directory shares
- Stored at `~/.arca/volumes/{name}/data/`
- Shareable across multiple containers
- Simple and reliable

**Named Volumes** (optional: `block` driver):
- EXT4-formatted block devices
- Stored at `~/.arca/volumes/{name}/volume.img`
- Exclusive access (one container at a time)
- Better performance for heavy I/O

**Bind Mounts**:
- Mount macOS host directories into containers
- Read-only support with `:ro` suffix
- Uses VirtioFS

### Container Persistence

Containers survive daemon restarts:

1. Container metadata saved to SQLite database
2. Daemon crashes/restarts → Container VMs destroyed (ephemeral)
3. `docker start` → Container recreated from database
4. Restart policies determine auto-restart behavior

**Restart Policies:**
- `always` - Always restart
- `unless-stopped` - Restart unless explicitly stopped
- `on-failure` - Restart on non-zero exit
- `no` - Never auto-restart (default)

### Custom vminit

Arca uses a custom fork of Apple's vminitd with extensions for networking:

- **arca-wireguard-service** - Manages WireGuard interfaces via gRPC
- **arca-filesystem-service** - Handles OverlayFS operations

Built into `vminit:latest` OCI image and transparently used by all containers.

## Use Cases

### Development

Replace Docker Desktop for local development:

```bash
# Your existing docker-compose.yml works
docker compose up -d

# Debug with logs and exec
docker logs myapp
docker exec -it myapp sh
```

### Testing

Run integration tests with strong isolation:

```bash
# Each test gets isolated VMs
docker run --rm test-runner npm test
```

### CI/CD

Use Arca in macOS CI pipelines:

```bash
# In GitHub Actions or similar
- run: arca daemon start
- run: docker compose up -d
- run: make test
```

### Learning

Study container technology on macOS:

- Inspect how VMs work
- Experiment with networking
- Understand OCI image formats

## Performance

| Operation | Performance | Notes |
|-----------|-------------|-------|
| Container start | 1-3 seconds | VM initialization |
| Container stop | <1 second | Fast shutdown |
| Network latency | ~1ms | WireGuard peer-to-peer |
| Image pull | Fast | 8 parallel downloads |
| Memory per container | 50-100MB | VM overhead |

## Project Structure

```
arca/
├── Sources/
│   ├── Arca/              # CLI executable
│   ├── ArcaDaemon/        # SwiftNIO HTTP server
│   ├── DockerAPI/         # Docker API models & handlers
│   └── ContainerBridge/   # Apple Containerization bridge
├── Tests/
│   └── ArcaTests/         # Unit tests
├── Documentation/
│   ├── OVERVIEW.md        # This file
│   ├── ARCHITECTURE.md    # Technical architecture
│   └── LIMITATIONS.md     # Known limitations
├── containerization/      # Custom vminitd fork (submodule)
├── scripts/               # Build and test scripts
├── Makefile               # Build orchestration
└── Package.swift          # Swift Package Manager config
```

## Building from Source

### One-Time Setup

```bash
# 1. Clone with submodules
git clone --recurse-submodules https://github.com/your-org/arca.git
cd arca

# 2. Build custom vminit (includes WireGuard service)
# This takes ~5 minutes the first time
make vminit
```

### Build and Run

```bash
# Debug build with automatic signing
make

# Run in development mode (uses /tmp/arca.sock)
make run

# In another terminal, use Docker CLI
export DOCKER_HOST=unix:///tmp/arca.sock
docker run hello-world
```

### Release Build

```bash
# Optimized release build
make release

# Install system-wide
sudo make install

# Run daemon
arca daemon start
```

## Development

### Running Tests

```bash
# Unit tests
swift test

# Integration tests with Docker CLI
make run  # In one terminal
./scripts/test-phase1-mvp.sh  # In another
```

### Modifying Networking

```bash
# 1. Edit WireGuard service code
vim containerization/vminitd/extensions/wireguard-service/main.go

# 2. Rebuild vminit image
make vminit

# 3. Restart daemon
# New containers will use updated vminit
```

### Protocol Changes

```bash
# 1. Edit protobuf definition
vim containerization/vminitd/extensions/wireguard-service/proto/wireguard.proto

# 2. Regenerate gRPC code (Go + Swift)
./scripts/generate-grpc.sh

# 3. Rebuild vminit
make vminit
```

## Configuration

Arca looks for configuration at `~/.arca/config.json`:

```json
{
  "kernelPath": "~/.arca/vmlinux",
  "socketPath": "/var/run/arca.sock",
  "logLevel": "info"
}
```

**Configuration Options:**

- `kernelPath` - Path to Linux kernel (default: `~/.arca/vmlinux`)
- `socketPath` - Docker API socket path (default: `/var/run/arca.sock`)
- `logLevel` - Logging verbosity: `debug`, `info`, `warning`, `error`

## Comparison with Other Tools

| Feature | Arca | Docker Desktop | Colima |
|---------|------|----------------|--------|
| **Backend** | Apple Containerization | LinuxKit VM | Lima VM |
| **Isolation** | VM per container | Shared Linux VM | Shared Linux VM |
| **Docker API** | Native Swift | Docker Engine | Docker Engine |
| **Networking** | WireGuard / vmnet | vpnkit | Lima networking |
| **Performance** | Good (VM overhead) | Good | Good |
| **Open Source** | ✅ Full | ⚠️ Partial | ✅ Full |
| **macOS Native** | ✅ Yes | ⚠️ Partial | ❌ No |

## Troubleshooting

### Daemon won't start

```bash
# Check if socket already exists
ls -la /var/run/arca.sock

# Check if code signing worked
codesign -d --entitlements - .build/debug/Arca

# Check logs
arca daemon start --log-level debug
```

### Container won't start

```bash
# Check container state
docker inspect mycontainer

# Check daemon logs (they include container errors)
# Logs appear in terminal where daemon is running

# Check if vminit image exists
ls -la ~/.arca/vminit/
```

### Network issues

```bash
# List networks
docker network ls

# Inspect network
docker network inspect bridge

# Check if WireGuard service is running in container
docker exec mycontainer ps aux | grep wireguard
```

### Permission errors

```bash
# Arca needs entitlements to access Virtualization framework
make verify-entitlements

# Reapply code signing
make clean
make
```

## Documentation

- **OVERVIEW.md** (this file) - High-level introduction
- **ARCHITECTURE.md** - Technical architecture with diagrams
- **LIMITATIONS.md** - Known differences from Docker
- **CLAUDE.md** - Development notes for Claude Code (not for public)

## Contributing

Contributions welcome! Please:

1. Read ARCHITECTURE.md to understand the system
2. Follow existing code patterns (see Swift style in sources)
3. Add tests for new features
4. Update documentation

## License

[License information here]

## Acknowledgments

- **Apple** - Containerization framework
- **Docker** - Docker Engine API specification
- **WireGuard** - Networking protocol
- **Swift Community** - SwiftNIO, grpc-swift, and other packages

---

For technical details, see [ARCHITECTURE.md](ARCHITECTURE.md)

For limitations and differences, see [LIMITATIONS.md](LIMITATIONS.md)
