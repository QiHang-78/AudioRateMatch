#!/bin/bash
set -euo pipefail

usage() {
    cat <<'TEXT'
Usage: bash build.sh [--arch native|arm64|x86_64|universal]
Build a locally signed app in dist/AudioRateMatch.app. Default: native architecture.
Requires macOS and Apple's Command Line Tools or Xcode. Does not launch the app.
TEXT
}

ARCH="native"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)
            if [[ $# -lt 2 ]]; then usage >&2; exit 2; fi
            ARCH="$2"
            shift 2
            ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'AudioRateMatch can only be built on macOS.\n' >&2
    exit 1
fi
if [[ "$ARCH" == "native" ]]; then ARCH="$(uname -m)"; fi
case "$ARCH" in
    arm64|x86_64) ARCHITECTURES=("$ARCH") ;;
    universal) ARCHITECTURES=(arm64 x86_64) ;;
    *) printf 'Unsupported architecture: %s\n' "$ARCH" >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
OUTPUT_DIR="$PROJECT_DIR/dist"
APP_DIR="$OUTPUT_DIR/AudioRateMatch.app"
VERSION="$(cat "$PROJECT_DIR/VERSION")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'VERSION must contain a numeric major.minor.patch version.\n' >&2
    exit 1
fi
MIN_MACOS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Resources/Info.plist")"
SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/staging.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/AudioRateMatch.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

BINARIES=()
for TARGET_ARCH in "${ARCHITECTURES[@]}"; do
    TARGET_DIR="$BUILD_DIR/$TARGET_ARCH"
    mkdir -p "$TARGET_DIR/module-cache"
    printf 'Compiling %s for macOS %s+…\n' "$TARGET_ARCH" "$MIN_MACOS"
    "$SWIFTC" -swift-version 5 -O \
        -sdk "$SDK_PATH" -target "$TARGET_ARCH-apple-macosx$MIN_MACOS" \
        -module-cache-path "$TARGET_DIR/module-cache" \
        "$PROJECT_DIR"/Sources/*.swift -framework AppKit -framework CoreAudio \
        -o "$TARGET_DIR/AudioRateMatch"
    BINARIES+=("$TARGET_DIR/AudioRateMatch")
done
if [[ ${#BINARIES[@]} -eq 1 ]]; then
    cp "${BINARIES[0]}" "$STAGED_APP/Contents/MacOS/AudioRateMatch"
else
    /usr/bin/lipo -create "${BINARIES[@]}" -output "$STAGED_APP/Contents/MacOS/AudioRateMatch"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
# Replace the previous product only after compilation and signing succeed.
rm -rf "$APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
printf 'Built %s (%s, %s)\n' "$APP_DIR" "$VERSION" "$ARCH"
