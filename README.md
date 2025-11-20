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

### Option 1: macOS Installer (Recommended)

Download and install the latest `.pkg` installer:

```bash
# Download from GitHub Releases
curl -LO https://github.com/liquescent-development/arca/releases/latest/download/Arca-latest.pkg

# Install (includes kernel, vminit, and auto-start daemon)
sudo installer -pkg Arca-latest.pkg -target /

# Configure your shell
export DOCKER_HOST=unix://~/.arca/arca.sock
echo 'export DOCKER_HOST=unix://~/.arca/arca.sock' >> ~/.zshrc

# Start using Docker!
docker run hello-world
```

The `.pkg` installer:
- ✅ Includes pre-built kernel and vminit (no manual setup required)
- ✅ Auto-starts daemon on boot via LaunchAgent
- ✅ Installs to `/usr/local/bin/Arca`
- ✅ Works on macOS 15.0+ (Sequoia)

### Option 2: Homebrew (Coming Soon)

```bash
brew install liquescent-development/arca/arca
brew services start arca
```

### Option 3: Build from Source

For development or if you want to build yourself:

```bash
# Clone repository with submodules
git clone --recurse-submodules https://github.com/Liquescent-Development/arca.git
cd arca

# Build pre-built assets (one-time, ~20-25 minutes)
make build-assets

# Install as LaunchAgent service
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
- [ARCHITECTURE.md](Documentation/ARCHITECTURE.md) - Technical deep-dive
- [LIMITATIONS.md](Documentation/LIMITATIONS.md) - Known differences from Docker

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).