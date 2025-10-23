#!/bin/sh
# Arca Networking Initialization Script
# Auto-starts arca-tap-forwarder daemon in container init system
# This script is executed by vminit on container startup

# Launch arca-tap-forwarder in background
/sbin/arca-tap-forwarder &

# Store PID for potential cleanup
echo $! > /run/arca-tap-forwarder.pid

exit 0
