#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    printf 'Usage: bash package.sh [--arch native|arm64|x86_64|universal]\n'
    printf 'Build the app, create a release ZIP and SHA-256 checksum in dist/.\n'
    exit 0
fi
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$PROJECT_DIR/build.sh" "$@"
VERSION="$(cat "$PROJECT_DIR/VERSION")"
APP_DIR="$PROJECT_DIR/dist/AudioRateMatch.app"
ARCHITECTURES="$(/usr/bin/lipo -archs "$APP_DIR/Contents/MacOS/AudioRateMatch")"
case "$ARCHITECTURES" in
    arm64|x86_64) ARCH_LABEL="$ARCHITECTURES" ;;
    *) ARCH_LABEL="universal" ;;
esac
ZIP_NAME="AudioRateMatch-$VERSION-macOS-$ARCH_LABEL.zip"
# ditto preserves the executable modes and app bundle metadata.
/usr/bin/ditto -c -k --keepParent --norsrc "$APP_DIR" "$PROJECT_DIR/dist/$ZIP_NAME"
(
    cd "$PROJECT_DIR/dist"
    /usr/bin/shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)
printf 'Packaged %s\n' "$PROJECT_DIR/dist/$ZIP_NAME"
