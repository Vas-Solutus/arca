#!/bin/bash
# Build custom vminit:latest image with arca-tap-forwarder included
# This creates a vminit init system that supports container networking

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTAINERIZATION_DIR="$PROJECT_ROOT/.build/checkouts/containerization"
OUTPUT_DIR="$HOME/.arca/vminit-build"
TAP_FORWARDER_PATH="$HOME/.arca/bin/arca-tap-forwarder"

echo "=== Building custom vminit:latest with arca-tap-forwarder ==="
echo

# Check if arca-tap-forwarder exists
if [ ! -f "$TAP_FORWARDER_PATH" ]; then
    echo "ERROR: arca-tap-forwarder not found at: $TAP_FORWARDER_PATH"
    echo "Run: make tap-forwarder"
    exit 1
fi

# Check if containerization checkout exists
if [ ! -d "$CONTAINERIZATION_DIR" ]; then
    echo "ERROR: Containerization package not found"
    echo "Run: swift package resolve"
    exit 1
fi

# Build vminitd and vmexec from Apple's source
# Use swiftly's Swift toolchain to match the Static Linux SDK
export PATH="$HOME/.swiftly/bin:$PATH"

echo "→ Building vminitd and vmexec..."
cd "$CONTAINERIZATION_DIR/vminitd"
make all BUILD_CONFIGURATION=release

VMINITD_PATH="$CONTAINERIZATION_DIR/vminitd/bin/vminitd"
VMEXEC_PATH="$CONTAINERIZATION_DIR/vminitd/bin/vmexec"

if [ ! -f "$VMINITD_PATH" ]; then
    echo "ERROR: vminitd not found at: $VMINITD_PATH"
    exit 1
fi

if [ ! -f "$VMEXEC_PATH" ]; then
    echo "ERROR: vmexec not found at: $VMEXEC_PATH"
    exit 1
fi

echo "  ✓ vminitd: $VMINITD_PATH"
echo "  ✓ vmexec: $VMEXEC_PATH"
echo "  ✓ arca-tap-forwarder: $TAP_FORWARDER_PATH"

# Build containerization tools (cctl) if not already built
echo
echo "→ Building cctl tool..."
cd "$CONTAINERIZATION_DIR"
swift build -c release --product cctl

CCTL_PATH="$CONTAINERIZATION_DIR/.build/release/cctl"
if [ ! -f "$CCTL_PATH" ]; then
    echo "ERROR: cctl not found at: $CCTL_PATH"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Build vminit rootfs with arca-tap-forwarder included
echo
echo "→ Creating vminit rootfs with arca-tap-forwarder..."
cd "$OUTPUT_DIR"

# Path to init script
INIT_SCRIPT_PATH="$PROJECT_ROOT/arca-vminit/init-arca-networking.sh"

if [ ! -f "$INIT_SCRIPT_PATH" ]; then
    echo "ERROR: Init script not found at: $INIT_SCRIPT_PATH"
    exit 1
fi

"$CCTL_PATH" rootfs create \
    --vminitd "$VMINITD_PATH" \
    --vmexec "$VMEXEC_PATH" \
    --add-file "$TAP_FORWARDER_PATH:/sbin/arca-tap-forwarder" \
    --add-file "$INIT_SCRIPT_PATH:/etc/init.d/arca-networking" \
    --label org.opencontainers.image.source=https://github.com/your-org/arca \
    --label arca.networking.enabled=true \
    --image vminit:latest \
    init.rootfs.tar.gz

echo "  ✓ Created: $OUTPUT_DIR/init.rootfs.tar.gz"
echo

# Verify the image was created
echo "→ Verifying vminit:latest image..."
if "$CCTL_PATH" image ls | grep -q "vminit.*latest"; then
    echo "  ✓ vminit:latest image created successfully"
else
    echo "  ⚠ Warning: Could not verify image creation"
fi

echo
echo "=== Build Complete ==="
echo
echo "The vminit:latest image now includes:"
echo "  - /sbin/vminitd (Apple's init system)"
echo "  - /sbin/vmexec (Apple's exec helper)"
echo "  - /sbin/arca-tap-forwarder (Arca's TAP networking forwarder)"
echo
echo "Location: ~/Library/Containers/com.apple.Containerization/Data/vminit:latest"
echo
echo "Next steps:"
echo "  1. Modify vminit startup to launch arca-tap-forwarder when ARCA_NETWORK_PORT is set"
echo "  2. Update ContainerManager to pass network environment variables"
