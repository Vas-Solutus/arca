#!/bin/bash
set -e

echo "========================================"
echo "Generating gRPC code from proto files"
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Proto file locations
CONTROL_API_PROTO="$PROJECT_ROOT/helpervm/proto/network.proto"

# Output directories
SWIFT_OUTPUT_DIR="$PROJECT_ROOT/Sources/ContainerBridge/Generated"
CONTROL_API_GO_DIR="$PROJECT_ROOT/helpervm/control-api/proto"

# Create output directory
mkdir -p "$SWIFT_OUTPUT_DIR"

# Clean up old subdirectory structure (files are now in root with prefixed names)
rm -rf "$SWIFT_OUTPUT_DIR/ControlAPI"

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

# Generate Swift code for Control API (helpervm/proto/network.proto)
echo ""
echo "→ Generating Swift code for Control API..."
if [ -f "$CONTROL_API_PROTO" ]; then
    protoc "$CONTROL_API_PROTO" \
        --proto_path="$(dirname "$CONTROL_API_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR"

    # Rename to avoid filename conflicts (both control_api and vlan_service use network.proto)
    mv "$SWIFT_OUTPUT_DIR/network.pb.swift" "$SWIFT_OUTPUT_DIR/control_api.pb.swift"
    mv "$SWIFT_OUTPUT_DIR/network.grpc.swift" "$SWIFT_OUTPUT_DIR/control_api.grpc.swift"

    echo "  ✓ Generated Swift code: control_api.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - proto file not found: $CONTROL_API_PROTO"
fi

# Generate Go code for Control API
echo ""
echo "→ Generating Go code for Control API..."
if [ -f "$CONTROL_API_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$CONTROL_API_PROTO" \
        --proto_path="$(dirname "$CONTROL_API_PROTO")" \
        --go_out="$CONTROL_API_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$CONTROL_API_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $CONTROL_API_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

# Generate Swift code for TAP Forwarder (containerization/vminitd/extensions/tap-forwarder/proto/tapforwarder.proto)
echo ""
echo "→ Generating Swift code for TAP Forwarder..."
TAP_FORWARDER_PROTO="$PROJECT_ROOT/containerization/vminitd/extensions/tap-forwarder/proto/tapforwarder.proto"
if [ -f "$TAP_FORWARDER_PROTO" ]; then
    protoc "$TAP_FORWARDER_PROTO" \
        --proto_path="$(dirname "$TAP_FORWARDER_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR"
    echo "  ✓ Generated Swift code: tapforwarder.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - proto file not found: $TAP_FORWARDER_PROTO"
fi

echo ""
echo "========================================"
echo "✓ gRPC code generation complete"
echo "========================================"
