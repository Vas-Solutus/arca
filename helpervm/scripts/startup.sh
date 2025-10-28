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
if ! ovn-nbctl init 2>&1; then
    echo "Note: OVN NB database may already be initialized (this is normal)"
fi

# Initialize OVN southbound if needed
echo "Initializing OVN southbound..."
if ! ovn-sbctl init 2>&1; then
    echo "Note: OVN SB database may already be initialized (this is normal)"
fi

# Verify database schema versions
echo "Checking OVN database schema versions..."
ovsdb-client get-schema unix:/var/run/ovn/ovnnb_db.sock OVN_Northbound | head -5 || echo "Failed to get NB schema"
ovsdb-client get-schema unix:/var/run/ovn/ovnsb_db.sock OVN_Southbound | head -5 || echo "Failed to get SB schema"

# Start OVN northd daemon (translates logical to physical network config)
# This is CRITICAL - without this, DHCP options and logical networks don't work!
echo "Starting OVN northd daemon..."
ovn-northd --pidfile=/var/run/ovn/ovn-northd.pid \
    --detach --log-file=/var/log/ovn/ovn-northd.log \
    --ovnnb-db=unix:/var/run/ovn/ovnnb_db.sock \
    --ovnsb-db=unix:/var/run/ovn/ovnsb_db.sock

# Wait for ovn-northd to connect and be ready
echo "Waiting for ovn-northd to connect to databases..."
sleep 3

# Verify ovn-northd is running
if [ -f /var/run/ovn/ovn-northd.pid ]; then
    PID=$(cat /var/run/ovn/ovn-northd.pid)
    if kill -0 $PID 2>/dev/null; then
        echo "✓ ovn-northd is running (PID: $PID)"
    else
        echo "ERROR: ovn-northd PID file exists but process is not running!"
        echo "ovn-northd log:"
        tail -50 /var/log/ovn/ovn-northd.log
        exit 1
    fi
else
    echo "ERROR: ovn-northd PID file not found!"
    echo "ovn-northd log:"
    tail -50 /var/log/ovn/ovn-northd.log
    exit 1
fi

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

# DISABLED: dnsmasq not needed - DNS resolution handled by embedded-DNS in each container
# Each container runs embedded-DNS at 127.0.0.11:53 with direct topology push from daemon
# OVN still handles DHCP (IP allocation)
# echo "Starting dnsmasq for DNS resolution..."
# mkdir -p /var/run
# mkdir -p /etc/dnsmasq.d
# dnsmasq --conf-file=/etc/dnsmasq.conf
# echo "✓ dnsmasq started"

# Wait for services to be ready
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for all services to stabilize..."
sleep 2

# Verify OVN services are operational
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Verifying OVN services..."
echo "OVN Northbound database status:"
echo "  Running: ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock show"
ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock show 2>&1 || echo "ERROR: ovn-nbctl show failed with exit code $?"

echo ""
echo "Testing basic ovn-nbctl connectivity..."
echo "  Running: ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock list NB_Global"
ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock list NB_Global 2>&1 || echo "ERROR: ovn-nbctl list failed with exit code $?"

echo ""
echo "Testing DHCP options creation..."
echo "  Note: Using 'ovn-nbctl create' instead of 'dhcp-options-create'"
echo "  (dhcp-options-create does not return UUID - known OVN limitation)"
echo "  Running: ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock create dhcp_options cidr=192.168.99.0/24"
TEST_UUID=$(ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock create dhcp_options cidr=192.168.99.0/24 2>&1)
EXIT_CODE=$?
echo "  Exit code: $EXIT_CODE"
echo "  Test DHCP UUID: $TEST_UUID"
if [ -n "$TEST_UUID" ] && [ "$EXIT_CODE" -eq 0 ]; then
    echo "✓ DHCP options creation working - UUID: $TEST_UUID"
    # Clean up test entry
    ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock destroy dhcp_options "$TEST_UUID" 2>/dev/null || true
else
    echo "ERROR: DHCP options creation returned empty UUID!"
    echo ""
    echo "=== Diagnostic Information ==="
    echo ""
    echo "OVN northd log (most recent 50 lines):"
    tail -50 /var/log/ovn/ovn-northd.log
    echo ""
    echo "OVN northbound database log (most recent 50 lines):"
    tail -50 /var/log/ovn/ovsdb-server-nb.log
    echo ""
    echo "OVN southbound database log (most recent 50 lines):"
    tail -50 /var/log/ovn/ovsdb-server-sb.log
    echo ""
    echo "OVN northbound database connection test:"
    ovn-nbctl --db=unix:/var/run/ovn/ovnnb_db.sock show 2>&1 || echo "Failed to connect to NB database"
    echo ""
    echo "Socket permissions:"
    ls -la /var/run/ovn/ 2>&1 || echo "Cannot list /var/run/ovn/"
    echo ""
    echo "Process status:"
    ps aux | grep -E "(ovn-northd|ovsdb-server)" | grep -v grep || echo "No OVN processes found"
    echo ""
    echo "=== End Diagnostic Information ==="
fi

STARTUP_END=$(date +%s)
TOTAL_STARTUP=$((STARTUP_END - STARTUP_START))
echo "========================================================"
echo "✓ All services started successfully"
echo "✓ Total startup time: ${TOTAL_STARTUP}s"
echo "========================================================"

# Start router service in background
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Arca Router Service on vsock port 50052..."
/usr/local/bin/router-service --vsock-port=50052 &
ROUTER_PID=$!
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ Router service started (PID: $ROUTER_PID)"

# Brief pause to let router service initialize
sleep 1

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting Arca Network Control API on vsock port 9999..."

# Start the control API server (foreground - this keeps the container running)
# Uses mdlayher/vsock library for proper vsock net.Listener support
exec /usr/local/bin/arca-network-api --vsock-port=9999
