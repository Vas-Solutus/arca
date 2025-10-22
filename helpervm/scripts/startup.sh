#!/bin/bash
set -e

STARTUP_START=$(date +%s)
echo "========================================================"
echo "Arca Network Helper VM Starting..."
echo "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================================"

# Initialize Open vSwitch
OVS_INIT_START=$(date +%s)
/usr/local/bin/ovs-init.sh
OVS_INIT_END=$(date +%s)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] OVS initialization completed in $((OVS_INIT_END - OVS_INIT_START))s"

# Initialize OVN databases
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing OVN databases..."
mkdir -p /var/run/ovn
mkdir -p /var/log/ovn

# Create OVN northbound database if it doesn't exist
if [ ! -f /etc/ovn/ovnnb_db.db ]; then
    echo "Creating OVN northbound database..."
    mkdir -p /etc/ovn
    ovsdb-tool create /etc/ovn/ovnnb_db.db /usr/share/ovn/ovn-nb.ovsschema
fi

# Create OVN southbound database if it doesn't exist
if [ ! -f /etc/ovn/ovnsb_db.db ]; then
    echo "Creating OVN southbound database..."
    ovsdb-tool create /etc/ovn/ovnsb_db.db /usr/share/ovn/ovn-sb.ovsschema
fi

# Start OVN northbound database server
echo "Starting OVN northbound database..."
ovsdb-server --remote=punix:/var/run/ovn/ovnnb_db.sock \
    --remote=db:OVN_Northbound,NB_Global,connections \
    --pidfile=/var/run/ovn/ovnnb_db.pid \
    --detach --log-file=/var/log/ovn/ovsdb-server-nb.log \
    /etc/ovn/ovnnb_db.db

# Start OVN southbound database server
echo "Starting OVN southbound database..."
ovsdb-server --remote=punix:/var/run/ovn/ovnsb_db.sock \
    --remote=db:OVN_Southbound,SB_Global,connections \
    --pidfile=/var/run/ovn/ovnsb_db.pid \
    --detach --log-file=/var/log/ovn/ovsdb-server-sb.log \
    /etc/ovn/ovnsb_db.db

# Wait for OVN databases to be ready
sleep 2

# Initialize OVN northbound if needed
echo "Initializing OVN northbound..."
ovn-nbctl init || true

# Initialize OVN southbound if needed
echo "Initializing OVN southbound..."
ovn-sbctl init || true

# Configure OVN integration bridge with netdev datapath (userspace)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Configuring OVN integration bridge for userspace datapath..."

# Delete any existing br-int first
ovs-vsctl --if-exists del-br br-int

# Retry bridge creation with exponential backoff
# OVS may need time to fully initialize its datapath subsystem
MAX_RETRIES=5
RETRY_COUNT=0
RETRY_DELAY=1

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES: Creating br-int with netdev datapath..."

    # Try to create the bridge (may fail initially while OVS initializes)
    ovs-vsctl add-br br-int -- set bridge br-int datapath_type=netdev 2>&1 || true

    # Wait a moment for the operation to complete
    sleep 1

    # Check if bridge actually exists with correct datapath type
    if ovs-vsctl list bridge br-int 2>/dev/null | grep -q "datapath_type.*netdev"; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ br-int created successfully with netdev datapath"
        ovs-vsctl set bridge br-int fail-mode=secure
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ br-int configured with fail-mode=secure"
        break
    else
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✗ Bridge not ready yet, retrying in ${RETRY_DELAY}s..."
            ovs-vsctl --if-exists del-br br-int  # Clean up before retry
            sleep $RETRY_DELAY
            RETRY_DELAY=$((RETRY_DELAY * 2))  # Exponential backoff
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to create br-int after $MAX_RETRIES attempts"
            echo "OVS logs:"
            tail -50 /var/log/openvswitch/ovs-vswitchd.log
            exit 1
        fi
    fi
done

# Start OVN controller
echo "Starting OVN controller..."
ovn-controller --pidfile=/var/run/ovn/ovn-controller.pid \
    --detach --log-file=/var/log/ovn/ovn-controller.log \
    unix:/var/run/openvswitch/db.sock

# Start dnsmasq
echo "Starting dnsmasq..."
mkdir -p /etc/dnsmasq.d
dnsmasq --conf-file=/etc/dnsmasq.conf &

# Wait for services to be ready
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for all services to stabilize..."
sleep 2

STARTUP_END=$(date +%s)
TOTAL_STARTUP=$((STARTUP_END - STARTUP_START))
echo "========================================================"
echo "✓ All services started successfully"
echo "✓ Total startup time: ${TOTAL_STARTUP}s"
echo "========================================================"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Arca Network Control API..."

# Start the control API server (foreground - this keeps the container running)
# Uses mdlayher/vsock library for proper vsock net.Listener support
exec /usr/local/bin/arca-network-api --vsock-port=9999
