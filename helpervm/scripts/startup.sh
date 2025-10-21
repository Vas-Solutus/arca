#!/bin/bash
set -e

echo "==================================="
echo "Arca Network Helper VM Starting..."
echo "==================================="

# Initialize Open vSwitch
/usr/local/bin/ovs-init.sh

# Initialize OVN databases
echo "Initializing OVN databases..."
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
sleep 2

echo "All services started successfully"
echo "Starting Arca Network Control API..."

# Start the control API server (foreground - this keeps the container running)
# Note: Uses TCP instead of vsock due to grpc-swift limitation
exec /usr/local/bin/arca-network-api --port=:9999
