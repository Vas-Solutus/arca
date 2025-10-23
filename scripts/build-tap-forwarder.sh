#!/bin/bash
# Build arca-tap-forwarder for Linux using Swift Static Linux SDK
# This binary runs inside container VMs to forward TAP traffic over vsock

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TAP_FORWARDER_DIR="$PROJECT_ROOT/arca-tap-forwarder"
OUTPUT_DIR="$PROJECT_ROOT/.arca-build"
INSTALL_PATH="$HOME/.arca/bin/arca-tap-forwarder"

echo "=== Building arca-tap-forwarder for Linux ==="
echo

# Check if Swift Static Linux SDK is installed
if ! swift sdk list 2>&1 | grep -q "static-linux"; then
    echo "ERROR: Swift Static Linux SDK not installed"
    echo
    echo "Install with:"
    echo "  cd .build/checkouts/containerization/vminitd"
    echo "  make cross-prep"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"
mkdir -p "$(dirname "$INSTALL_PATH")"

# Build for Linux
cd "$TAP_FORWARDER_DIR"

# Use swiftly's Swift toolchain to match the SDK
SWIFT_BIN="${HOME}/.swiftly/bin/swift"
if [ ! -f "$SWIFT_BIN" ]; then
    echo "ERROR: swiftly Swift not found at $SWIFT_BIN"
    echo "The Static Linux SDK requires the release version of Swift 6.2"
    exit 1
fi

echo "→ Building arca-tap-forwarder for Linux (aarch64-musl)..."
"$SWIFT_BIN" build \
    -c release \
    --swift-sdk aarch64-swift-linux-musl \
    --product arca-tap-forwarder

# Get build path
BUILD_PATH=$("$SWIFT_BIN" build -c release --swift-sdk aarch64-swift-linux-musl --show-bin-path)
BINARY_PATH="$BUILD_PATH/arca-tap-forwarder"

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Build completed but binary not found at: $BINARY_PATH"
    exit 1
fi

# Copy to output directory
cp "$BINARY_PATH" "$OUTPUT_DIR/arca-tap-forwarder"
echo "  ✓ Built: $OUTPUT_DIR/arca-tap-forwarder"

# Install to ~/.arca/bin
cp "$BINARY_PATH" "$INSTALL_PATH"
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
echo "Next steps:"
echo "  1. Update ContainerManager to copy this binary into containers"
echo "  2. Launch it when ARCA_NETWORK_PORT is set in environment"
