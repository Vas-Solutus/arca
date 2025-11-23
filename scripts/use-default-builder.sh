#!/bin/bash
# Switch back to the default buildx builder

set -e

echo "Switching to default buildx builder..."

# Switch to default builder
docker buildx use default

echo ""
echo "✓ Default builder is now active!"
echo ""
echo "Note: With the default builder, you'll need to use --load flag"
echo "to import built images into your local Docker images."
echo ""
echo "Example: docker buildx build -t myimage . --load"
echo ""
echo "To switch back to Arca builder, run: ./scripts/use-arca-builder.sh"
