#!/bin/sh
set -e

# Start vsock-to-TCP proxy in background
echo "Starting vsock proxy on port 8088..."
/usr/local/bin/vsock-proxy &
PROXY_PID=$!

# Trap signals to ensure proxy is killed when buildkitd exits
trap "kill $PROXY_PID 2>/dev/null || true" EXIT TERM INT

# Wait a moment for proxy to start listening
sleep 0.5

# Start buildkitd on localhost only (not exposed to network)
echo "Starting buildkitd on 127.0.0.1:8088..."
exec /usr/bin/buildkitd --addr tcp://127.0.0.1:8088 "$@"
