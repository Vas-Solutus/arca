#!/bin/bash
set -e

echo "Generating Swift gRPC code from proto..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
PROTO_FILE="$PROJECT_ROOT/helpervm/proto/network.proto"
OUTPUT_DIR="$PROJECT_ROOT/Sources/ContainerBridge/Generated"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo "ERROR: protoc not found. Please install protobuf compiler:"
    echo "  brew install protobuf"
    exit 1
fi

# Check if Swift protoc plugins are installed
if ! command -v protoc-gen-swift &> /dev/null; then
    echo "ERROR: protoc-gen-swift not found. Please install swift-protobuf:"
    echo "  brew install swift-protobuf"
    exit 1
fi

if ! command -v protoc-gen-grpc-swift &> /dev/null; then
    echo "ERROR: protoc-gen-grpc-swift not found."
    echo ""
    echo "This project requires protoc-gen-grpc-swift v1.27.0 (must match grpc-swift dependency)."
    echo "Install it with:"
    echo "  make install-grpc-plugin"
    exit 1
fi

# Generate Swift code
echo "Generating Swift protobuf and gRPC code..."
protoc "$PROTO_FILE" \
    --proto_path="$(dirname "$PROTO_FILE")" \
    --swift_out=Visibility=Public:"$OUTPUT_DIR" \
    --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$OUTPUT_DIR"

echo "✓ Generated Swift code in $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"
