# Murmur

Local voice-to-text dictation for macOS, powered by [Whisper](https://github.com/openai/whisper) running on Apple Silicon via [MLX](https://github.com/ml-explore/mlx).

Press a hotkey, speak, release — your words appear wherever the cursor is. No cloud, no subscription, fully offline.

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Python 3.13+ (via Homebrew: `brew install python@3.13`)

## Quick start

```bash
cd murmur
./setup.sh     # creates venv, installs dependencies
./run.sh       # launches Murmur in the menu bar
```

The first time you record, Murmur downloads the Whisper model (~150 MB for "base"). After that it works fully offline.

## Usage

| Action | How |
|---|---|
| **Start recording** | Press `Option + Space` (or click the menu bar icon) |
| **Stop & transcribe** | Press `Option + Space` again |
| **Switch model** | Menu bar > Whisper Model > pick one |
| **Quit** | Menu bar > Quit |

The menu bar icon shows what Murmur is doing:

- **microphone** — idle, ready to record
- **red circle** — recording
- **hourglass** — transcribing

Transcribed text is pasted at the current cursor position in whatever app is focused.

## Models

Choose from the menu bar based on your speed/accuracy preference:

| Model | Size | Speed | Best for |
|---|---|---|---|
| **Tiny** | ~75 MB | Fastest | Quick notes, short commands |
| **Base** | ~150 MB | Fast | General dictation (default) |
| **Small** | ~500 MB | Moderate | Longer passages, accented speech |

Models are downloaded once from Hugging Face and cached locally.

## macOS permissions

Murmur needs two permissions the first time you run it:

### Microphone

macOS prompts automatically. Click "Allow".

### Accessibility

Required so Murmur can paste text into the focused app (it simulates `Cmd+V`).

1. Open **System Settings** > **Privacy & Security** > **Accessibility**
2. Click the **+** button
3. Add the app you're launching Murmur from:
   - If using **Terminal**: `/System/Applications/Utilities/Terminal.app`
   - If using **iTerm2**: `/Applications/iTerm.app`
   - If using **VS Code** terminal: `/Applications/Visual Studio Code.app`
4. Make sure the toggle is **on**

## Changing the hotkey

Edit the `HOTKEY` variable at the top of `app.py`:

```python
HOTKEY = "<alt>space"          # Option + Space (default)
HOTKEY = "<cmd><shift>d"       # Cmd + Shift + D
HOTKEY = "<ctrl><shift>space"  # Ctrl + Shift + Space
```

## Project structure

```
murmur/
  app.py            — menu bar app, hotkey wiring, UI state machine
  recorder.py       — microphone capture at 16 kHz via sounddevice
  transcriber.py    — Whisper inference via mlx-whisper
  text_inserter.py  — clipboard + Cmd+V paste into focused app
  requirements.txt  — Python dependencies
  setup.sh          — one-time setup script
  run.sh            — launch script
```

## Troubleshooting

**"No text appears after transcription"**
- Check that Accessibility permission is granted for your terminal app (see above).

**"Recording but no transcription / empty result"**
- Speak for at least 1 second — very short clips are discarded.
- Check that your microphone is working: `python -c "import sounddevice; print(sounddevice.query_devices())"`.

**"Model download is slow"**
- The first download comes from Hugging Face. Subsequent runs use the cached model at `~/.cache/huggingface/hub/`.

**"High latency on transcription"**
- Switch to the Tiny model from the menu bar for faster results.
- Ensure no other heavy GPU workloads are running.

## License

MIT
