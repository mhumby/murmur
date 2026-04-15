"""Text inserter — pastes text into the focused app via clipboard + Cmd+V."""

import subprocess
import time
import pyperclip


def type_text(text: str) -> None:
    """Set clipboard and simulate Cmd+V in the frontmost application."""
    if not text:
        return

    pyperclip.copy(text)
    time.sleep(0.05)

    # AppleScript: tell the frontmost app to paste via Cmd+V
    script = '''
    tell application "System Events"
        set frontApp to name of first application process whose frontmost is true
        tell process frontApp
            keystroke "v" using command down
        end tell
    end tell
    '''
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True, text=True, timeout=5,
    )

    if result.returncode != 0:
        print(f"[murmur] Paste failed: {result.stderr.strip()}")
        print(f"[murmur] Text is on clipboard — Cmd+V to paste manually.")
    else:
        print(f"[murmur] Pasted: {text[:60]}")
