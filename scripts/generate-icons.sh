#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/icons"
mkdir -p "$BUILD_DIR/module-cache" "$PROJECT_DIR/Resources"
/usr/bin/xcrun swiftc -swift-version 5 \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Artwork/GenerateIcon.swift" -framework AppKit \
    -o "$BUILD_DIR/generate-icon"
"$BUILD_DIR/generate-icon" "$BUILD_DIR/AppIcon.iconset" "$PROJECT_DIR/Resources/AppIcon.png"
/usr/bin/iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$PROJECT_DIR/Resources/AppIcon.icns"
printf 'Generated Resources/AppIcon.icns and Resources/AppIcon.png\n'
