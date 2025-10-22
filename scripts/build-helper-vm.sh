#!/bin/bash
set -e

echo "Building Arca Network Helper VM..."

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
HELPERVM_DIR="$PROJECT_ROOT/helpervm"
OUTPUT_DIR="$HOME/.arca/helpervm"
IMAGE_NAME="arca-network-helper"
IMAGE_TAG="latest"
OCI_LAYOUT_DIR="$OUTPUT_DIR/oci-layout"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Clean and recreate OCI layout directory
if [ -d "$OCI_LAYOUT_DIR" ]; then
    echo "Removing existing OCI layout directory..."
    rm -rf "$OCI_LAYOUT_DIR"
fi
mkdir -p "$OCI_LAYOUT_DIR"

# Step 1: Generate gRPC code from proto
echo "Step 1: Generating gRPC code from proto..."
mkdir -p "$HELPERVM_DIR/control-api/proto"
cd "$HELPERVM_DIR/proto"
protoc --go_out=../control-api/proto --go_opt=paths=source_relative \
    --go-grpc_out=../control-api/proto --go-grpc_opt=paths=source_relative \
    network.proto

# Step 2: Build OCI image
echo "Step 2: Building OCI image..."
cd "$HELPERVM_DIR"

# Determine which builder to use
if command -v docker &> /dev/null; then
    BUILDER="docker"
elif command -v podman &> /dev/null; then
    BUILDER="podman"
else
    echo "ERROR: Neither docker nor podman found. Please install one of them."
    exit 1
fi

echo "Using builder: $BUILDER"

# Build the image
$BUILDER build -t "$IMAGE_NAME:$IMAGE_TAG" .

# Detect Docker socket path for skopeo
DOCKER_SOCKET=""
if [ "$BUILDER" = "docker" ]; then
    # Get the active docker context endpoint
    DOCKER_ENDPOINT=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "")
    if [ -n "$DOCKER_ENDPOINT" ]; then
        # Strip the unix:// prefix to get the socket path
        DOCKER_SOCKET="${DOCKER_ENDPOINT#unix://}"
        echo "Detected Docker socket: $DOCKER_SOCKET"
    fi
fi

# Step 3: Save as OCI Image Layout
echo "Step 3: Saving image as OCI Image Layout..."

if command -v skopeo &> /dev/null; then
    # Method 1: Use skopeo (preferred - creates proper OCI layout)
    echo "Using skopeo to export OCI layout..."
    if [ -n "$DOCKER_SOCKET" ] && [ "$BUILDER" = "docker" ]; then
        # Use explicit socket path for non-standard Docker setups (Colima, etc)
        skopeo --insecure-policy copy --src-daemon-host "unix://$DOCKER_SOCKET" \
            "docker-daemon:$IMAGE_NAME:$IMAGE_TAG" "oci:$OCI_LAYOUT_DIR:$IMAGE_TAG"
    else
        # Use default socket path
        skopeo copy "docker-daemon:$IMAGE_NAME:$IMAGE_TAG" "oci:$OCI_LAYOUT_DIR:$IMAGE_TAG"
    fi

elif [ "$BUILDER" = "podman" ]; then
    # Method 2: Use podman push to OCI layout
    echo "Using podman to export OCI layout..."
    podman push "$IMAGE_NAME:$IMAGE_TAG" "oci:$OCI_LAYOUT_DIR:$IMAGE_TAG"
fi

# Fix index.json for Apple Containerization framework compatibility
echo "Fixing index.json for Apple Containerization framework..."
INDEX_FILE="$OCI_LAYOUT_DIR/index.json"
if [ -f "$INDEX_FILE" ]; then
    # Use python to:
    # 1. Add mediaType field to the index
    # 2. Fix the image reference annotation to include image name
    python3 -c "
import json
with open('$INDEX_FILE', 'r') as f:
    data = json.load(f)

# Add mediaType if missing
if 'mediaType' not in data:
    data['mediaType'] = 'application/vnd.oci.image.index.v1+json'

# Fix image reference in manifest annotations
if 'manifests' in data:
    for manifest in data['manifests']:
        if 'annotations' in manifest:
            ref_name = manifest['annotations'].get('org.opencontainers.image.ref.name', '')
            # If ref_name is just a tag (e.g., 'latest'), prepend the image name
            if ref_name and ':' not in ref_name and '/' not in ref_name:
                manifest['annotations']['org.opencontainers.image.ref.name'] = '$IMAGE_NAME:' + ref_name
                print(f\"Fixed image reference: {ref_name} -> $IMAGE_NAME:{ref_name}\")

# Reorder to put mediaType after schemaVersion
ordered_data = {'schemaVersion': data['schemaVersion'], 'mediaType': data['mediaType']}
ordered_data.update({k: v for k, v in data.items() if k not in ['schemaVersion', 'mediaType']})

with open('$INDEX_FILE', 'w') as f:
    json.dump(ordered_data, f, indent=2)
print('index.json fixed for Apple Containerization framework')
"
fi

echo ""
echo "✓ Helper VM OCI image built successfully"
echo "  Image: $IMAGE_NAME:$IMAGE_TAG"
echo "  OCI Layout: $OCI_LAYOUT_DIR"
echo "  Size: $(du -sh "$OCI_LAYOUT_DIR" 2>/dev/null | cut -f1 || echo 'N/A')"
echo ""
echo "Next steps:"
echo "  1. The OCI Image Layout is ready at: $OCI_LAYOUT_DIR"
echo "  2. When Arca daemon starts, NetworkHelperVM will load this into the ImageStore"
echo "  3. The helper VM will be available as: $IMAGE_NAME:$IMAGE_TAG"
echo ""
echo "Build complete!"
