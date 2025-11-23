#!/bin/bash
# Switch to the Arca buildx builder with default-load=true

set -e

echo "Configuring Arca buildx builder..."

# Check if arca builder exists
if docker buildx inspect arca >/dev/null 2>&1; then
    echo "✓ Arca builder already exists"
else
    echo "Creating arca builder with default-load=true..."
    docker buildx create \
        --name arca \
        --driver docker-container \
        --driver-opt default-load=true \
        --driver-opt network=host
    echo "✓ Arca builder created"
fi

# Make it the default builder
echo "Setting arca as default builder..."
docker buildx use arca

echo ""
echo "✓ Arca builder is now active!"
echo ""
echo "You can now run 'docker build' and images will automatically load."
echo "No need for --load flag anymore."
echo ""
echo "To switch back to default builder, run: ./scripts/use-default-builder.sh"
