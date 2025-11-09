#!/bin/bash
# Setup the Arca buildx builder with default-load=true
# This script waits for the daemon to be ready before creating the builder

set -e

SOCKET_PATH="${DOCKER_HOST:-unix:///tmp/arca.sock}"
SOCKET_PATH="${SOCKET_PATH#unix://}"  # Remove unix:// prefix if present

echo "Waiting for Arca daemon to be ready at ${SOCKET_PATH}..."

# Wait for daemon to be ready (max 30 seconds)
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    if docker version >/dev/null 2>&1; then
        echo "✓ Daemon is ready"
        break
    fi
    WAIT_COUNT=$((WAIT_COUNT + 1))
    if [ $WAIT_COUNT -eq $MAX_WAIT ]; then
        echo "✗ Daemon did not start within ${MAX_WAIT} seconds"
        echo ""
        echo "Please ensure the daemon is running:"
        echo "  make run"
        echo ""
        echo "Or set DOCKER_HOST to the correct socket:"
        echo "  export DOCKER_HOST=unix:///tmp/arca.sock"
        exit 1
    fi
    sleep 1
done

# Now set up the builder
echo ""
echo "Setting up Arca buildx builder..."

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
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Arca buildx builder is now configured!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "You can now run 'docker buildx build' and images will"
echo "automatically load into your local Docker images."
echo ""
echo "No need for the --load flag anymore!"
echo ""
echo "To switch back to default builder:"
echo "  ./scripts/use-default-builder.sh"
echo ""
