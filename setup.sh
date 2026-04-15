#!/usr/bin/env bash
set -e

echo ""
echo "  Murmur — local voice-to-text for macOS"
echo "  ======================================="
echo ""

# Use Homebrew Python 3.13 for best compatibility
PYTHON=/opt/homebrew/bin/python3.13

if ! command -v "$PYTHON" &>/dev/null; then
    echo "Error: Python 3.13 not found at $PYTHON"
    echo "Install it with:  brew install python@3.13"
    exit 1
fi

# Create virtual environment if it doesn't exist
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    $PYTHON -m venv .venv
fi

source .venv/bin/activate

echo "Installing dependencies..."
pip install --upgrade pip --quiet
pip install -r requirements.txt --quiet

echo ""
echo "  Setup complete."
echo ""
echo "  Run Murmur:"
echo "    ./run.sh"
echo ""
echo "  First launch downloads the Whisper model (~150 MB for 'base')."
echo ""
echo "  macOS permissions required (one-time):"
echo "    Microphone    — macOS will prompt automatically"
echo "    Accessibility — System Settings > Privacy & Security > Accessibility"
echo "                    Add your terminal app to the allowed list"
echo ""
