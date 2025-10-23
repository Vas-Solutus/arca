#!/bin/bash
# Generate Swift gRPC code from tapforwarder.proto

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROTO_DIR="$PROJECT_ROOT/arca-tap-forwarder/proto"
OUTPUT_DIR="$PROJECT_ROOT/arca-tap-forwarder/Sources/arca-tap-forwarder/Generated"

echo "=== Generating Swift gRPC code for TAP Forwarder ==="
echo

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo "ERROR: protoc not found"
    echo "Install with: brew install protobuf"
    exit 1
fi

# Check if protoc-gen-swift is installed
if ! command -v protoc-gen-swift &> /dev/null; then
    echo "ERROR: protoc-gen-swift not found"
    echo "Install with: brew install swift-protobuf"
    exit 1
fi

# Check if protoc-gen-grpc-swift is installed
if ! command -v protoc-gen-grpc-swift &> /dev/null; then
    echo "ERROR: protoc-gen-grpc-swift not found"
    echo "Run: make install-grpc-plugin"
    exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate Swift code
echo "→ Generating Swift protobuf and gRPC code..."
cd "$PROTO_DIR"

protoc tapforwarder.proto \
    --swift_out="$OUTPUT_DIR" \
    --grpc-swift_out="$OUTPUT_DIR"

echo "  ✓ Generated: $OUTPUT_DIR/tapforwarder.pb.swift"
echo "  ✓ Generated: $OUTPUT_DIR/tapforwarder.grpc.swift"

echo
echo "=== Code generation complete ==="
