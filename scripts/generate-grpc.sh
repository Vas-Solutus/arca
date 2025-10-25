#!/bin/bash
set -e

echo "========================================"
echo "Generating gRPC code from proto files"
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Proto file locations
CONTROL_API_PROTO="$PROJECT_ROOT/helpervm/proto/network.proto"
ROUTER_SERVICE_PROTO="$PROJECT_ROOT/helpervm/router-service/proto/router.proto"
VLAN_SERVICE_PROTO="$PROJECT_ROOT/vminitd/vminitd/extensions/vlan-service/proto/network.proto"

# Output directories
SWIFT_OUTPUT_DIR="$PROJECT_ROOT/Sources/ContainerBridge/Generated"
CONTROL_API_GO_DIR="$PROJECT_ROOT/helpervm/control-api/proto"
ROUTER_SERVICE_GO_DIR="$PROJECT_ROOT/helpervm/router-service/proto"
VLAN_SERVICE_GO_DIR="$PROJECT_ROOT/vminitd/vminitd/extensions/vlan-service/proto"

# Create output directories
mkdir -p "$SWIFT_OUTPUT_DIR/ControlAPI"
mkdir -p "$SWIFT_OUTPUT_DIR/RouterService"
mkdir -p "$SWIFT_OUTPUT_DIR/VLANService"

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
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR/ControlAPI" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR/ControlAPI"
    echo "  ✓ Generated Swift code in $SWIFT_OUTPUT_DIR/ControlAPI"
else
    echo "  ⚠ Skipping - proto file not found: $CONTROL_API_PROTO"
fi

# Generate Swift code for Router Service
echo ""
echo "→ Generating Swift code for Router Service..."
if [ -f "$ROUTER_SERVICE_PROTO" ]; then
    protoc "$ROUTER_SERVICE_PROTO" \
        --proto_path="$(dirname "$ROUTER_SERVICE_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR/RouterService" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR/RouterService"
    echo "  ✓ Generated Swift code in $SWIFT_OUTPUT_DIR/RouterService"
else
    echo "  ⚠ Skipping - proto file not found: $ROUTER_SERVICE_PROTO"
fi

# Generate Swift code for VLAN Service
echo ""
echo "→ Generating Swift code for VLAN Service..."
if [ -f "$VLAN_SERVICE_PROTO" ]; then
    protoc "$VLAN_SERVICE_PROTO" \
        --proto_path="$(dirname "$VLAN_SERVICE_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR/VLANService" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR/VLANService"
    echo "  ✓ Generated Swift code in $SWIFT_OUTPUT_DIR/VLANService"
else
    echo "  ⚠ Skipping - proto file not found: $VLAN_SERVICE_PROTO"
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

# Generate Go code for Router Service
echo ""
echo "→ Generating Go code for Router Service..."
if [ -f "$ROUTER_SERVICE_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$ROUTER_SERVICE_PROTO" \
        --proto_path="$(dirname "$ROUTER_SERVICE_PROTO")" \
        --go_out="$ROUTER_SERVICE_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$ROUTER_SERVICE_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $ROUTER_SERVICE_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

# Generate Go code for VLAN Service
echo ""
echo "→ Generating Go code for VLAN Service..."
if [ -f "$VLAN_SERVICE_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$VLAN_SERVICE_PROTO" \
        --proto_path="$(dirname "$VLAN_SERVICE_PROTO")" \
        --go_out="$VLAN_SERVICE_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$VLAN_SERVICE_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $VLAN_SERVICE_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

echo ""
echo "========================================"
echo "✓ gRPC code generation complete"
echo "========================================"
