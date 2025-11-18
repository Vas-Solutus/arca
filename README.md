# Arca

**A native container engine for macOS**

Arca is a complete container runtime built on Apple's Virtualization framework. It provides Docker CLI compatibility while leveraging macOS's native VM-per-container architecture for security and performance.

Part of the [Vas Solutus](https://vassolutus.com) project - freeing containers on macOS.

## Features

- ✅ Docker CLI and Docker Compose compatibility
- ✅ Native Apple Silicon performance (VM-per-container architecture)
- ✅ WireGuard-based networking with multi-network support
- ✅ Container name resolution via embedded DNS
- ✅ Named volumes with multiple driver support
- ✅ Container persistence with restart policies
- ✅ OCI-compliant image support

## Quick Start

```bash
# Clone repository with submodules
git clone --recurse-submodules https://github.com/Liquescent-Development/arca.git
cd arca

# Build custom vminit (one-time setup, ~5 minutes)
cd containerization
make cross-prep  # Install Swift Static Linux SDK
cd ..
make vminit      # Build vminit:latest with networking extensions

# Build and run Arca
make run         # Builds, signs, and starts daemon at /tmp/arca.sock

# Configure Docker CLI (in another terminal)
export DOCKER_HOST=unix:///tmp/arca.sock
docker run -d nginx:latest
docker ps
```

**No root required** - Arca runs at `~/.arca/arca.sock` by default, avoiding permission issues.

## Installation

For persistent use, install as a LaunchAgent service:

```bash
make install-service    # Install service (no sudo required)
make start-service      # Start service
make configure-shell    # Add DOCKER_HOST to shell profile
```

## Key Architecture

- **Forked Apple Containerization**: Custom fork with networking extensions
- **WireGuard Networking**: Full mesh peer-to-peer container networking
- **SQLite Persistence**: Container state survives daemon restarts
- **Custom Init System**: Extended vminitd with gRPC API for network control

## Documentation

- [OVERVIEW.md](Documentation/OVERVIEW.md) - Architecture and design
- [IMPLEMENTATION_PLAN.md](Documentation/IMPLEMENTATION_PLAN.md) - Current status and roadmap
- [LIMITATIONS.md](Documentation/LIMITATIONS.md) - Known differences from Docker
- [ARCHITECTURE.md](Documentation/ARCHITECTURE.md) - Technical deep-dive

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).