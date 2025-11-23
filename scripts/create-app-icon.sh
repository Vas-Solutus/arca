#!/bin/bash
#
# Create macOS .icns app icon from PNG
# Generates all required sizes for Retina displays
#

set -e

SOURCE_PNG="${1:-assets/ArcaLogo.png}"
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"

if [ ! -f "$SOURCE_PNG" ]; then
    echo "Error: Source PNG not found: $SOURCE_PNG"
    exit 1
fi

echo "Creating app icon from $SOURCE_PNG..."

# Create iconset directory
mkdir -p "$ICONSET_DIR"

# Generate all required icon sizes
sips -z 16 16     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16.png" > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32.png" > /dev/null
sips -z 64 64     "$SOURCE_PNG" --out "$ICONSET_DIR/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$SOURCE_PNG" --out "$ICONSET_DIR/icon_512x512@2x.png" > /dev/null

# Convert to .icns
iconutil -c icns "$ICONSET_DIR" -o "ArcaApp/ArcaApp/AppIcon.icns"

# Clean up
rm -rf "$(dirname "$ICONSET_DIR")"

echo "✓ Created ArcaApp/ArcaApp/AppIcon.icns"
