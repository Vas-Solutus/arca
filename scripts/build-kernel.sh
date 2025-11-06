#!/bin/bash
# Build Linux kernel with TUN and WireGuard support for Arca
# This script follows Apple's documented kernel build process from:
# https://github.com/apple/containerization/tree/main/kernel

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$HOME/.arca/kernel-build"
INSTALL_PATH="$HOME/.arca/vmlinux"

echo "=== Building Linux kernel with TUN and WireGuard support ==="
echo

# Check prerequisites
if ! command -v container &> /dev/null; then
    echo "ERROR: 'container' tool not found"
    echo "Download from: https://github.com/apple/container/releases"
    exit 1
fi

# Create work directory
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Download Apple's kernel build files if not present
if [ ! -d "kernel" ]; then
    echo "→ Downloading Apple's kernel build configuration..."
    git clone --depth 1 https://github.com/apple/containerization.git temp-repo
    mv temp-repo/kernel .
    rm -rf temp-repo
fi

cd kernel

# Create .dockerignore if it doesn't exist (required by container build)
if [ ! -f "image/.dockerignore" ]; then
    touch image/.dockerignore
fi

# Enable CONFIG_TUN in the kernel config
echo "→ Enabling CONFIG_TUN in kernel configuration..."
if grep -q "^# CONFIG_TUN is not set" config-arm64; then
    sed -i.bak 's/^# CONFIG_TUN is not set$/CONFIG_TUN=y/' config-arm64
    echo "  ✓ Enabled CONFIG_TUN=y"
elif grep -q "^CONFIG_TUN=y" config-arm64; then
    echo "  ✓ CONFIG_TUN already enabled"
else
    echo "CONFIG_TUN=y" >> config-arm64
    echo "  ✓ Added CONFIG_TUN=y"
fi

# Enable CONFIG_WIREGUARD in the kernel config
echo "→ Enabling CONFIG_WIREGUARD in kernel configuration..."
if grep -q "^# CONFIG_WIREGUARD is not set" config-arm64; then
    sed -i.bak 's/^# CONFIG_WIREGUARD is not set$/CONFIG_WIREGUARD=y/' config-arm64
    echo "  ✓ Enabled CONFIG_WIREGUARD=y"
elif grep -q "^CONFIG_WIREGUARD=y" config-arm64; then
    echo "  ✓ CONFIG_WIREGUARD already enabled"
else
    echo "CONFIG_WIREGUARD=y" >> config-arm64
    echo "  ✓ Added CONFIG_WIREGUARD=y"
fi

# Run Apple's build process
echo
echo "→ Building kernel (this will take 10-15 minutes)..."
echo "  Using Apple's Makefile and build.sh"
make

# Install the kernel
if [ -f "vmlinux" ]; then
    echo
    echo "→ Installing kernel..."

    # Backup existing kernel if present
    if [ -f "$INSTALL_PATH" ]; then
        BACKUP="$INSTALL_PATH.backup-$(date +%Y%m%d-%H%M%S)"
        mv "$INSTALL_PATH" "$BACKUP"
        echo "  ✓ Backed up existing kernel to: $BACKUP"
    fi

    cp vmlinux "$INSTALL_PATH"
    echo "  ✓ Installed to: $INSTALL_PATH"
    echo
    echo "=== Build complete! ==="
    echo
    echo "Kernel installed at: $INSTALL_PATH"
    echo "Update your Arca config to use this kernel path."
else
    echo "ERROR: Build completed but vmlinux not found"
    exit 1
fi
