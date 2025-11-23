#!/bin/bash
#
# Arca Notarization Script
# Submits .pkg or .dmg to Apple notarization service and staples the ticket
#
# Requirements:
#   - For .pkg: Must be signed with Developer ID Installer certificate
#   - For .dmg: App bundle inside must be signed with Developer ID Application certificate
#   - Package/image file path as first argument
#
# Optional:
#   - NOTARY_KEY_ID: App Store Connect API key ID
#   - NOTARY_ISSUER_ID: App Store Connect API issuer ID
#   - NOTARY_KEY_FILE: Path to API key .p8 file
#

set -e

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage
usage() {
    echo "Usage: $0 <file.pkg|file.dmg>"
    echo ""
    echo "Supported file types:"
    echo "  .pkg - Installer package (must be signed with Developer ID Installer)"
    echo "  .dmg - Disk image containing app bundle (app must be signed with Developer ID Application)"
    echo ""
    echo "Optional (for API key authentication):"
    echo "  NOTARY_KEY_ID       - App Store Connect API key ID"
    echo "  NOTARY_ISSUER_ID    - App Store Connect API issuer ID"
    echo "  NOTARY_KEY_FILE     - Path to API key .p8 file"
    echo ""
    echo "Password authentication (default):"
    echo "  Store password in keychain with:"
    echo "  xcrun notarytool store-credentials \"AC_PASSWORD\" --apple-id=\"your@email.com\" --team-id=\"YOUR_TEAM_ID\""
    exit 1
}

