# Arca

**Docker Engine API for Apple Containerization**

Arca implements the Docker Engine API backed by Apple's Containerization framework,
enabling Docker CLI, Docker Compose, and the entire Docker ecosystem to work with
Apple's high-performance, VM-per-container architecture on macOS.

Part of the [Vas Solutus](https://vassolutus.com) project - freeing containers on macOS.

## Why?

Apple's `container` tool provides excellent performance and security through
VM-per-container architecture, but lacks compatibility with the Docker ecosystem.
This project implements the Docker Engine API to bridge that gap.

## Features

- ✅ Docker CLI compatibility
- ✅ Docker Compose support (with limitations)
- ✅ Native Apple Silicon performance
- ✅ OCI-compliant image support
- ⚠️  Networking differs from Docker (DNS-based)
- ⚠️  Some volume operations limited by VirtioFS

## Installation

### Prerequisites

Arca requires the `vminit` init system to be built before it can run containers. This is a one-time setup step.

### Build vminit (One-Time Setup)

The `vminit` init system runs inside each container's VM and provides container management capabilities. To build it:

```bash
cd .build/checkouts/containerization

# Install Swift Static Linux SDK (one-time, ~5 minutes)
make cross-prep

# Build vminitd binaries
make vminitd

# Package into vminit:latest OCI image
make init
```

This creates the `vminit:latest` image in `~/Library/Application Support/com.apple.containerization/`.

**Note**: This step is only needed once. Future versions of Arca will automate this process or include pre-built binaries.

### Build and Run Arca

```bash
# Build from source
swift build -c release

# Start the daemon
.build/release/arca daemon start

# Configure Docker CLI to use Arca
export DOCKER_HOST=unix:///var/run/arca.sock
```

## Coexistence with Docker Desktop / Colima

Arca uses `/var/run/arca.sock` instead of `/var/run/docker.sock`, allowing it to run alongside
Docker Desktop or Colima without conflicts.

### Switching between Docker implementations:

```bash
# Use Docker Desktop / Colima (default)
export DOCKER_HOST=unix:///var/run/docker.sock
docker ps

# Use Arca
export DOCKER_HOST=unix:///var/run/arca.sock
docker ps
```

### Shell aliases for easy switching:

```bash
# Add to your ~/.zshrc or ~/.bashrc
alias docker-colima='export DOCKER_HOST=unix:///var/run/docker.sock'
alias docker-arca='export DOCKER_HOST=unix:///var/run/arca.sock'

# Usage:
docker-arca
docker ps    # Now using Arca

docker-colima
docker ps    # Now using Colima/Docker Desktop
```

### Per-command override:

```bash
# Run single command with Arca
DOCKER_HOST=unix:///var/run/arca.sock docker ps

# Run single command with Colima
DOCKER_HOST=unix:///var/run/docker.sock docker ps
```

## Usage
```bash
# Use Docker CLI as normal
docker run -d nginx:latest
docker ps
docker compose up
```

## API Coverage

See [API_COVERAGE.md](Documentation/API_COVERAGE.md) for full list of
implemented endpoints.

## Limitations

See [LIMITATIONS.md](Documentation/LIMITATIONS.md) for known differences
from Docker.

## Contributing

Contributions welcome! See [CONTRIBUTING.md](CONTRIBUTING.md).