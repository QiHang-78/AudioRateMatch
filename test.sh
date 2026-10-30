#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'These tests require macOS and Apple Swift.\n' >&2
    exit 1
fi
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/tests"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
mkdir -p "$BUILD_DIR/module-cache"
"$SWIFTC" -swift-version 5 -sdk "$SDK_PATH" \
    -module-cache-path "$BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Sources/PlaybackEvidence.swift" "$PROJECT_DIR/Tests/main.swift" \
    -o "$BUILD_DIR/evidence-tests"
"$BUILD_DIR/evidence-tests"
