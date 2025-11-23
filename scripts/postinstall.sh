#!/bin/bash
#
# Arca .pkg Postinstall Script (User-Local Installation)
# Runs as the current user (no admin/root required)
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo ""
echo "Arca Post-Installation Setup"
echo "============================="
echo ""

# User directories
USER_HOME="$HOME"
ARCA_INSTALL_DIR="$USER_HOME/Library/Application Support/Arca"
ARCA_USER_DIR="$USER_HOME/.arca"

echo "Installing Arca for user: $(whoami)"
echo "Installation directory: $ARCA_INSTALL_DIR"
echo ""

# Create ~/.arca directory for runtime data
echo "Creating Arca user directory..."
mkdir -p "$ARCA_USER_DIR"
chmod 755 "$ARCA_USER_DIR"
echo -e "${GREEN}✓${NC} Created: $ARCA_USER_DIR"

# Create symlinks to installed assets
KERNEL_SRC="$ARCA_INSTALL_DIR/share/vmlinux"
KERNEL_DST="$ARCA_USER_DIR/vmlinux"
VMINIT_ENCRYPTED="$ARCA_INSTALL_DIR/share/vminit.zip"
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
    mkdir -p "$ARCA_USER_DIR"

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

# Verify assets
echo "Verifying assets..."

# Verify kernel
if [ ! -f "$KERNEL_DST" ]; then
    echo -e "${RED}ERROR: Kernel symlink failed${NC}"
    exit 1
fi

KERNEL_SIZE=$(wc -c < "$KERNEL_DST")
if [ "$KERNEL_SIZE" -lt 1000000 ]; then
    echo -e "${RED}ERROR: Kernel file seems too small ($KERNEL_SIZE bytes)${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} Kernel verified: $(numfmt --to=iec-i --suffix=B "$KERNEL_SIZE")"

# Verify vminit OCI layout
if [ ! -f "$VMINIT_DST/oci-layout" ]; then
    echo -e "${RED}ERROR: vminit OCI layout not found${NC}"
    exit 1
fi

echo -e "${GREEN}✓${NC} vminit OCI layout verified"

# Install LaunchAgent (auto-start daemon on boot)
LAUNCH_AGENT_DIR="$USER_HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/com.liquescent.arca.plist"
LAUNCH_AGENT_TEMPLATE="$ARCA_INSTALL_DIR/share/com.liquescent.arca.plist.template"

echo ""
echo "Installing LaunchAgent for auto-start..."

if [ -f "$LAUNCH_AGENT_TEMPLATE" ]; then
    mkdir -p "$LAUNCH_AGENT_DIR"

    # Replace HOME_DIR placeholder with actual user home
    sed "s|HOME_DIR|$USER_HOME|g" "$LAUNCH_AGENT_TEMPLATE" > "$LAUNCH_AGENT_PLIST"
    chmod 644 "$LAUNCH_AGENT_PLIST"

    echo -e "${GREEN}✓${NC} LaunchAgent installed: $LAUNCH_AGENT_PLIST"

    # Load LaunchAgent immediately
    launchctl load -w "$LAUNCH_AGENT_PLIST" 2>/dev/null || {
        echo -e "${YELLOW}⚠${NC}  Could not auto-start daemon (will start on next login)"
        echo "   To start now: launchctl load -w ~/Library/LaunchAgents/com.liquescent.arca.plist"
    }

    # Wait a moment for daemon to start
    sleep 2

    # Check if daemon started successfully
    SOCKET_PATH="$USER_HOME/.arca/arca.sock"
    if [ -S "$SOCKET_PATH" ]; then
        echo -e "${GREEN}✓${NC} Arca daemon is running"
        echo "   Socket: $SOCKET_PATH"
    else
        echo -e "${YELLOW}⚠${NC}  Daemon will start on next login"
    fi
else
    echo -e "${YELLOW}⚠${NC}  LaunchAgent template not found (manual start required)"
    echo "   Start daemon: $ARCA_INSTALL_DIR/bin/Arca daemon start"
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
        # Check if .bash_profile or .bashrc exists
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
    *)
        echo -e "${YELLOW}⚠${NC}  Unknown shell: $SHELL_NAME"
        echo "   Manually add to your shell config:"
        echo "   export PATH=\"\$HOME/Library/Application Support/Arca/bin:\$PATH\""
        echo "   export DOCKER_HOST=\"unix://\$HOME/.arca/arca.sock\""
        SHELL_CONFIG=""
        ;;
esac

if [ -n "$SHELL_CONFIG" ]; then
    # Check if already configured
    if grep -q "# Arca configuration" "$SHELL_CONFIG" 2>/dev/null; then
        echo -e "${BLUE}ℹ${NC}  Shell already configured: $SHELL_CONFIG"
    else
        echo "" >> "$SHELL_CONFIG"
        echo "# Arca configuration" >> "$SHELL_CONFIG"
        echo "export PATH=\"\$HOME/Library/Application Support/Arca/bin:\$PATH\"" >> "$SHELL_CONFIG"
        echo "export DOCKER_HOST=\"unix://\$HOME/.arca/arca.sock\"" >> "$SHELL_CONFIG"
        echo -e "${GREEN}✓${NC} Shell configured: $SHELL_CONFIG"
        echo -e "${BLUE}ℹ${NC}  Restart your terminal or run: source $SHELL_CONFIG"
    fi
fi

# Summary
echo ""
echo "============================="
echo -e "${GREEN}✓ Installation complete!${NC}"
echo "============================="
echo ""
echo "Arca has been installed successfully."
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo ""
echo "1. Restart your terminal (or run: source $SHELL_CONFIG)"
echo ""
echo "2. Verify installation:"
echo "   arca --version"
echo "   docker version"
echo "   docker run hello-world"
echo ""
echo -e "${BLUE}Daemon Management:${NC}"
echo "  Start:   launchctl load -w ~/Library/LaunchAgents/com.liquescent.arca.plist"
echo "  Stop:    launchctl unload ~/Library/LaunchAgents/com.liquescent.arca.plist"
echo "  Status:  launchctl list | grep arca"
echo ""
echo "For help: arca --help"
echo "Documentation: https://github.com/Vas-Solutus/arca"
echo ""

exit 0
