#!/usr/bin/env bash
set -e

# Installs the built Murmur.app into /Applications and resets the TCC
# (permissions) entries for the bundle ID. This is needed because Murmur
# is ad-hoc signed — every rebuild gets a new signature, which macOS
# treats as a different app for permission purposes. Without the reset,
# the stale entry silently blocks the re-prompt and Murmur can't record
# or paste.
#
# Usage:
#   ./build_app.sh && ./install.sh

APP_NAME="Murmur"
APP_DIR="$APP_NAME.app"
BUNDLE_ID="com.mhumby.murmur"
INSTALL_PATH="/Applications/$APP_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SCRIPT_DIR/$APP_DIR" ]; then
    echo "Error: $APP_DIR not found. Run ./build_app.sh first."
    exit 1
fi

# --- Quit any running instance ---
if pgrep -x "$APP_NAME" > /dev/null; then
    echo "Quitting running $APP_NAME..."
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    # Give it a moment, then force-kill anything that lingers
    sleep 1
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

# --- Copy to /Applications ---
echo "Installing to $INSTALL_PATH..."
rm -rf "$INSTALL_PATH"
cp -R "$SCRIPT_DIR/$APP_DIR" "/Applications/"

# --- Reset permissions so macOS re-prompts cleanly ---
# Ad-hoc signatures change per build; without this, the stale TCC entry
# blocks both the re-prompt and the granted permission.
echo "Resetting TCC permissions for $BUNDLE_ID..."
tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
tccutil reset Microphone   "$BUNDLE_ID" 2>/dev/null || true
tccutil reset ListenEvent   "$BUNDLE_ID" 2>/dev/null || true

# --- Launch ---
echo "Launching $APP_NAME..."
open "$INSTALL_PATH"

echo ""
echo "  Installed and launched."
echo "  macOS will prompt for Accessibility and Microphone on first use."
echo ""
