#!/bin/bash
#
# Arca .pkg Preinstall Script
# Runs before package installation to verify system requirements
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo "Arca Pre-Installation Checks"
echo "=============================="
echo ""

# Check macOS version (requires Sequoia 15.0+)
echo "Checking macOS version..."
MACOS_VERSION=$(sw_vers -productVersion)
MACOS_MAJOR=$(echo "$MACOS_VERSION" | cut -d '.' -f 1)

if [ "$MACOS_MAJOR" -lt 15 ]; then
    echo -e "${RED}ERROR: Arca requires macOS 15.0 (Sequoia) or later${NC}"
    echo "Current version: $MACOS_VERSION"
    echo ""
    echo "Please upgrade to macOS Sequoia to use Arca."
    exit 1
fi

echo -e "${GREEN}✓${NC} macOS version: $MACOS_VERSION (compatible)"

# Check architecture (ARM64 required - Intel can run via Rosetta 2)
echo "Checking system architecture..."
ARCH=$(uname -m)

if [ "$ARCH" != "arm64" ] && [ "$ARCH" != "x86_64" ]; then
    echo -e "${RED}ERROR: Unsupported architecture: $ARCH${NC}"
    echo "Arca requires ARM64 (Apple Silicon) or x86_64 (Intel)."
    exit 1
fi

if [ "$ARCH" = "x86_64" ]; then
    echo -e "${YELLOW}⚠${NC}  Architecture: $ARCH (Intel Mac)"
    echo "   Note: Arca will run via Rosetta 2. For best performance, use Apple Silicon."
else
    echo -e "${GREEN}✓${NC} Architecture: $ARCH (Apple Silicon)"
fi

# Check if Arca is already installed
echo "Checking for existing installation..."
EXISTING_BINARY="/usr/local/bin/Arca"
EXISTING_ASSETS="/usr/local/share/arca"

if [ -f "$EXISTING_BINARY" ]; then
    EXISTING_VERSION=$("$EXISTING_BINARY" version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    echo -e "${YELLOW}⚠${NC}  Existing installation found: $EXISTING_VERSION"
    echo "   This installation will upgrade Arca."

    # Check if daemon is running
    DAEMON_RUNNING=false
    if launchctl list | grep -q com.liquescent.arca; then
        echo -e "${YELLOW}⚠${NC}  Arca daemon is currently running (LaunchAgent)"
        DAEMON_RUNNING=true
    elif pgrep -f "Arca daemon start" > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠${NC}  Arca daemon is currently running"
        DAEMON_RUNNING=true
    fi

    if [ "$DAEMON_RUNNING" = true ]; then
        echo ""
        echo "The daemon will be stopped during installation and can be restarted afterward."

        # Stop LaunchAgent if running
        if launchctl list | grep -q com.liquescent.arca; then
            echo "Stopping LaunchAgent..."
            launchctl unload ~/Library/LaunchAgents/com.liquescent.arca.plist 2>/dev/null || true
        fi

        # Wait a moment for daemon to shut down gracefully
        sleep 2
    fi
else
    echo -e "${GREEN}✓${NC} No existing installation found (clean install)"
fi

# Check for containerization submodule (development installs)
# This check is informational only - not required for binary distribution
if [ -d "containerization/.git" ]; then
    echo -e "${GREEN}✓${NC} Containerization submodule initialized"
else
    echo "ℹ  Containerization submodule not initialized (normal for binary installs)"
fi

# Check available disk space (require at least 1 GB free)
echo "Checking disk space..."
AVAILABLE_SPACE=$(df -h / | awk 'NR==2 {print $4}' | sed 's/Gi//')
AVAILABLE_SPACE_INT=$(echo "$AVAILABLE_SPACE" | cut -d'.' -f1)

if [ "$AVAILABLE_SPACE_INT" -lt 1 ]; then
    echo -e "${RED}ERROR: Insufficient disk space${NC}"
    echo "Available: ${AVAILABLE_SPACE}GB, Required: 1GB"
    echo ""
    echo "Please free up disk space before installing Arca."
    exit 1
fi

echo -e "${GREEN}✓${NC} Disk space: ${AVAILABLE_SPACE}GB available"

# Summary
echo ""
echo "=============================="
echo -e "${GREEN}Pre-installation checks passed!${NC}"
echo "=============================="
echo ""
echo "Installation will:"
echo "  • Install Arca binary to /usr/local/bin/Arca"
echo "  • Install kernel (vmlinux) to /usr/local/share/arca/"
echo "  • Install vminit image to /usr/local/share/arca/vminit/"
echo "  • Create ~/.arca/ directory with symlinks"
echo "  • Optionally install LaunchAgent for auto-start"
echo ""

exit 0
