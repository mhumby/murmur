"""Text inserter — pastes transcribed text at the current cursor position."""

import subprocess
import threading
import time
import pyperclip
from pynput.keyboard import Controller, Key


_keyboard = Controller()


def _get_clipboard() -> str:
    try:
        return pyperclip.paste()
    except Exception:
        return ""


def _set_clipboard(text: str) -> None:
    try:
        pyperclip.copy(text)
    except Exception:
        pass


def type_text(text: str) -> None:
    """Insert *text* at the current cursor position via clipboard + ⌘V.

    This approach works in any app (Terminal, browser, Notes, etc.) and
    handles Unicode correctly. Requires Accessibility permission.
    """
    if not text:
        return

    # Preserve whatever was on the clipboard before we clobber it.
    previous = _get_clipboard()

    _set_clipboard(text)
    time.sleep(0.05)  # Let clipboard settle

    # Simulate ⌘V
    _keyboard.press(Key.cmd)
    _keyboard.press("v")
    _keyboard.release("v")
    _keyboard.release(Key.cmd)

    # Restore the previous clipboard after a short delay so the paste
    # completes before we overwrite it again.
    def _restore():
        time.sleep(0.4)
        _set_clipboard(previous)

    threading.Thread(target=_restore, daemon=True).start()
