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
VMINITD_DIR="$PROJECT_ROOT/vminitd"

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

# Build VLAN service (Go binary cross-compiled to Linux)
echo ""
echo "→ Building VLAN service (Go → Linux ARM64)..."
cd "$VMINITD_DIR/vminitd/extensions/vlan-service"

if [ ! -f build.sh ]; then
    echo "ERROR: vlan-service/build.sh not found"
    exit 1
fi

./build.sh

if [ ! -f vlan-service ]; then
    echo "ERROR: vlan-service binary not built"
    exit 1
fi

echo "  ✓ VLAN service built: vlan-service"

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

# Build vminitd (Swift cross-compiled to Linux)
echo ""
echo "→ Building vminitd (Swift → Linux ARM64)..."
cd "$VMINITD_DIR/vminitd"

# Use vminitd's Makefile to build for Linux (builds both vminitd and vmexec)
BUILD_CONFIGURATION=release make all

VMINITD_BINARY="$VMINITD_DIR/vminitd/.build/aarch64-unknown-linux-musl/release/vminitd"
VMEXEC_BINARY="$VMINITD_DIR/vminitd/.build/aarch64-unknown-linux-musl/release/vmexec"

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

# Create OCI image layout
echo ""
echo "→ Creating OCI image layout..."

OCI_DIR="$HOME/.arca/vminit"
ROOTFS_DIR="$OCI_DIR/rootfs"

# Clean and recreate directories
rm -rf "$OCI_DIR"
mkdir -p "$ROOTFS_DIR/sbin"
mkdir -p "$ROOTFS_DIR/usr/local/bin"

# Copy binaries to rootfs
echo "  Copying vminitd → /sbin/vminitd"
cp "$VMINITD_BINARY" "$ROOTFS_DIR/sbin/vminitd"
chmod +x "$ROOTFS_DIR/sbin/vminitd"

echo "  Copying vmexec → /sbin/vmexec"
cp "$VMEXEC_BINARY" "$ROOTFS_DIR/sbin/vmexec"
chmod +x "$ROOTFS_DIR/sbin/vmexec"

echo "  Copying vlan-service → /usr/local/bin/vlan-service"
cp "$VMINITD_DIR/vminitd/extensions/vlan-service/vlan-service" "$ROOTFS_DIR/usr/local/bin/vlan-service"
chmod +x "$ROOTFS_DIR/usr/local/bin/vlan-service"

echo "  Copying arca-tap-forwarder → /usr/local/bin/arca-tap-forwarder"
cp "$VMINITD_DIR/vminitd/extensions/tap-forwarder/arca-tap-forwarder" "$ROOTFS_DIR/usr/local/bin/arca-tap-forwarder"
chmod +x "$ROOTFS_DIR/usr/local/bin/arca-tap-forwarder"

# Create OCI image manifest
echo "  Creating OCI manifest..."

cat > "$OCI_DIR/oci-layout" <<EOF
{
  "imageLayoutVersion": "1.0.0"
}
EOF

mkdir -p "$OCI_DIR/blobs/sha256"

# Create layer tarball
echo "  Creating layer tarball..."
LAYER_TAR="$OCI_DIR/layer.tar"
tar -C "$ROOTFS_DIR" -cf "$LAYER_TAR" .

# Calculate layer digest
LAYER_DIGEST=$(shasum -a 256 "$LAYER_TAR" | awk '{print $1}')
LAYER_SIZE=$(stat -f%z "$LAYER_TAR")
mv "$LAYER_TAR" "$OCI_DIR/blobs/sha256/$LAYER_DIGEST"

echo "  Layer digest: sha256:$LAYER_DIGEST"
echo "  Layer size: $LAYER_SIZE bytes"

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

CONFIG_FILE="$OCI_DIR/config.json"
echo "$CONFIG_JSON" > "$CONFIG_FILE"
CONFIG_DIGEST=$(shasum -a 256 "$CONFIG_FILE" | awk '{print $1}')
CONFIG_SIZE=$(stat -f%z "$CONFIG_FILE")
mv "$CONFIG_FILE" "$OCI_DIR/blobs/sha256/$CONFIG_DIGEST"

echo "  Config digest: sha256:$CONFIG_DIGEST"

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

MANIFEST_FILE="$OCI_DIR/manifest.json"
echo "$MANIFEST_JSON" > "$MANIFEST_FILE"
MANIFEST_DIGEST=$(shasum -a 256 "$MANIFEST_FILE" | awk '{print $1}')
mv "$MANIFEST_FILE" "$OCI_DIR/blobs/sha256/$MANIFEST_DIGEST"

echo "  Manifest digest: sha256:$MANIFEST_DIGEST"

# Create index pointing to manifest with "latest" tag
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
        "org.opencontainers.image.ref.name": "latest"
      }
    }
  ]
}
EOF
)

echo "$INDEX_JSON" > "$OCI_DIR/index.json"

# Clean up rootfs (no longer needed)
rm -rf "$ROOTFS_DIR"

echo ""
echo "========================================"
echo "✓ vminit:latest built successfully"
echo "========================================"
echo ""
echo "OCI image location: $OCI_DIR"
echo ""
echo "Contents:"
echo "  /sbin/vminitd              - Init system (PID 1)"
echo "  /sbin/vmexec               - Exec helper"
echo "  /usr/local/bin/vlan-service       - VLAN configuration (vsock:50051)"
echo "  /usr/local/bin/arca-tap-forwarder - TAP forwarder (legacy)"
echo ""
echo "This image will be used automatically by all containers."
echo "Restart Arca daemon to pick up the new vminit image."
