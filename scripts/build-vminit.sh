#!/bin/bash
# Build custom vminit:latest OCI image with Arca extensions
#
# This script builds a custom vminit image based on Apple's vminitd with
# Arca-specific networking extensions:
# - arca-tap-forwarder: TAP-over-vsock for overlay networks (legacy)
# - vlan-service: VLAN configuration service for bridge networks (Phase 3.5.5+)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VMINITD_DIR="$PROJECT_ROOT/containerization"

echo "========================================"
echo "Building custom vminit:latest"
echo "========================================"

# Check if vminitd submodule is initialized
if [ ! -f "$VMINITD_DIR/Package.swift" ]; then
    echo "ERROR: vminitd submodule not initialized"
    echo "Run: git submodule update --init --recursive"
    exit 1
fi

# Ensure Swift Static Linux SDK is installed (required for cross-compilation)
echo ""
echo "→ Checking for Swift Static Linux SDK..."
if ! swift sdk list 2>/dev/null | grep -q "static-linux"; then
    echo "ERROR: Swift Static Linux SDK not installed"
    echo ""
    echo "Install it with:"
    echo "  cd $VMINITD_DIR/vminitd"
    echo "  make cross-prep"
    echo ""
    echo "This is a one-time setup that takes ~5 minutes."
    exit 1
fi
echo "  ✓ Swift Static Linux SDK found"

# Build TAP forwarder (Go binary cross-compiled to Linux)
echo ""
echo "→ Building TAP forwarder (Go → Linux ARM64)..."
cd "$VMINITD_DIR/vminitd/extensions/tap-forwarder"

if [ ! -f build.sh ]; then
    echo "ERROR: tap-forwarder/build.sh not found"
    exit 1
fi

./build.sh

if [ ! -f arca-tap-forwarder ]; then
    echo "ERROR: arca-tap-forwarder binary not built"
    exit 1
fi

echo "  ✓ TAP forwarder built: arca-tap-forwarder"

# Build embedded DNS (Go binary cross-compiled to Linux)
echo ""
echo "→ Building embedded DNS (Go → Linux ARM64)..."
cd "$VMINITD_DIR/vminitd/extensions/embedded-dns"

if [ ! -f build.sh ]; then
    echo "ERROR: embedded-dns/build.sh not found"
    exit 1
fi

# Generate protobuf code first
if [ ! -f proto/network.pb.go ]; then
    echo "  Generating protobuf code..."
    ./generate-proto.sh
fi

./build.sh

if [ ! -f arca-embedded-dns ]; then
    echo "ERROR: arca-embedded-dns binary not built"
    exit 1
fi

echo "  ✓ Embedded DNS built: arca-embedded-dns"

# Build vminitd (Swift cross-compiled to Linux)
echo ""
echo "→ Building vminitd (Swift → Linux ARM64)..."
cd "$VMINITD_DIR"

# Build using parent Makefile's init target which handles the nested package properly
BUILD_CONFIGURATION=release make init

# The binaries are placed in vminitd/bin/ by the parent Makefile
VMINITD_BINARY="$VMINITD_DIR/vminitd/bin/vminitd"
VMEXEC_BINARY="$VMINITD_DIR/vminitd/bin/vmexec"

if [ ! -f "$VMINITD_BINARY" ]; then
    echo "ERROR: vminitd binary not built at $VMINITD_BINARY"
    exit 1
fi

if [ ! -f "$VMEXEC_BINARY" ]; then
    echo "ERROR: vmexec binary not built at $VMEXEC_BINARY"
    exit 1
fi

echo "  ✓ vminitd built: $VMINITD_BINARY"
echo "  ✓ vmexec built: $VMEXEC_BINARY"

# Create vminit rootfs using cctl (includes Swift runtime and all dependencies)
echo ""
echo "→ Creating vminit rootfs with cctl..."

# Path to cctl binary
CCTL_BINARY="$VMINITD_DIR/bin/cctl"

if [ ! -f "$CCTL_BINARY" ]; then
    echo "ERROR: cctl binary not found at $CCTL_BINARY"
    echo "Please build containerization first: cd containerization && make"
    exit 1
fi

# Output directory
VMINIT_DIR="$HOME/.arca/vminit"
rm -rf "$VMINIT_DIR"
mkdir -p "$VMINIT_DIR"

# Create rootfs tarball with cctl, adding our custom binaries
ROOTFS_TAR="$VMINIT_DIR/vminit-rootfs.tar"
OCI_DIR="$VMINIT_DIR/oci"

