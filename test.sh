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
    "$PROJECT_DIR/Sources/PlaybackEvidence.swift" "$PROJECT_DIR/Sources/PreplayPolicy.swift" \
    "$PROJECT_DIR/Sources/AudioFailure.swift" "$PROJECT_DIR/Sources/MediaTransport.swift" "$PROJECT_DIR/Tests/main.swift" \
    -o "$BUILD_DIR/evidence-tests"
"$BUILD_DIR/evidence-tests"
xcrun clang -std=c11 -O1 -g -Wall -Wextra -Werror -fsanitize=address,undefined \
    -fno-omit-frame-pointer -I "$PROJECT_DIR/Native" \
    "$PROJECT_DIR/Native/PlaybackBuffer.c" "$PROJECT_DIR/Tests/playback_buffer.c" \
    -o "$BUILD_DIR/buffer-tests"
"$BUILD_DIR/buffer-tests"
