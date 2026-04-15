"""Murmur — local voice-to-text for macOS, powered by Whisper on Apple Silicon."""

import threading
import rumps
from pynput import keyboard as pynput_keyboard

from recorder import AudioRecorder
from transcriber import Transcriber
import text_inserter as text_typer

HOTKEY = "<alt>space"   # ⌥Space  — change to e.g. "<ctrl><shift>d" if preferred

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
        self._hotkey_listener: pynput_keyboard.Listener | None = None

        # Build menu
        self._toggle_item = rumps.MenuItem(
            f"Start Recording  ({_hotkey_display(HOTKEY)})",
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

        self._start_hotkey_listener()

    # ------------------------------------------------------------------
    # Hotkey
    # ------------------------------------------------------------------

    def _start_hotkey_listener(self) -> None:
        hotkey = pynput_keyboard.HotKey(
            pynput_keyboard.HotKey.parse(HOTKEY),
            self._on_hotkey,
        )

        def canonical_press(key):
            hotkey.press(self._hotkey_listener.canonical(key))  # type: ignore[union-attr]

        def canonical_release(key):
            hotkey.release(self._hotkey_listener.canonical(key))  # type: ignore[union-attr]

        self._hotkey_listener = pynput_keyboard.Listener(
            on_press=canonical_press,
            on_release=canonical_release,
        )
        self._hotkey_listener.daemon = True
        self._hotkey_listener.start()

    def _on_hotkey(self) -> None:
        # HotKey fires on the listener thread — bounce to main thread via timer.
        rumps.Timer(self._toggle_recording_main_thread, 0).start()

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
        self._toggle_item.title = "Stop Recording  (click or ⌥Space)"
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
        text = self._transcriber.transcribe(audio)
        if text:
            text_typer.type_text(text)
        # Reset UI on main thread
        rumps.Timer(self._reset_ui, 0).start()

    def _reset_ui(self, _timer) -> None:
        _timer.stop()
        self.title = ICON_IDLE
        self._toggle_item.title = f"Start Recording  ({_hotkey_display(HOTKEY)})"

    # ------------------------------------------------------------------
    # Model selection
    # ------------------------------------------------------------------

    def _on_model_select(self, sender) -> None:
        for label, item in self._model_items.items():
            item.state = 1 if item is sender else 0
        model_id = MODEL_OPTIONS[sender.title]
        self._transcriber = Transcriber(model_id)


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _hotkey_display(hotkey_str: str) -> str:
    return (
        hotkey_str.replace("<alt>", "⌥")
        .replace("<cmd>", "⌘")
        .replace("<ctrl>", "⌃")
        .replace("<shift>", "⇧")
        .replace("space", "Space")
    )


if __name__ == "__main__":
    MurmurApp().run()