echo "  Using cctl to create rootfs with Swift runtime..."
"$CCTL_BINARY" rootfs create \
    --vminitd "$VMINITD_BINARY" \
    --vmexec "$VMEXEC_BINARY" \
    --add-file "$VMINITD_DIR/vminitd/extensions/tap-forwarder/arca-tap-forwarder:/sbin/arca-tap-forwarder" \
    --add-file "$VMINITD_DIR/vminitd/extensions/embedded-dns/arca-embedded-dns:/sbin/arca-embedded-dns" \
    --image arca-vminit:latest \
    --label org.opencontainers.image.source=https://github.com/liquescent-development/arca \
    "$ROOTFS_TAR"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "ERROR: cctl failed to create rootfs tarball"
    exit 1
fi

echo "  ✓ Rootfs tarball created: $(du -h "$ROOTFS_TAR" | awk '{print $1}')"

# Convert tarball to OCI image layout for loading into ImageStore
echo "  Converting rootfs to OCI image layout..."

# Extract tarball to temp directory
TEMP_ROOTFS="$VMINIT_DIR/temp_rootfs"
mkdir -p "$TEMP_ROOTFS"
tar -xf "$ROOTFS_TAR" -C "$TEMP_ROOTFS"

# Create OCI layout structure
mkdir -p "$OCI_DIR/blobs/sha256"

cat > "$OCI_DIR/oci-layout" <<EOF
{
  "imageLayoutVersion": "1.0.0"
}
EOF

# Create layer from extracted rootfs
LAYER_TAR="$VMINIT_DIR/layer.tar"
tar -C "$TEMP_ROOTFS" -cf "$LAYER_TAR" .
LAYER_DIGEST=$(shasum -a 256 "$LAYER_TAR" | awk '{print $1}')
LAYER_SIZE=$(stat -f%z "$LAYER_TAR")
mv "$LAYER_TAR" "$OCI_DIR/blobs/sha256/$LAYER_DIGEST"

# Create config
CONFIG_JSON=$(cat <<EOF
{
  "architecture": "arm64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:$LAYER_DIGEST"]
  },
  "config": {
    "Cmd": ["/sbin/vminitd"]
  }
}
EOF
)

CONFIG_FILE="$VMINIT_DIR/config.json"
echo "$CONFIG_JSON" > "$CONFIG_FILE"
CONFIG_DIGEST=$(shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')
CONFIG_SIZE=$(stat -f%z "$CONFIG_FILE")
mv "$CONFIG_FILE" "$OCI_DIR/blobs/sha256/$CONFIG_DIGEST"

# Create manifest
MANIFEST_JSON=$(cat <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:$CONFIG_DIGEST",
    "size": $CONFIG_SIZE
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar",
      "digest": "sha256:$LAYER_DIGEST",
      "size": $LAYER_SIZE
    }
  ]
}
EOF
)

MANIFEST_FILE="$VMINIT_DIR/manifest.json"
echo "$MANIFEST_JSON" > "$MANIFEST_FILE"
MANIFEST_DIGEST=$(shasum -a 256 "$MANIFEST_FILE" | awk '{print $1}')
mv "$MANIFEST_FILE" "$OCI_DIR/blobs/sha256/$MANIFEST_DIGEST"

# Create index with "arca-vminit:latest" tag
INDEX_JSON=$(cat <<EOF
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:$MANIFEST_DIGEST",
      "size": $(stat -f%z "$OCI_DIR/blobs/sha256/$MANIFEST_DIGEST"),
      "annotations": {
        "org.opencontainers.image.ref.name": "arca-vminit:latest"
      }
    }
  ]
}
EOF
)

echo "$INDEX_JSON" > "$OCI_DIR/index.json"

# Clean up temp files
rm -rf "$TEMP_ROOTFS" "$ROOTFS_TAR"

# Move OCI layout contents to vminit directory root
# OCI layout is currently at $VMINIT_DIR/oci/, we want it at $VMINIT_DIR/
mv "$OCI_DIR"/* "$VMINIT_DIR/"
rmdir "$OCI_DIR"

echo ""
echo "========================================"
echo "✓ arca-vminit:latest built successfully"
echo "========================================"
echo ""
echo "OCI image location: $VMINIT_DIR"
echo ""
echo "Contents:"
echo "  /sbin/vminitd            - Init system (PID 1)"
echo "  /sbin/vmexec             - Exec helper"
echo "  /sbin/arca-tap-forwarder - TAP forwarder (auto-started on boot, vsock:5555)"
echo "  /sbin/arca-embedded-dns  - Embedded DNS resolver (127.0.0.11:53, auto-started on boot)"
echo "  + Swift runtime and system libraries (via cctl)"
echo ""
echo "This image will be loaded as 'arca-vminit:latest' and used by all containers."
echo "Restart Arca daemon to pick up the new vminit image."
