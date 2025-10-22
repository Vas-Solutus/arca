#!/bin/bash
set -e

START_TIME=$(date +%s)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing Open vSwitch..."

# Create directories
mkdir -p /var/run/openvswitch
mkdir -p /var/log/openvswitch
mkdir -p /etc/openvswitch

# Debug: Check /dev mount and TUN device
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Debugging TUN device setup..."
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Mount info for /dev:"
mount | grep /dev || echo "  (no /dev mounts found)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking if /dev/net/tun exists:"
if [ -e /dev/net/tun ]; then
    ls -la /dev/net/tun
    echo "  Device exists, attempting to read:"
    if dd if=/dev/net/tun of=/dev/null count=0 2>&1; then
        echo "  ✓ TUN device is accessible"
    else
        echo "  ✗ TUN device exists but cannot be opened (error code: $?)"
    fi
else
    echo "  /dev/net/tun does NOT exist"
    echo "  Creating device node..."
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200
    chmod 666 /dev/net/tun
    echo "  Device created, testing accessibility:"
    if dd if=/dev/net/tun of=/dev/null count=0 2>&1; then
        echo "  ✓ TUN device is now accessible"
    else
        echo "  ✗ TUN device created but still cannot be opened (error code: $?)"
        echo "  This suggests the TUN driver is not functioning in the kernel"
    fi
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Checking kernel support for TUN:"
echo "  Contents of /sys/class/misc/:"
ls -la /sys/class/misc/ 2>/dev/null || echo "  /sys/class/misc/ does not exist"

echo "  Checking /sys/class/net/:"
ls -la /sys/class/net/ 2>/dev/null || echo "  /sys/class/net/ does not exist"

echo "  Checking /sys/devices/virtual/:"
ls -la /sys/devices/virtual/ 2>/dev/null | head -20 || echo "  /sys/devices/virtual/ does not exist"

echo "  Checking kernel version and config:"
uname -a
if [ -f /proc/config.gz ]; then
    echo "  Checking CONFIG_TUN in /proc/config.gz:"
    zcat /proc/config.gz | grep TUN
elif [ -f /boot/config-$(uname -r) ]; then
    echo "  Checking CONFIG_TUN in /boot/config:"
    grep TUN /boot/config-$(uname -r)
else
    echo "  Cannot find kernel config to verify TUN setting"
fi

echo "  Checking if TUN driver needs to be initialized:"
if [ -d /sys/class/misc/tun ]; then
    echo "  ✓ TUN driver is present in kernel (/sys/class/misc/tun exists)"
else
    echo "  ✗ TUN driver not found in /sys/class/misc/"
    echo "  Attempting to trigger TUN driver initialization by opening device..."
    # Sometimes TUN driver initializes lazily when first accessed
    if cat /dev/net/tun 2>&1 | grep -q "File descriptor in bad state"; then
        echo "  ✓ TUN driver responded (even if with error - this is expected)"
    fi
fi

# Initialize OVS database if it doesn't exist
if [ ! -f /etc/openvswitch/conf.db ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Creating OVS database..."
    ovsdb-tool create /etc/openvswitch/conf.db /usr/share/openvswitch/vswitch.ovsschema
fi

# Start ovsdb-server
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting ovsdb-server..."
OVSDB_START=$(date +%s)
ovsdb-server --remote=punix:/var/run/openvswitch/db.sock \
    --remote=db:Open_vSwitch,Open_vSwitch,manager_options \
    --pidfile --detach --log-file
OVSDB_END=$(date +%s)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ovsdb-server started in $((OVSDB_END - OVSDB_START))s"

# Initialize database
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing OVS database..."
ovs-vsctl --no-wait init || true

# Start ovs-vswitchd
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting ovs-vswitchd..."
VSWITCHD_START=$(date +%s)
ovs-vswitchd --pidfile --detach --log-file
VSWITCHD_END=$(date +%s)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] ovs-vswitchd started in $((VSWITCHD_END - VSWITCHD_START))s"

# Wait for OVS to be ready for operations
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Waiting for OVS to be ready..."
WAIT_START=$(date +%s)
timeout=10
while [ $timeout -gt 0 ]; do
    if ovs-vsctl show >/dev/null 2>&1; then
        WAIT_END=$(date +%s)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] OVS is ready (waited $((WAIT_END - WAIT_START))s)"
        break
    fi
    sleep 1
    timeout=$((timeout - 1))
done

if [ $timeout -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: OVS failed to start within 10 seconds"
    exit 1
fi

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Open vSwitch initialized successfully (total time: ${TOTAL_TIME}s)"
