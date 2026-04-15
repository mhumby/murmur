"""Murmur — local voice-to-text for macOS, powered by Whisper on Apple Silicon."""

import threading
import rumps
from Cocoa import NSEvent, NSKeyDownMask, NSFlagsChangedMask, NSAlternateKeyMask, NSEventModifierFlagFunction

from recorder import AudioRecorder
from transcriber import Transcriber
import text_inserter as text_typer

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

    # ------------------------------------------------------------------
    # Hotkey — uses Cocoa NSEvent global monitor (no Accessibility needed)
    # ------------------------------------------------------------------

    def _register_hotkey(self) -> None:
        # ⌥Space
        NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            NSKeyDownMask,
            self._handle_global_key,
        )
        # fn (Globe) key — fires as a modifier flag change
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
            # fn key just pressed — toggle recording
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

    def _stop_recording(self) -> None:
        self._is_recording = False
        self.title = ICON_PROCESSING
        self._toggle_item.title = "Processing…"
        audio = self._recorder.stop()
        threading.Thread(
            target=self._transcribe_and_type, args=(audio,), daemon=True
        ).start()

    def _transcribe_and_type(self, audio) -> None:
        print(f"[murmur] Transcribing {len(audio)/16000:.1f}s of audio...")
        text = self._transcriber.transcribe(audio)
        print(f"[murmur] Result: {text!r}")
        if text:
            text_typer.type_text(text)
        else:
            print("[murmur] No text detected.")
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
    MurmurApp().run()
