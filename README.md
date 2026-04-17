# Murmur

Local voice-to-text dictation for macOS, powered by [Whisper](https://github.com/openai/whisper) running on Apple Silicon via [MLX](https://github.com/ml-explore/mlx).

Press `fn`, speak, press `fn` again — your words are transcribed and pasted wherever the cursor is. No cloud, no subscription, fully offline.

## Why I built this

I work remotely, which means everything happens through Slack, email, and text — voice calls are rarely an option. Being able to type as fast as I think matters a lot.

I started using a popular AI dictation app to keep up. It worked well enough, but at £19/month it costs as much as a full AI assistant like ChatGPT or Claude. The free tier came with a 2,000 word limit, which disappeared fast. Even on the paid plan, punctuation was hit-or-miss — full stops and commas would often go missing, turning spoken sentences into one long run-on that needed heavy editing afterwards.

So I built Murmur instead. It runs entirely on-device using OpenAI's Whisper model, optimised for Apple Silicon via MLX. No subscription, no word limits, no audio leaving your machine.

## Requirements

- macOS on Apple Silicon (M1/M2/M3/M4)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3.13+ (via Homebrew: `brew install python@3.13`)

## Install

```bash
git clone https://github.com/mhumby/murmur.git
cd murmur
./setup.sh        # creates Python venv, installs ML dependencies
./build_app.sh    # compiles the native Swift app
cp -r Murmur.app /Applications/
open /Applications/Murmur.app
```

On first launch, macOS will prompt for:
- **Accessibility** — required for auto-paste (simulates Cmd+V)
- **Microphone** — required for recording
- **Notifications** — optional, shows transcribed text

The first recording downloads the Whisper model (~150 MB for "base"). After that it works fully offline.

## Usage

| Action | How |
|---|---|
| **Start recording** | Press `fn` or `Option+Space` |
| **Stop & transcribe** | Press `fn` or `Option+Space` again |
| **Switch model** | Menu bar icon > Whisper Model |
| **Quit** | Menu bar icon > Quit Murmur |

### Menu bar icon

| Icon | Meaning |
|---|---|
| Microphone | Idle, ready to record |
| Red circle | Recording — speak now |
| Hourglass | Transcribing |

A sound plays when recording starts (Tink) and stops (Pop).

### Alternative: run from terminal

If you prefer running from the terminal without building the .app:

```bash
./run.sh
```

This uses the Python-based menu bar app directly. Auto-paste works if your terminal app has Accessibility permission.

## macOS setup

### fn key

By default, macOS maps the `fn`/Globe key to the emoji picker. To use it with Murmur:

1. Open **System Settings** > **Keyboard**
2. Set **"Press fn key to"** to **"Do Nothing"**

### Accessibility troubleshooting

If text doesn't auto-paste after transcription:

1. Open **System Settings** > **Privacy & Security** > **Accessibility**
2. Remove any old Murmur entries
3. Click **+** and add **Murmur** from `/Applications/Murmur.app`
4. Make sure the toggle is **on**
5. Quit and relaunch Murmur

## Models

Switch models from the menu bar:

| Model | Download size | Speed | Best for |
|---|---|---|---|
| **Tiny** | ~75 MB | Fastest | Quick notes, short commands |
| **Base** | ~150 MB | Fast | General dictation (default) |
| **Small** | ~500 MB | Moderate | Longer passages, accented speech |

Models are downloaded once from [Hugging Face](https://huggingface.co/mlx-community) and cached at `~/.cache/huggingface/hub/`.

## Architecture

Murmur is a **native Swift menu bar app** that calls Python only for ML inference:

```
┌─────────────────────────────┐
│    Murmur.app (Swift)       │
│  - Menu bar + hotkey        │
│  - Accessibility (CGEvent)  │
│  - Clipboard + Cmd+V paste  │
└──────────┬──────────────────┘
           │ subprocess
     ┌─────▼─────┐      ┌──────────────┐
     │ record_cli │      │transcribe_cli│
     │  (Python)  │      │   (Python)   │
     │ sounddevice│      │  mlx-whisper │
     └────────────┘      └──────────────┘
```

1. **Hotkey** — Swift registers `fn` and `Option+Space` via `NSEvent` global monitor
2. **Recording** — Python subprocess captures audio at 16 kHz, saves to WAV
3. **Silence trimming** — trailing silence is stripped to prevent Whisper hallucinations
4. **Transcription** — Python subprocess runs Whisper via `mlx-whisper`, prints text to stdout
5. **Paste** — Swift reads the text, copies to clipboard, simulates `Cmd+V` via `CGEvent`

All processing happens locally on-device.

## Building the Swift app

The Swift app is a single file at `swift/Murmur.swift`. To compile:

```bash
./build_app.sh
```

This runs:

```bash
swiftc -O \
    -o Murmur.app/Contents/MacOS/Murmur \
    swift/Murmur.swift \
    -framework Cocoa \
    -framework Carbon \
    -framework ApplicationServices
```

The build script also generates the `Info.plist` (with `LSUIElement` to hide from the Dock) and ad-hoc signs the binary.

To install after building:

```bash
cp -r Murmur.app /Applications/
xattr -cr /Applications/Murmur.app    # clear quarantine if needed
open /Applications/Murmur.app
```

## Project structure

```
murmur/
  swift/
    Murmur.swift        native macOS app — menu bar, hotkey, paste
  record_cli.py         audio recording subprocess (sounddevice → WAV)
  transcribe_cli.py     transcription subprocess (mlx-whisper)
  app.py                Python-based menu bar app (alternative to Swift)
  recorder.py           audio recorder module (used by app.py)
  transcriber.py        transcriber module (used by app.py)
  text_inserter.py      text paste module (used by app.py)
  build_app.sh          builds Murmur.app from Swift source
  setup.sh              Python venv and dependency install
  run.sh                launch Python-based app from terminal
  requirements.txt      Python dependencies
```

## Troubleshooting

**Text doesn't appear after transcription**
- Check Accessibility permission for Murmur (see above)
- If you previously had a Python-based Murmur in Accessibility, remove it and re-add the new one

**fn key opens emoji picker**
- Set "Press fn key to" to "Do Nothing" in System Settings > Keyboard

**Empty transcription / no result**
- Speak for at least 1 second — clips under 0.5s are discarded
- Check your microphone: `python3 -c "import sounddevice; print(sounddevice.query_devices())"`

**Hallucinated or repeated text**
- Murmur filters hallucination loops automatically
- Switch to the Small model for better accuracy

**App shows "damaged" or won't open**
- Run `xattr -cr /Applications/Murmur.app` to clear the quarantine flag

**Logs**
- View logs at `~/Library/Logs/Murmur.log`

## Versioning

Murmur follows [Semantic Versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

The version lives in a single `VERSION` file at the repo root. `build_app.sh` reads it and injects the value into `CFBundleVersion` and `CFBundleShortVersionString` in the generated `Info.plist`, so the menu bar "Murmur vX.Y.Z" entry, the startup log line, and the macOS "About" dialog all stay in sync.

When to bump which component:

| Component | When to bump | Example |
|---|---|---|
| **MAJOR** | Breaking change users must act on (e.g. new required permission, changed hotkey, incompatible config) | `1.4.0` to `2.0.0` |
| **MINOR** | New feature, backwards compatible (e.g. new model, new hotkey option, UI addition) | `1.4.0` to `1.5.0` |
| **PATCH** | Bug fix or internal refactor, no user-visible change | `1.4.0` to `1.4.1` |

Release workflow:

```bash
# 1. Bump the file (commit as part of your change PR)
echo "1.4.1" > VERSION

# 2. After the PR merges to main, tag and push
git tag v1.4.1
git push origin v1.4.1
```

## Contributing

Issues and suggestions are welcome. PRs require approval from the maintainer.

## License

MIT
