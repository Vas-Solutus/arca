# Arca

**Docker compatible, Apple native, secure container engine for macOS**

Arca is a complete container runtime built on Apple's Virtualization framework. It provides Docker CLI compatibility while leveraging macOS's native VM-per-container architecture for security and performance.

Part of the [Vas Solutus](https://vassolutus.com) project - freeing containers on macOS.

## Features

- Docker CLI and Docker Compose compatibility
- Secure native Apple Silicon performance utilizing a lightweight virtual machine per container
- Encrypted WireGuard-based networking with multi-network support

## Development Quick Start

### Download and install Apple's [container CLI](https://github.com/apple/container/releases) (Bootstraps the Linux kernel build)

### Clone Arca
```bash
# Clone repository with submodules
git clone --recurse-submodules https://github.com/Vas-Solutus/arca.git
cd arca
```
### Configure Swift Linux SDK and build vminit
```bash
# Build custom vminit (one-time setup, ~5 minutes)
cd containerization
make cross-prep  # Install Swift Static Linux SDK
cd ..
make vminit      # Build vminit:latest with networking extensions
```

### Build and run Arca
```bash
# Build and run Arca
make run         # Builds, signs, and starts daemon at /tmp/arca.sock

# Configure Docker CLI (in another terminal)
export DOCKER_HOST=unix:///tmp/arca.sock
docker run -d nginx:latest
docker ps
```

## Installation

### Ensure prerequisites are installed

```bash
# Install the Docker CLI
brew install docker

# Install Docker Buildx
brew install docker-buildx

# Install Docker Compose
brew install docker-compose
```

### Download and install the latest `.dmg` [release](https://github.com/Vas-Solutus/arca/releases) and drag Arca to your applications folder.

```bash
# Configure your shell
export DOCKER_HOST=unix://~/.arca/arca.sock
echo 'export DOCKER_HOST=unix://~/.arca/arca.sock' >> ~/.zshrc

# Start using Docker!
docker run hello-world
```

The `.dmg`:
- Includes pre-built kernel and vminit (no manual setup required)
- Auto-starts daemon on boot via LaunchAgent
- Works on macOS 15.0+ (Sequoia)

## Key Architecture

- **Forked Apple Containerization**: Custom fork with networking extensions
- **WireGuard Networking**: Full mesh peer-to-peer container networking
- **SQLite Persistence**: Container state survives daemon restarts
- **Custom Init System**: Extended vminitd with gRPC API for network control

## Documentation

- [ARCHITECTURE.md](Documentation/ARCHITECTURE.md) - Technical deep-dive
- [DISTRIBUTION.md](Documentation/DISTRIBUTION.md) - Build and release process
- [VMINIT_BUILD.md](Documentation/VMINIT_BUILD.md) - Building custom vminit
