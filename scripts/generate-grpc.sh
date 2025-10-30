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

# Generate Swift code for BuildKit Control API
echo ""
echo "→ Generating Swift code for BuildKit Control API..."
BUILDKIT_PROTO_DIR="$PROJECT_ROOT/Sources/ContainerBuild/proto"
BUILDKIT_OUTPUT_DIR="$PROJECT_ROOT/Sources/ContainerBuild/Generated"

# Create BuildKit output directory
mkdir -p "$BUILDKIT_OUTPUT_DIR"

# List of BuildKit proto files to compile (in dependency order)
BUILDKIT_PROTOS=(
    "$BUILDKIT_PROTO_DIR/google/rpc/status.proto"
    "$BUILDKIT_PROTO_DIR/github.com/moby/buildkit/solver/pb/ops.proto"
    "$BUILDKIT_PROTO_DIR/github.com/moby/buildkit/solver/errdefs/errdefs.proto"
    "$BUILDKIT_PROTO_DIR/github.com/moby/buildkit/sourcepolicy/pb/policy.proto"
    "$BUILDKIT_PROTO_DIR/github.com/moby/buildkit/api/types/worker.proto"
    "$BUILDKIT_PROTO_DIR/github.com/moby/buildkit/api/services/control/control.proto"
)

# Check if all proto files exist
ALL_EXIST=true
for proto in "${BUILDKIT_PROTOS[@]}"; do
    if [ ! -f "$proto" ]; then
        echo "  ⚠ Missing proto file: $proto"
        ALL_EXIST=false
    fi
done

if [ "$ALL_EXIST" = true ]; then
    # Generate Swift code for all BuildKit protos
    # Note: We use --proto_path to point to the root of our vendored proto files
    # so that imports like "github.com/moby/buildkit/..." resolve correctly
    # We also include protoc's default include path for google/protobuf well-known types
    PROTOC_INCLUDE=$(dirname $(dirname $(which protoc)))/include

    # Compile all protos together so imports are resolved
    protoc "${BUILDKIT_PROTOS[@]}" \
        --proto_path="$BUILDKIT_PROTO_DIR" \
        --proto_path="$PROTOC_INCLUDE" \
        --swift_out=Visibility=Public:"$BUILDKIT_OUTPUT_DIR" \
        --grpc-swift_out=Client=true,Server=false,Visibility=Public:"$BUILDKIT_OUTPUT_DIR"

    echo "  ✓ Generated Swift code for BuildKit in $BUILDKIT_OUTPUT_DIR"
    echo "  ✓ Files: ops.pb.swift, errdefs.pb.swift, policy.pb.swift, worker.pb.swift, control.{pb,grpc}.swift"
else
    echo "  ⚠ Skipping - some proto files not found"
fi

echo ""
echo "========================================"
echo "✓ gRPC code generation complete"
echo "========================================"
