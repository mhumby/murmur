"""Text inserter — pastes text into the focused app via clipboard + Cmd+V."""

import logging
import time
import pyperclip
from Quartz import (
    CGEventCreateKeyboardEvent,
    CGEventSetFlags,
    CGEventPost,
    CGPreflightPostEventAccess,
    kCGHIDEventTap,
    kCGEventFlagMaskCommand,
)

log = logging.getLogger("murmur")

V_KEY_CODE = 9  # macOS virtual key code for "V"


def _simulate_cmd_v() -> bool:
    """Simulate Cmd+V using Quartz CGEvent. Returns True if we have permission."""
    if not CGPreflightPostEventAccess():
        return False

    event_down = CGEventCreateKeyboardEvent(None, V_KEY_CODE, True)
    CGEventSetFlags(event_down, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, event_down)

    event_up = CGEventCreateKeyboardEvent(None, V_KEY_CODE, False)
    CGEventSetFlags(event_up, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, event_up)
    return True


def type_text(text: str) -> bool:
    """Copy text to clipboard and attempt to paste via Cmd+V.

    Returns True if auto-paste succeeded, False if clipboard-only.
    """
    if not text:
        return False

    pyperclip.copy(text)
    log.info(f"Clipboard set: {text[:60]}")
    time.sleep(0.05)

    if _simulate_cmd_v():
        log.info("Pasted via CGEvent")
        return True
    else:
        log.warning("No Accessibility permission — text on clipboard only")
        return False
