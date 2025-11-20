#!/bin/bash
#
# Arca Uninstall Script
# Removes Arca.app and all user data
#
# Usage: ./uninstall.sh [--remove-data]
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
REMOVE_DATA=false
if [ "$1" = "--remove-data" ]; then
    REMOVE_DATA=true
fi

echo ""
echo "Arca Uninstall"
echo "=============="
echo ""

# Installation locations
USER_HOME="$HOME"
ARCA_APP="/Applications/Arca.app"
ARCA_USER_DIR="$USER_HOME/.arca"
LAUNCH_AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.liquescent.arca.plist"

echo "Removing Arca for user: $(whoami)"
echo ""

# Step 1: Stop and unload LaunchAgent
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    echo "Stopping Arca daemon (LaunchAgent)..."

    # Check if daemon is running
    if launchctl list | grep -q com.liquescent.arca; then
        launchctl unload "$LAUNCH_AGENT_PLIST" 2>/dev/null || true
        echo -e "${GREEN}✓${NC} Daemon stopped"
    else
        echo -e "${GREEN}✓${NC} Daemon not running"
    fi

    # Wait for daemon to shut down
    sleep 2
else
    echo "No LaunchAgent found (skipping)"
fi

# Step 2: Check for running Arca processes
echo "Checking for running Arca processes..."

# Check for GUI app
GUI_PIDS=$(pgrep -f "Arca.app" || true)
# Check for daemon
DAEMON_PIDS=$(pgrep -f "Arca daemon start" || true)

ARCA_PIDS="${GUI_PIDS}${DAEMON_PIDS}"

if [ -n "$ARCA_PIDS" ]; then
    echo -e "${YELLOW}⚠${NC}  Found running Arca processes"
    [ -n "$GUI_PIDS" ] && echo "    GUI: $GUI_PIDS"
    [ -n "$DAEMON_PIDS" ] && echo "    Daemon: $DAEMON_PIDS"
    echo "Stopping processes..."
    echo "$ARCA_PIDS" | xargs kill -TERM 2>/dev/null || true
    sleep 2
    echo -e "${GREEN}✓${NC} Processes stopped"
else
    echo -e "${GREEN}✓${NC} No running processes found"
fi

# Step 3: Remove Arca.app
if [ -d "$ARCA_APP" ]; then
    echo "Removing Arca.app..."
    rm -rf "$ARCA_APP"
    echo -e "${GREEN}✓${NC} Removed: $ARCA_APP"
else
    echo -e "${YELLOW}⚠${NC}  Arca.app not found at: $ARCA_APP"
fi

# Step 4: Remove LaunchAgent plist
if [ -f "$LAUNCH_AGENT_PLIST" ]; then
    echo "Removing LaunchAgent..."
    rm -f "$LAUNCH_AGENT_PLIST"
    echo -e "${GREEN}✓${NC} Removed: $LAUNCH_AGENT_PLIST"
fi

# Step 5: Remove shell configuration
echo ""
echo "Checking shell configuration..."

SHELL_CONFIGS=()
SHELL_NAME=$(basename "$SHELL")

case "$SHELL_NAME" in
    zsh)
        SHELL_CONFIGS+=("$USER_HOME/.zshrc")
        ;;
    bash)
        [ -f "$USER_HOME/.bash_profile" ] && SHELL_CONFIGS+=("$USER_HOME/.bash_profile")
        [ -f "$USER_HOME/.bashrc" ] && SHELL_CONFIGS+=("$USER_HOME/.bashrc")
        ;;
    fish)
        SHELL_CONFIGS+=("$USER_HOME/.config/fish/config.fish")
        ;;
esac

FOUND_CONFIG=false
for CONFIG in "${SHELL_CONFIGS[@]}"; do
    if [ -f "$CONFIG" ] && grep -q "# Arca configuration" "$CONFIG" 2>/dev/null; then
        # Remove Arca configuration lines
        sed -i.bak '/# Arca configuration/,+2d' "$CONFIG"
        rm -f "${CONFIG}.bak"
        echo -e "${GREEN}✓${NC} Removed Arca configuration from: $CONFIG"
        FOUND_CONFIG=true
    fi
done

if [ "$FOUND_CONFIG" = false ]; then
    echo -e "${GREEN}✓${NC} No shell configuration found"
fi

# Step 6: Handle user data directory
if [ -d "$ARCA_USER_DIR" ]; then
    echo ""
    echo "User data directory found: $ARCA_USER_DIR"
    echo "This contains:"
    echo "  • State database (container metadata)"
    echo "  • Container filesystems"
    echo "  • vminit OCI image"
    echo "  • Logs"
    echo ""

    if [ "$REMOVE_DATA" = true ]; then
        echo -e "${YELLOW}⚠${NC}  --remove-data flag provided"
        echo "Removing ALL user data..."
        rm -rf "$ARCA_USER_DIR"
        echo -e "${GREEN}✓${NC} Removed: $ARCA_USER_DIR"
    else
        echo -e "${BLUE}ℹ${NC}  User data preserved (default behavior)"
        echo ""
        echo "To remove user data, run:"
        echo "  rm -rf $ARCA_USER_DIR"
        echo ""
        echo "Or run this script with --remove-data:"
        echo "  ./uninstall.sh --remove-data"
        echo ""
    fi
else
    echo -e "${YELLOW}⚠${NC}  User data directory not found: $ARCA_USER_DIR"
fi

# Step 7: Check for Docker images (via Apple's ImageStore)
APPLE_IMAGE_STORE="$USER_HOME/Library/Application Support/com.apple.containerization"

if [ -d "$APPLE_IMAGE_STORE" ]; then
    echo ""
    echo -e "${BLUE}ℹ${NC}  Docker images are stored by Apple's Containerization framework at:"
    echo "   $APPLE_IMAGE_STORE"
    echo ""
    echo "These images are NOT removed by this script."
    echo "To remove images, use Docker CLI before uninstalling:"
    echo "  docker image prune -a"
fi

# Summary
echo ""
echo "==========================="
echo -e "${GREEN}✓ Uninstall complete!${NC}"
echo "==========================="
echo ""
echo "Removed:"
echo "  ✓ Arca.app (/Applications/Arca.app)"
echo "  ✓ LaunchAgent (~/Library/LaunchAgents/com.liquescent.arca.plist)"
if [ "$FOUND_CONFIG" = true ]; then
    echo "  ✓ Shell configuration (PATH and DOCKER_HOST)"
fi

if [ "$REMOVE_DATA" = true ]; then
    echo "  ✓ User data (~/.arca/)"
else
    echo "  ○ User data preserved (~/.arca/)"
fi

echo ""
echo "Arca has been uninstalled from your system."
echo ""
echo "To perform a complete clean uninstall (removes all data):"
echo "  ./uninstall.sh --remove-data"
echo ""

exit 0
