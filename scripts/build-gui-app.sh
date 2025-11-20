#!/bin/bash
#
# Build Arca GUI App
# Compiles the SwiftUI macOS app and creates Arca.app bundle
#

set -e

# Configuration
CONFIGURATION="${1:-release}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GUI_SRC="$ROOT_DIR/ArcaApp/ArcaApp"
BUILD_DIR="$ROOT_DIR/.build-gui"
DERIVED_DATA="$BUILD_DIR/DerivedData"

echo "Building Arca GUI App (${CONFIGURATION})..."

# Clean build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$DERIVED_DATA"

# Build Swift files
echo "Compiling Swift sources..."
swiftc \
    -o "$BUILD_DIR/ArcaApp" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "arm64-apple-macos15.0" \
    -O \
    -whole-module-optimization \
    -enable-library-evolution \
    -import-objc-header "$GUI_SRC/ArcaApp-Bridging-Header.h" 2>/dev/null || \
swiftc \
    -o "$BUILD_DIR/ArcaApp" \
    -sdk "$(xcrun --show-sdk-path)" \
    -target "arm64-apple-macos15.0" \
    -O \
    -whole-module-optimization \
    -enable-library-evolution \
    "$GUI_SRC/ArcaApp.swift" \
    "$GUI_SRC/ContentView.swift" \
    "$GUI_SRC/SetupManager.swift"

echo "✓ GUI app binary built: $BUILD_DIR/ArcaApp"
