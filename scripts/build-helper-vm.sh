#!/bin/bash
set -e

echo "Building Arca Network Helper VM..."

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HELPERVM_DIR="$PROJECT_ROOT/helpervm"
OUTPUT_DIR="$HOME/.arca/helpervm"
IMAGE_NAME="arca-helpervm"
IMAGE_TAG="latest"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Step 1: Generate gRPC code from proto
echo "Step 1: Generating gRPC code from proto..."
cd "$HELPERVM_DIR/proto"
protoc --go_out=../control-api --go_opt=paths=source_relative \
    --go-grpc_out=../control-api --go-grpc_opt=paths=source_relative \
    network.proto

# Step 2: Build Docker/OCI image
echo "Step 2: Building OCI image..."
cd "$HELPERVM_DIR"

# Use Docker if available, otherwise podman
if command -v docker &> /dev/null; then
    BUILDER="docker"
elif command -v podman &> /dev/null; then
    BUILDER="podman"
else
    echo "ERROR: Neither docker nor podman found. Please install one of them."
    exit 1
fi

echo "Using builder: $BUILDER"

$BUILDER build -t "$IMAGE_NAME:$IMAGE_TAG" .

# Step 3: Export image to tar
echo "Step 3: Exporting image to tar..."
TEMP_TAR="$OUTPUT_DIR/helpervm-temp.tar"
$BUILDER save -o "$TEMP_TAR" "$IMAGE_NAME:$IMAGE_TAG"

# Step 4: Extract filesystem from tar
echo "Step 4: Extracting filesystem..."
TEMP_EXTRACT="$OUTPUT_DIR/extract"
mkdir -p "$TEMP_EXTRACT"
cd "$TEMP_EXTRACT"
tar -xf "$TEMP_TAR"

# Find the layer tars and extract them in order
for layer in $(find . -name 'layer.tar' | sort); do
    echo "Extracting layer: $layer"
    tar -xf "$layer" -C .
done

# Step 5: Create raw disk image
echo "Step 5: Creating raw disk image..."
DISK_IMAGE="$OUTPUT_DIR/disk.img"
DISK_SIZE="500M"

# Create empty disk image
dd if=/dev/zero of="$DISK_IMAGE" bs=1M count=500 status=progress

# Create ext4 filesystem
mkfs.ext4 -F "$DISK_IMAGE"

# Mount and copy files
MOUNT_POINT="$OUTPUT_DIR/mnt"
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$DISK_IMAGE" "$MOUNT_POINT"

# Copy filesystem
sudo cp -a "$TEMP_EXTRACT"/* "$MOUNT_POINT/" || true

# Unmount
sudo umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"

# Cleanup
rm -rf "$TEMP_EXTRACT" "$TEMP_TAR"

echo "Helper VM disk image created at: $DISK_IMAGE"
echo "Image size: $(du -h "$DISK_IMAGE" | cut -f1)"
echo ""
echo "Build complete!"
