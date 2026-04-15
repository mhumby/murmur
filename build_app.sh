#!/usr/bin/env bash
set -e

APP_NAME="Murmur"
APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building $APP_NAME.app..."

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# --- Compile Swift app ---
echo "Compiling Swift..."
swiftc -O \
    -o "$MACOS/Murmur" \
    swift/Murmur.swift \
    -framework Cocoa \
    -framework Carbon \
    -framework ApplicationServices

# --- Info.plist ---
cat > "$CONTENTS/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Murmur</string>
    <key>CFBundleDisplayName</key>
    <string>Murmur</string>
    <key>CFBundleIdentifier</key>
    <string>com.mhumby.murmur</string>
    <key>CFBundleVersion</key>
    <string>1.3</string>
    <key>CFBundleShortVersionString</key>
    <string>1.3</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur needs microphone access to record your voice for transcription.</string>
</dict>
</plist>
PLIST

# --- Ad-hoc sign ---
codesign --force --deep --sign - "$APP_DIR"

echo ""
echo "  Built: $SCRIPT_DIR/$APP_DIR"
echo ""
echo "  Install:"
echo "    cp -r $APP_DIR /Applications/"
echo ""
echo "  Launch:"
echo "    open /Applications/Murmur.app"
echo ""
echo "  On first launch, macOS will prompt for:"
echo "    - Accessibility (for auto-paste)"
echo "    - Microphone (for recording)"
echo ""
