#!/bin/bash
#
# Arca First-Launch Setup Script
# Runs when the app is first launched (or manually via "arca setup")
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Get the app bundle path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

# User directories
USER_HOME="$HOME"
ARCA_USER_DIR="$USER_HOME/.arca"
LAUNCH_AGENT_PLIST="$USER_HOME/Library/LaunchAgents/com.liquescent.arca.plist"

echo ""
echo "Arca Setup"
echo "=========="
echo ""
echo "Installing Arca from: $APP_BUNDLE"
echo ""

# Create ~/.arca directory for runtime data
echo "Creating Arca user directory..."
mkdir -p "$ARCA_USER_DIR"
chmod 755 "$ARCA_USER_DIR"
echo -e "${GREEN}✓${NC} Created: $ARCA_USER_DIR"

# Create symlinks to app bundle assets
KERNEL_SRC="$RESOURCES_DIR/vmlinux"
KERNEL_DST="$ARCA_USER_DIR/vmlinux"
VMINIT_ENCRYPTED="$RESOURCES_DIR/vminit.zip"
VMINIT_DST="$ARCA_USER_DIR/vminit"
VMINIT_PASSWORD="arca-vminit-payload"

echo "Creating symlinks to assets..."

# Symlink kernel
if [ -f "$KERNEL_SRC" ]; then
    if [ -L "$KERNEL_DST" ] || [ -f "$KERNEL_DST" ]; then
        rm -f "$KERNEL_DST"
    fi
    ln -s "$KERNEL_SRC" "$KERNEL_DST"
    echo -e "${GREEN}✓${NC} Linked: $KERNEL_DST → $KERNEL_SRC"
else
    echo -e "${RED}ERROR: Kernel not found at $KERNEL_SRC${NC}"
    exit 1
fi

# Extract and setup vminit
if [ -f "$VMINIT_ENCRYPTED" ]; then
    echo "Decrypting and extracting vminit OCI image..."
    if [ -d "$VMINIT_DST" ]; then
        rm -rf "$VMINIT_DST"
    fi

    # Decrypt zip to temporary location
    TEMP_VMINIT=$(mktemp /tmp/vminit.XXXXXX.tar.gz)
    unzip -q -P "$VMINIT_PASSWORD" -p "$VMINIT_ENCRYPTED" > "$TEMP_VMINIT"

    # Extract OCI image
    tar xzf "$TEMP_VMINIT" -C "$ARCA_USER_DIR"
    rm -f "$TEMP_VMINIT"

    echo -e "${GREEN}✓${NC} Extracted: vminit to $VMINIT_DST"
else
    echo -e "${RED}ERROR: vminit archive not found at $VMINIT_ENCRYPTED${NC}"
    exit 1
fi

# Install LaunchAgent (auto-start daemon on boot)
echo ""
echo "Installing LaunchAgent for auto-start..."

LAUNCH_AGENT_DIR="$USER_HOME/Library/LaunchAgents"
mkdir -p "$LAUNCH_AGENT_DIR"

# Create LaunchAgent plist
cat > "$LAUNCH_AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.liquescent.arca</string>

    <key>ProgramArguments</key>
    <array>
        <string>$APP_BUNDLE/Contents/MacOS/Arca</string>
        <string>daemon</string>
        <string>start</string>
        <string>--socket-path</string>
        <string>$USER_HOME/.arca/arca.sock</string>
        <string>--kernel-path</string>
        <string>$USER_HOME/.arca/vmlinux</string>
        <string>--log-level</string>
        <string>info</string>
        <string>--foreground</string>
    </array>

    <key>RunAtLoad</key>
    <false/>

    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>

    <key>StandardOutPath</key>
    <string>$USER_HOME/.arca/arca.log</string>

    <key>StandardErrorPath</key>
    <string>$USER_HOME/.arca/arca.log</string>

    <key>WorkingDirectory</key>
    <string>$USER_HOME</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>$USER_HOME</string>
    </dict>
</dict>
</plist>
EOF

chmod 644 "$LAUNCH_AGENT_PLIST"
echo -e "${GREEN}✓${NC} LaunchAgent installed: $LAUNCH_AGENT_PLIST"

# Load LaunchAgent immediately
launchctl load -w "$LAUNCH_AGENT_PLIST" 2>/dev/null || {
    echo -e "${YELLOW}⚠${NC}  Could not auto-start daemon (will start on next login)"
}

# Wait a moment for daemon to start
sleep 2

# Check if daemon started successfully
SOCKET_PATH="$USER_HOME/.arca/arca.sock"
if [ -S "$SOCKET_PATH" ]; then
    echo -e "${GREEN}✓${NC} Arca daemon is running"
else
    echo -e "${YELLOW}⚠${NC}  Daemon will start on next login"
fi

# Configure shell (PATH and DOCKER_HOST)
echo ""
echo "Configuring shell environment..."

# Detect shell
SHELL_NAME=$(basename "$SHELL")
SHELL_CONFIG=""

case "$SHELL_NAME" in
    zsh)
        SHELL_CONFIG="$USER_HOME/.zshrc"
        ;;
    bash)
        if [ -f "$USER_HOME/.bash_profile" ]; then
            SHELL_CONFIG="$USER_HOME/.bash_profile"
        elif [ -f "$USER_HOME/.bashrc" ]; then
            SHELL_CONFIG="$USER_HOME/.bashrc"
        else
            SHELL_CONFIG="$USER_HOME/.bash_profile"
        fi
        ;;
    fish)
        SHELL_CONFIG="$USER_HOME/.config/fish/config.fish"
        mkdir -p "$(dirname "$SHELL_CONFIG")"
        ;;
esac

if [ -n "$SHELL_CONFIG" ]; then
    # Check if already configured
    if grep -q "# Arca configuration" "$SHELL_CONFIG" 2>/dev/null; then
        echo -e "${BLUE}ℹ${NC}  Shell already configured: $SHELL_CONFIG"
    else
        echo "" >> "$SHELL_CONFIG"
        echo "# Arca configuration" >> "$SHELL_CONFIG"
        echo "export PATH=\"$APP_BUNDLE/Contents/MacOS:\$PATH\"" >> "$SHELL_CONFIG"
        echo "export DOCKER_HOST=\"unix://\$HOME/.arca/arca.sock\"" >> "$SHELL_CONFIG"
        echo -e "${GREEN}✓${NC} Shell configured: $SHELL_CONFIG"
        echo -e "${BLUE}ℹ${NC}  Restart your terminal or run: source $SHELL_CONFIG"
    fi
fi

# Summary
echo ""
echo "=============================="
echo -e "${GREEN}✓ Setup complete!${NC}"
echo "=============================="
echo ""
echo "Next steps:"
echo "1. Restart your terminal (or run: source $SHELL_CONFIG)"
echo "2. Verify: arca --version"
echo "3. Test: docker version"
echo ""
echo -e "${BLUE}Daemon Management:${NC}"
echo "  Start:   launchctl load -w ~/Library/LaunchAgents/com.liquescent.arca.plist"
echo "  Stop:    launchctl unload ~/Library/LaunchAgents/com.liquescent.arca.plist"
echo "  Status:  launchctl list | grep arca"
echo ""

exit 0