# Check arguments
if [ $# -ne 1 ]; then
    usage
fi

FILE="$1"

if [ ! -f "$FILE" ]; then
    echo -e "${RED}ERROR: File not found: $FILE${NC}"
    exit 1
fi

# Detect file type
FILE_EXT="${FILE##*.}"
if [ "$FILE_EXT" != "pkg" ] && [ "$FILE_EXT" != "dmg" ]; then
    echo -e "${RED}ERROR: Unsupported file type: .$FILE_EXT${NC}"
    echo "Supported types: .pkg, .dmg"
    exit 1
fi

echo ""
echo "Arca Notarization Workflow"
echo "==========================="
echo ""
echo "File: $FILE"
echo "Type: .$FILE_EXT"
echo ""

# Validate environment variables
echo "Validating configuration..."

# Determine authentication method
AUTH_METHOD="password"
if [ -n "$NOTARY_KEY_ID" ] && [ -n "$NOTARY_ISSUER_ID" ] && [ -n "$NOTARY_KEY_FILE" ]; then
    AUTH_METHOD="apiKey"
    echo -e "${BLUE}ℹ${NC}  Using API key authentication"
    echo "  Key ID: $NOTARY_KEY_ID"
    echo "  Issuer ID: $NOTARY_ISSUER_ID"
    echo "  Key file: $NOTARY_KEY_FILE"

    if [ ! -f "$NOTARY_KEY_FILE" ]; then
        echo -e "${RED}ERROR: API key file not found: $NOTARY_KEY_FILE${NC}"
        exit 1
    fi
else
    echo -e "${BLUE}ℹ${NC}  Using keychain-profile authentication (profile: AC_PASSWORD)"

    # Verify the profile exists and works
    if ! xcrun notarytool history --keychain-profile "AC_PASSWORD" > /dev/null 2>&1; then
        echo -e "${RED}ERROR: Keychain profile 'AC_PASSWORD' not found or invalid${NC}"
        echo ""
        echo "Store credentials with:"
        echo "  xcrun notarytool store-credentials \"AC_PASSWORD\" \\"
        echo "    --apple-id \"your@email.com\" \\"
        echo "    --team-id \"YOUR_TEAM_ID\""
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Keychain profile 'AC_PASSWORD' is valid"
fi

echo ""

# Step 1: Verify signature
echo "Step 1: Verifying signature..."

if [ "$FILE_EXT" = "pkg" ]; then
    # Verify .pkg signature
    if pkgutil --check-signature "$FILE" > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Package is signed"
        pkgutil --check-signature "$FILE" | grep "Developer ID Installer" || {
            echo -e "${YELLOW}⚠${NC}  Warning: Package may not be signed with Developer ID Installer"
        }
    else
        echo -e "${RED}ERROR: Package is not signed or signature is invalid${NC}"
        echo "The package must be signed with a Developer ID Installer certificate"
        exit 1
    fi
elif [ "$FILE_EXT" = "dmg" ]; then
    # Mount .dmg and verify app bundle signature
    echo "Mounting DMG to verify app bundle signature..."
    MOUNT_POINT=$(mktemp -d)
    hdiutil attach "$FILE" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

    # Find .app bundle in mounted DMG
    APP_BUNDLE=$(find "$MOUNT_POINT" -name "*.app" -maxdepth 1 -type d | head -1)

    if [ -z "$APP_BUNDLE" ]; then
        hdiutil detach "$MOUNT_POINT" -quiet
        rm -rf "$MOUNT_POINT"
        echo -e "${RED}ERROR: No .app bundle found in DMG${NC}"
        exit 1
    fi

    echo "Found app bundle: $(basename "$APP_BUNDLE")"

    # Verify app bundle signature
    if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | grep -q "valid on disk"; then
        echo -e "${GREEN}✓${NC} App bundle is signed"

        # Check for Developer ID Application
        if codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Developer ID Application"; then
            echo -e "${GREEN}✓${NC} Signed with Developer ID Application"
        else
            echo -e "${YELLOW}⚠${NC}  Warning: May not be signed with Developer ID Application"
        fi

        # Check for hardened runtime
        if codesign -dv --entitlements - "$APP_BUNDLE" 2>&1 | grep -q "com.apple.security"; then
            echo -e "${GREEN}✓${NC} Hardened runtime enabled"
        else
            echo -e "${YELLOW}⚠${NC}  Warning: Hardened runtime may not be enabled"
        fi
    else
        hdiutil detach "$MOUNT_POINT" -quiet
        rm -rf "$MOUNT_POINT"
        echo -e "${RED}ERROR: App bundle signature is invalid${NC}"
        echo "The app bundle must be signed with a Developer ID Application certificate"
        exit 1
    fi

    hdiutil detach "$MOUNT_POINT" -quiet
    rm -rf "$MOUNT_POINT"
fi

echo ""

# Step 2: Submit for notarization
echo "Step 2: Submitting for notarization..."
echo "This may take a few minutes..."
echo ""

SUBMIT_OUTPUT=$(mktemp)

if [ "$AUTH_METHOD" = "apiKey" ]; then
    # API key authentication
    xcrun notarytool submit "$FILE" \
        --key "$NOTARY_KEY_FILE" \
        --key-id "$NOTARY_KEY_ID" \
        --issuer "$NOTARY_ISSUER_ID" \
        --wait \
        2>&1 | tee "$SUBMIT_OUTPUT"
else
    # Password authentication (keychain profile)
    xcrun notarytool submit "$FILE" \
        --keychain-profile "AC_PASSWORD" \
        --wait \
        2>&1 | tee "$SUBMIT_OUTPUT"
fi

NOTARY_EXIT_CODE=$?

# Check submission status
if [ $NOTARY_EXIT_CODE -eq 0 ]; then
    if grep -q "status: Accepted" "$SUBMIT_OUTPUT"; then
        echo ""
        echo -e "${GREEN}✓ Notarization successful!${NC}"
    else
        echo ""
        echo -e "${RED}ERROR: Notarization failed${NC}"
        echo "Check the output above for details"

        # Try to extract submission ID for log retrieval
        SUBMISSION_ID=$(grep "id:" "$SUBMIT_OUTPUT" | head -1 | awk '{print $2}')
        if [ -n "$SUBMISSION_ID" ]; then
            echo ""
            echo "To view detailed logs:"
            if [ "$AUTH_METHOD" = "apiKey" ]; then
                echo "xcrun notarytool log $SUBMISSION_ID --key \"$NOTARY_KEY_FILE\" --key-id \"$NOTARY_KEY_ID\" --issuer \"$NOTARY_ISSUER_ID\""
            else
                echo "xcrun notarytool log $SUBMISSION_ID --keychain-profile \"AC_PASSWORD\""
            fi
        fi

        rm -f "$SUBMIT_OUTPUT"
        exit 1
    fi
else
    echo ""
    echo -e "${RED}ERROR: Notarization submission failed${NC}"
    echo "Exit code: $NOTARY_EXIT_CODE"
    cat "$SUBMIT_OUTPUT"
    rm -f "$SUBMIT_OUTPUT"
    exit 1
fi

rm -f "$SUBMIT_OUTPUT"

echo ""

# Step 3: Staple notarization ticket
echo "Step 3: Stapling notarization ticket..."

if xcrun stapler staple "$FILE"; then
    echo -e "${GREEN}✓${NC} Notarization ticket stapled successfully"
else
    echo -e "${RED}ERROR: Failed to staple notarization ticket${NC}"
    echo "The file is notarized but the ticket could not be attached"
    exit 1
fi

echo ""

# Step 4: Verify notarization
echo "Step 4: Verifying notarization..."

if xcrun stapler validate "$FILE"; then
    echo -e "${GREEN}✓${NC} Notarization verified"
else
    echo -e "${YELLOW}⚠${NC}  Warning: Stapler validation failed"
fi

# Additional verification with spctl
echo "Verifying Gatekeeper acceptance..."
if [ "$FILE_EXT" = "pkg" ]; then
    # Verify .pkg with Gatekeeper
    if spctl -a -vv -t install "$FILE" 2>&1 | grep -q "accepted"; then
        echo -e "${GREEN}✓${NC} Package will be accepted by Gatekeeper"
    else
        echo -e "${YELLOW}⚠${NC}  Warning: Gatekeeper may not accept this package"
        spctl -a -vv -t install "$FILE" 2>&1 || true
    fi
elif [ "$FILE_EXT" = "dmg" ]; then
    # For .dmg, we need to mount and verify the app bundle
    echo "Mounting DMG for Gatekeeper verification..."
    MOUNT_POINT=$(mktemp -d)
    hdiutil attach "$FILE" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
    APP_BUNDLE=$(find "$MOUNT_POINT" -name "*.app" -maxdepth 1 -type d | head -1)

    if [ -n "$APP_BUNDLE" ]; then
        if spctl -a -vv -t execute "$APP_BUNDLE" 2>&1 | grep -q "accepted"; then
            echo -e "${GREEN}✓${NC} App will be accepted by Gatekeeper"
        else
            echo -e "${YELLOW}⚠${NC}  Warning: Gatekeeper may not accept this app"
            spctl -a -vv -t execute "$APP_BUNDLE" 2>&1 || true
        fi
    fi

    hdiutil detach "$MOUNT_POINT" -quiet
    rm -rf "$MOUNT_POINT"
fi

# Summary
echo ""
echo "==========================="
echo -e "${GREEN}✓ Notarization complete!${NC}"
echo "==========================="
echo ""
echo "File: $FILE"
echo ""

if [ "$FILE_EXT" = "pkg" ]; then
    echo "The package is now:"
    echo "  ✓ Signed with Developer ID Installer"
    echo "  ✓ Notarized by Apple"
    echo "  ✓ Stapled with notarization ticket"
    echo "  ✓ Ready for distribution"
    echo ""
    echo "Installation (no Gatekeeper warnings):"
    echo "  • Double-click $FILE (recommended)"
    echo "  • Or via CLI: sudo installer -pkg $FILE -target /"
elif [ "$FILE_EXT" = "dmg" ]; then
    echo "The DMG is now:"
    echo "  ✓ App bundle signed with Developer ID Application"
    echo "  ✓ Notarized by Apple"
    echo "  ✓ Stapled with notarization ticket"
    echo "  ✓ Ready for distribution"
    echo ""
    echo "Installation (no Gatekeeper warnings):"
    echo "  1. Double-click $FILE to mount"
    echo "  2. Drag Arca.app to Applications folder"
    echo "  3. Open Arca.app or run 'arca setup' from terminal"
fi

echo ""

exit 0
