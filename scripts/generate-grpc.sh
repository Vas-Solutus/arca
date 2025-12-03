#!/bin/bash
set -e

echo "========================================"
echo "Generating gRPC code from proto files"
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Proto file locations (all in arca-services now)
ARCA_SERVICES_DIR="$PROJECT_ROOT/containerization/vminitd/extensions/arca-services"

# Output directories
SWIFT_OUTPUT_DIR="$PROJECT_ROOT/Sources/ContainerBridge/Generated"
PROCESS_SWIFT_DIR="$PROJECT_ROOT/Sources/ContainerBridge/Process/Generated"

# Create output directories
mkdir -p "$SWIFT_OUTPUT_DIR"
mkdir -p "$PROCESS_SWIFT_DIR"

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

# ============================================================================
# WireGuard Service
# ============================================================================
WG_PROTO="$ARCA_SERVICES_DIR/proto/wireguard/wireguard.proto"
WG_GO_DIR="$ARCA_SERVICES_DIR/proto/wireguard"

echo ""
echo "→ Generating Swift code for WireGuard Service..."
if [ -f "$WG_PROTO" ]; then
    protoc "$WG_PROTO" \
        --proto_path="$(dirname "$WG_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR"
    echo "  ✓ Generated Swift code: wireguard.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - proto file not found: $WG_PROTO"
fi

echo ""
echo "→ Generating Go code for WireGuard Service..."
if [ -f "$WG_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$WG_PROTO" \
        --proto_path="$(dirname "$WG_PROTO")" \
        --go_out="$WG_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$WG_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $WG_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

# ============================================================================
# Filesystem Service
# ============================================================================
FS_PROTO="$ARCA_SERVICES_DIR/proto/filesystem/filesystem.proto"
FS_GO_DIR="$ARCA_SERVICES_DIR/proto/filesystem"

echo ""
echo "→ Generating Swift code for Filesystem Service..."
if [ -f "$FS_PROTO" ]; then
    protoc "$FS_PROTO" \
        --proto_path="$(dirname "$FS_PROTO")" \
        --swift_out=Visibility=Public:"$SWIFT_OUTPUT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$SWIFT_OUTPUT_DIR"
    echo "  ✓ Generated Swift code: filesystem.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - proto file not found: $FS_PROTO"
fi

echo ""
echo "→ Generating Go code for Filesystem Service..."
if [ -f "$FS_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$FS_PROTO" \
        --proto_path="$(dirname "$FS_PROTO")" \
        --go_out="$FS_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$FS_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $FS_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

# ============================================================================
# Process Service
# ============================================================================
PROC_PROTO="$ARCA_SERVICES_DIR/proto/process/process.proto"
PROC_GO_DIR="$ARCA_SERVICES_DIR/proto/process"

echo ""
echo "→ Generating Swift code for Process Service..."
if [ -f "$PROC_PROTO" ]; then
    protoc "$PROC_PROTO" \
        --proto_path="$(dirname "$PROC_PROTO")" \
        --swift_out=Visibility=Public:"$PROCESS_SWIFT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$PROCESS_SWIFT_DIR"
    echo "  ✓ Generated Swift code: process.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - proto file not found: $PROC_PROTO"
fi

echo ""
echo "→ Generating Go code for Process Service..."
if [ -f "$PROC_PROTO" ] && command -v protoc-gen-go &> /dev/null && command -v protoc-gen-go-grpc &> /dev/null; then
    protoc "$PROC_PROTO" \
        --proto_path="$(dirname "$PROC_PROTO")" \
        --go_out="$PROC_GO_DIR" \
        --go_opt=paths=source_relative \
        --go-grpc_out="$PROC_GO_DIR" \
        --go-grpc_opt=paths=source_relative
    echo "  ✓ Generated Go code in $PROC_GO_DIR"
else
    echo "  ⚠ Skipping - proto file or Go plugins not found"
fi

echo ""
echo "========================================"
echo "✓ gRPC code generation complete"
echo "========================================"
