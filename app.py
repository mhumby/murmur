"""Murmur — local voice-to-text for macOS, powered by Whisper on Apple Silicon."""

import logging
import os
import subprocess
import threading
import rumps
from Cocoa import NSEvent, NSKeyDownMask, NSFlagsChangedMask, NSAlternateKeyMask, NSEventModifierFlagFunction

from recorder import AudioRecorder
from transcriber import Transcriber
import text_inserter

log = logging.getLogger("murmur")

# Hotkey: ⌥Space (Option + Space)
HOTKEY_KEY_CODE = 49
HOTKEY_MODIFIER = NSAlternateKeyMask
HOTKEY_DISPLAY = "⌥Space / fn"

ICON_IDLE = "🎤"
ICON_RECORDING = "🔴"
ICON_PROCESSING = "⏳"

MODEL_OPTIONS = {
    "Tiny  (fastest)":   "mlx-community/whisper-tiny-mlx",
    "Base  (balanced)":  "mlx-community/whisper-base-mlx",
    "Small (accurate)":  "mlx-community/whisper-small-mlx",
}
DEFAULT_MODEL_KEY = "Base  (balanced)"


def _play_sound(name: str) -> None:
    """Play a macOS system sound (non-blocking)."""
    path = f"/System/Library/Sounds/{name}.aiff"
    subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _check_accessibility() -> bool:
    """Check if we have Accessibility permission. If not, prompt the system dialog."""
    from ApplicationServices import AXIsProcessTrustedWithOptions
    from CoreFoundation import CFDictionaryCreate, kCFBooleanTrue
    # kAXTrustedCheckOptionPrompt = True triggers the macOS system dialog
    options = {
        "AXTrustedCheckOptionPrompt": kCFBooleanTrue,
    }
    return AXIsProcessTrustedWithOptions(options)


class MurmurApp(rumps.App):
    def __init__(self):
        super().__init__("Murmur", icon=None, quit_button="Quit")
        self.title = ICON_IDLE

        self._recorder = AudioRecorder()
        self._transcriber = Transcriber(MODEL_OPTIONS[DEFAULT_MODEL_KEY])
        self._is_recording = False

        # Build menu
        self._toggle_item = rumps.MenuItem(
            f"Start Recording  ({HOTKEY_DISPLAY})",
            callback=self._on_toggle,
        )
        self._model_items: dict[str, rumps.MenuItem] = {}
        model_menu = rumps.MenuItem("Whisper Model")
        for label in MODEL_OPTIONS:
            item = rumps.MenuItem(label, callback=self._on_model_select)
            item.state = 1 if label == DEFAULT_MODEL_KEY else 0
            model_menu.add(item)
            self._model_items[label] = item

        self.menu = [self._toggle_item, None, model_menu]

        self._register_hotkey()

        # Check Accessibility on startup
        if not _check_accessibility():
            log.warning("Accessibility permission not granted — auto-paste will not work")
            rumps.notification(
                title="Murmur — Setup Required",
                subtitle="Accessibility permission needed for auto-paste",
                message="System Settings → Privacy & Security → Accessibility → add Python (or your terminal app). Without this, text is copied to clipboard only.",
            )

    # ------------------------------------------------------------------
    # Hotkey — uses Cocoa NSEvent global monitor
    # ------------------------------------------------------------------

    def _register_hotkey(self) -> None:
        NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSKeyDownMask,
            self._handle_global_key,
        )
        self._fn_was_down = False
        NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSFlagsChangedMask,
            self._handle_flags_changed,
        )

    def _handle_global_key(self, event) -> None:
        if event.keyCode() == HOTKEY_KEY_CODE and (event.modifierFlags() & HOTKEY_MODIFIER):
            rumps.Timer(self._toggle_recording_main_thread, 0).start()

    def _handle_flags_changed(self, event) -> None:
        fn_down = bool(event.modifierFlags() & NSEventModifierFlagFunction)
        if fn_down and not self._fn_was_down:
            rumps.Timer(self._toggle_recording_main_thread, 0).start()
        self._fn_was_down = fn_down

    def _toggle_recording_main_thread(self, _timer) -> None:
        _timer.stop()
        self._toggle_recording()

    # ------------------------------------------------------------------
    # Recording
    # ------------------------------------------------------------------

    def _on_toggle(self, _) -> None:
        self._toggle_recording()

    def _toggle_recording(self) -> None:
        if self._is_recording:
            self._stop_recording()
        else:
            self._start_recording()

    def _start_recording(self) -> None:
        self._is_recording = True
        self.title = ICON_RECORDING
        self._toggle_item.title = f"Stop Recording  (click or {HOTKEY_DISPLAY})"
        self._recorder.start()
        _play_sound("Tink")
        log.info("Recording started")

    def _stop_recording(self) -> None:
        self._is_recording = False
        self.title = ICON_PROCESSING
        self._toggle_item.title = "Processing…"
        audio = self._recorder.stop()
        _play_sound("Pop")
        log.info("Recording stopped")
        threading.Thread(
            target=self._transcribe_and_type, args=(audio,), daemon=True
        ).start()

    def _transcribe_and_type(self, audio) -> None:
        log.info(f"Transcribing {len(audio)/16000:.1f}s of audio...")
        text = self._transcriber.transcribe(audio)
        log.info(f"Result: {text!r}")
        if text:
            pasted = text_inserter.type_text(text)
            if pasted:
                rumps.notification("Murmur", "", text[:120])
            else:
                rumps.notification(
                    "Murmur",
                    "Copied to clipboard",
                    f"{text[:100]}  — press Cmd+V to paste",
                )
        else:
            log.info("No text detected.")
            rumps.notification("Murmur", "", "No speech detected — try again")
        rumps.Timer(self._reset_ui, 0).start()

    def _reset_ui(self, _timer) -> None:
        _timer.stop()
        self.title = ICON_IDLE
        self._toggle_item.title = f"Start Recording  ({HOTKEY_DISPLAY})"

    # ------------------------------------------------------------------
    # Model selection
    # ------------------------------------------------------------------

    def _on_model_select(self, sender) -> None:
        for label, item in self._model_items.items():
            item.state = 1 if item is sender else 0
        model_id = MODEL_OPTIONS[sender.title]
        self._transcriber = Transcriber(model_id)


if __name__ == "__main__":
    log_path = os.path.expanduser("~/Library/Logs/Murmur.log")
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_path),
            logging.StreamHandler(),
        ],
    )
    log.info("Murmur starting...")
    MurmurApp().run()
