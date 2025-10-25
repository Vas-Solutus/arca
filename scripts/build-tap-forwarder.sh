#!/bin/bash
# Build arca-tap-forwarder for Linux using Go cross-compilation
# This binary runs inside container VMs to forward TAP traffic over vsock

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_FORWARDER_DIR="$PROJECT_ROOT/arca-tap-forwarder-go"
OUTPUT_DIR="$PROJECT_ROOT/.arca-build"
INSTALL_PATH="$HOME/.arca/bin/arca-tap-forwarder"

echo "=== Building arca-tap-forwarder for Linux (Go) ==="
echo

# Check if Go is installed
if ! command -v go &> /dev/null; then
    echo "ERROR: Go not installed"
    echo "Install Go from: https://go.dev/dl/"
    exit 1
fi

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo "ERROR: protoc not installed"
    echo "Install protoc from: https://grpc.io/docs/protoc-installation/"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$INSTALL_PATH")"

# Build for Linux
cd "$TAP_FORWARDER_DIR"

# Ensure dependencies are downloaded
echo "→ Downloading Go dependencies..."
go mod download

# Cross-compile for Linux ARM64
echo "→ Building arca-tap-forwarder for Linux (aarch64)..."
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -o "$INSTALL_PATH" \
    ./cmd/arca-tap-forwarder

if [ ! -f "$INSTALL_PATH" ]; then
    echo "ERROR: Build completed but binary not found at: $INSTALL_PATH"
    exit 1
fi

# Copy to output directory
cp "$INSTALL_PATH" "$OUTPUT_DIR/arca-tap-forwarder"
echo "  ✓ Built: $OUTPUT_DIR/arca-tap-forwarder"
echo "  ✓ Installed: $INSTALL_PATH"

# Show binary info
echo
echo "=== Binary Information ==="
file "$INSTALL_PATH"
ls -lh "$INSTALL_PATH"

echo
echo "=== Build Complete ==="
echo
echo "The arca-tap-forwarder binary is ready to be injected into container VMs."
echo "It will be bind-mounted at /.arca/bin/arca-tap-forwarder in containers."
