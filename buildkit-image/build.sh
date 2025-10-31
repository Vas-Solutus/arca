#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="arca/buildkit:latest"

echo "Building custom BuildKit image with vsock proxy..."

# Build the image
docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"

echo "✅ Custom BuildKit image built: $IMAGE_NAME"
echo ""
echo "The image includes:"
echo "  - Official moby/buildkit:latest as base"
echo "  - vsock-to-TCP proxy listening on vsock port 8088"
echo "  - buildkitd listening on 127.0.0.1:8088 (localhost only)"
echo ""
echo "Connection flow: Host → vsock:8088 → proxy → localhost:8088 → buildkitd"
