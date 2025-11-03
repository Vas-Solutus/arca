#!/bin/bash
# NAT initialization for control plane container
# Enables internet access for user containers on OVN bridge networks

set -e

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing NAT for user container networks..."

# Enable IP forwarding (required for NAT)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Enabling IP forwarding..."
echo 1 > /proc/sys/net/ipv4/ip_forward

# Verify IP forwarding is enabled
if [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "1" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ IP forwarding enabled"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Failed to enable IP forwarding"
    exit 1
fi

# Detect the external interface (vmnet interface with default route)
EXTERNAL_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [ -z "$EXTERNAL_IFACE" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: Could not detect external interface"
    exit 1
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Detected external interface: $EXTERNAL_IFACE"

# Set up NAT for user container networks (172.16.0.0/12 covers 172.16-172.31)
# This range includes all potential user networks managed by OVN
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Setting up iptables NAT rules..."

# MASQUERADE: Rewrite source IP of outgoing packets from user networks to the external interface IP
iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o "$EXTERNAL_IFACE" -j MASQUERADE

# Allow forwarding between br-int and external interface
iptables -A FORWARD -i br-int -o "$EXTERNAL_IFACE" -j ACCEPT
iptables -A FORWARD -i "$EXTERNAL_IFACE" -o br-int -m state --state RELATED,ESTABLISHED -j ACCEPT

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ NAT rules configured"

# Display current NAT rules for verification
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current NAT rules:"
iptables -t nat -L POSTROUTING -n -v | head -5

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Current FORWARD rules:"
iptables -L FORWARD -n -v | head -10

echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✓ NAT initialization complete"
