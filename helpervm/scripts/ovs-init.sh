#!/bin/bash
set -e

echo "Initializing Open vSwitch..."

# Create directories
mkdir -p /var/run/openvswitch
mkdir -p /var/log/openvswitch
mkdir -p /etc/openvswitch

# Initialize OVS database if it doesn't exist
if [ ! -f /etc/openvswitch/conf.db ]; then
    echo "Creating OVS database..."
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi

# Start ovsdb-server
echo "Starting ovsdb-server..."
ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --pidfile --detach --log-file

# Initialize database
echo "Initializing OVS database..."
ovs-vsctl --no-wait init || true

# Start ovs-vswitchd
echo "Starting ovs-vswitchd..."
ovs-vswitchd --pidfile --detach --log-file

# Wait for OVS to be ready
echo "Waiting for OVS to be ready..."
timeout=10
while [ $timeout -gt 0 ]; do
    if ovs-vsctl show >/dev/null 2>&1; then
        echo "OVS is ready"
        break
    fi
    sleep 1
    timeout=$((timeout - 1))
done

if [ $timeout -eq 0 ]; then
    echo "ERROR: OVS failed to start"
    exit 1
fi

echo "Open vSwitch initialized successfully"
