#!/bin/bash
# Build router-service for Linux ARM64 (cross-compile from macOS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR}"

echo "=== Building Router service for Linux ARM64 ==="
echo

cd "$SCRIPT_DIR"

# Download dependencies
echo "→ Downloading Go dependencies..."
go mod download

# Cross-compile for Linux ARM64
echo "→ Building router-service for Linux (arm64)..."
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build \
    -o "$OUTPUT_DIR/router-service" \
    -ldflags="-s -w" \
    .

if [ ! -f "$OUTPUT_DIR/router-service" ]; then
    echo "ERROR: Build completed but binary not found"
    exit 1
fi

# Show binary info
echo "  ✓ Built: $OUTPUT_DIR/router-service"
file "$OUTPUT_DIR/router-service" 2>/dev/null || echo "  (file command not available)"
ls -lh "$OUTPUT_DIR/router-service"

echo
echo "=== Build Complete ==="
echo
echo "The router-service binary is ready for deployment in the helper VM."
