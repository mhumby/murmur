#!/usr/bin/env bash
set -e

APP_NAME="Murmur"
APP_DIR="$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_PATH="$SCRIPT_DIR/.venv"

# --- Read version from VERSION file (single source of truth) ---
VERSION_FILE="$SCRIPT_DIR/VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: VERSION file not found at $VERSION_FILE"
    exit 1
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Error: VERSION must be MAJOR.MINOR.PATCH (got: '$VERSION')"
    exit 1
fi

echo "Building $APP_NAME.app v$VERSION..."

if [ ! -f "$VENV_PATH/bin/python" ]; then
    echo "Error: .venv not found. Run ./setup.sh first."
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

# --- Bundle Python scripts into Resources ---
cp record_cli.py "$RESOURCES/"
cp transcribe_cli.py "$RESOURCES/"

# --- Bundle the Python venv into Resources so the .app is self-contained ---
# The bundled venv still relies on Homebrew Python 3.13 being present on the
# target Mac (/opt/homebrew/opt/python@3.13/bin/python3.13), via the symlink
# inside bin/ and the `home` entry in pyvenv.cfg. This is already a stated
# requirement. Wheels and site-packages travel with the app.
echo "Bundling venv into Resources (this can take a moment)..."
cp -R "$VENV_PATH" "$RESOURCES/venv"

# Trim cruft we don't need at runtime to keep the bundle small.
find "$RESOURCES/venv" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "$RESOURCES/venv" -type f -name "*.pyc" -delete 2>/dev/null || true

# --- Compile Swift app ---
echo "Compiling Swift..."
swiftc -O \
    -o "$MACOS/Murmur" \
    swift/main.swift \
    swift/Transcribers.swift \
    swift/AppState.swift \
    swift/MainWindow.swift \
    swift/HistoryStore.swift \
    swift/KeychainHelper.swift \
    swift/SettingsStore.swift \
    swift/OpenAINetworking.swift \
    swift/VocabularyStore.swift \
    -framework Cocoa \
    -framework Carbon \
    -framework ApplicationServices \
    -framework SwiftUI

# --- Info.plist (MurmurVenvPath written at build time) ---
cat > "$CONTENTS/Info.plist" << PLIST
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
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>Murmur</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur needs microphone access to record your voice for transcription.</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 2M Tech. Released under the MIT License.</string>
    <key>MurmurVenvPath</key>
    <string>$VENV_PATH</string>
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
