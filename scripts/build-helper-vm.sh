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
mkdir -p "$HELPERVM_DIR/control-api/proto"
cd "$HELPERVM_DIR/proto"
protoc --go_out=../control-api/proto --go_opt=paths=source_relative \
    --go-grpc_out=../control-api/proto --go-grpc_opt=paths=source_relative \
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

# Step 3: Create temporary container and export filesystem
echo "Step 3: Creating temporary container and exporting filesystem..."
TEMP_TAR="$OUTPUT_DIR/helpervm-temp.tar"

# Create a temporary container from the image (doesn't start it)
TEMP_CONTAINER=$($BUILDER create "$IMAGE_NAME:$IMAGE_TAG")
echo "Created temporary container: $TEMP_CONTAINER"

# Export the container's filesystem (this gets the merged filesystem, not layers)
$BUILDER export "$TEMP_CONTAINER" -o "$TEMP_TAR"

# Remove temporary container
$BUILDER rm "$TEMP_CONTAINER"

# Step 4: Extract filesystem from tar
echo "Step 4: Extracting filesystem..."
TEMP_EXTRACT="$OUTPUT_DIR/extract"
mkdir -p "$TEMP_EXTRACT"
cd "$TEMP_EXTRACT"
tar -xf "$TEMP_TAR"

# Step 5: Create raw disk image using Docker (macOS doesn't have ext4 tools)
echo "Step 5: Creating raw disk image..."
DISK_IMAGE="$OUTPUT_DIR/disk.img"
DISK_SIZE="500M"

# Create empty disk image
dd if=/dev/zero of="$DISK_IMAGE" bs=1M count=500 status=progress

# Use Docker to create ext4 filesystem and copy files
# We need Linux tools (mkfs.ext4, mount) which don't exist on macOS
echo "Creating ext4 filesystem and copying files using Docker..."
$BUILDER run --rm --privileged \
    -v "$DISK_IMAGE:/disk.img" \
    -v "$TEMP_EXTRACT:/rootfs:ro" \
    alpine:3.22 \
    sh -c '
        # Install ext4 tools
        apk add --no-cache e2fsprogs

        # Create ext4 filesystem
        mkfs.ext4 -F /disk.img

        # Mount disk image
        mkdir -p /mnt
        mount -o loop /disk.img /mnt

        # Copy filesystem contents
        cp -a /rootfs/* /mnt/ || true

        # Unmount
        umount /mnt

        echo "Disk image creation complete"
    '

# Cleanup
rm -rf "$TEMP_EXTRACT" "$TEMP_TAR"

echo "Helper VM disk image created at: $DISK_IMAGE"
echo "Image size: $(du -h "$DISK_IMAGE" | cut -f1)"
echo ""
echo "Build complete!"
