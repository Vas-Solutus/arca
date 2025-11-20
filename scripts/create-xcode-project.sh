#!/bin/bash
#
# Create Xcode project for Arca GUI app
#

set -e

cd "$(dirname "$0")/.."

echo "Creating Xcode project for ArcaApp..."

# Create Xcode project using swift package init
cd ArcaApp
if [ ! -f "Package.swift" ]; then
    swift package init --type executable --name ArcaApp
    rm -rf Sources Tests
fi

# Generate Xcode project
swift package generate-xcodeproj

echo "✓ Xcode project created: ArcaApp/ArcaApp.xcodeproj"
echo ""
echo "To open in Xcode:"
echo "  open ArcaApp/ArcaApp.xcodeproj"
