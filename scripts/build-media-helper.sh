#!/bin/bash
set -euo pipefail
# No Homebrew/runtime dependency: build the vendored BSD adapter using Apple clang.
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HELPER_DIR="$1"
shift
VENDOR_DIR="$PROJECT_DIR/Vendor/mediaremote-adapter"
mkdir -p "$HELPER_DIR/MediaRemoteAdapter.framework/Versions/A/Resources"
BINARIES=()
for TARGET_ARCH in "$@"; do
    TARGET_FILE="$HELPER_DIR/adapter-$TARGET_ARCH"
    xcrun clang -arch "$TARGET_ARCH" -mmacosx-version-min=14.2 -O2 -fobjc-arc \
        -dynamiclib -install_name '@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter' \
        -I "$VENDOR_DIR/include" -I "$VENDOR_DIR/src" \
        "$VENDOR_DIR"/src/adapter/*.m "$VENDOR_DIR"/src/private/*.m "$VENDOR_DIR"/src/utility/*.m \
        -framework Foundation -framework AppKit -framework UniformTypeIdentifiers -o "$TARGET_FILE"
    BINARIES+=("$TARGET_FILE")
done
FRAMEWORK="$HELPER_DIR/MediaRemoteAdapter.framework"
xcrun lipo -create "${BINARIES[@]}" -output "$FRAMEWORK/Versions/A/MediaRemoteAdapter"
rm "${BINARIES[@]}"
cat > "$FRAMEWORK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MediaRemoteAdapter</string>
<key>CFBundleIdentifier</key><string>local.audioratematch.MediaRemoteAdapter</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleVersion</key><string>0</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(cat "$PROJECT_DIR/VERSION")" "$FRAMEWORK/Versions/A/Resources/Info.plist"
ln -s A "$FRAMEWORK/Versions/Current"
ln -s Versions/Current/MediaRemoteAdapter "$FRAMEWORK/MediaRemoteAdapter"
ln -s Versions/Current/Resources "$FRAMEWORK/Resources"
cp "$VENDOR_DIR/bin/mediaremote-adapter.pl" "$HELPER_DIR/mediaremote-adapter.pl"
codesign --force --sign - "$FRAMEWORK"
