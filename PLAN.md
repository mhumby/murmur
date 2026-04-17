# Murmur Pro — UI Feature Plan

## Overview

Add a main window with model selection, transcription history, and OpenAI
online transcription. The menu bar icon and fn hotkey stay exactly as they are.

---

## Online model

**OpenAI gpt-4o-transcribe** only.

- API endpoint: `POST https://api.openai.com/v1/audio/transcriptions`
- Model: `gpt-4o-transcribe`
- API key stored in macOS Keychain, never in UserDefaults or on disk in plaintext.
- Fallback: if the online call fails (no network, bad key, timeout), silently
  fall back to the active local MLX model and log the error.

---

## UI layout

```
┌─ Murmur ──────────────────────────────────┐
│  Model                                     │
│  ┌─────────────────────────────────────┐  │
│  │  Local                              │  │
│  │    Tiny  (fastest)                  │  │
│  │  ● Base  (balanced)                 │  │
│  │    Small (accurate)                 │  │
│  │  Online                             │  │
│  │    OpenAI — gpt-4o-transcribe       │  │
│  └─────────────────────────────────────┘  │
│                                            │
│  OpenAI API Key  [ ••••••••••• ] [ Edit ] │
│                                            │
│  ─────────────────────────────────────── │
│                                            │
│  History                        [ Clear ] │
│                                            │
│  14:32  base    "So the idea is to…"  📋  │
│  14:18  online  "Let me know if you…" 📋  │
│  11:07  small   "Following up on the" 📋  │
│                                            │
└────────────────────────────────────────────┘
```

Opened via: menu bar → **Open Murmur** (or Cmd+,).
App stays hidden in menu bar on launch — window only appears when explicitly opened.

---

## History

- Each entry: timestamp, model name (local or online), full transcript text.
- Persisted to `~/Library/Application Support/Murmur/history.json`.
- Click row to copy text to clipboard.
- Right-click → Delete entry.
- Clear All button wipes the file.
- Max 200 entries — oldest pruned automatically.

---

## PR breakdown

### PR 12 — Transcription protocol (`feat/transcription-protocol`)

Refactor transcription into a Swift protocol so local and online share
the same interface. No visible change to the user.

Files touched: `swift/`

```swift
protocol Transcriber {
    func transcribe(audioPath: String) async throws -> String
}

class LocalMLXTranscriber: Transcriber { ... }  // wraps existing Python subprocess
class OpenAITranscriber: Transcriber { ... }     // stub, returns "" for now
```

Version bump: none (internal refactor only).

---

### PR 13 — Main window + model picker (`feat/main-window`)

New `NSWindow` with SwiftUI content view.
- Menu bar gets an "Open Murmur" item (Cmd+,).
- Model picker replaces the existing menu submenu.
- Window shows model selector and a placeholder for history.

Files touched: `swift/`

Version bump: `1.6.0` → `1.7.0` (MINOR — new user-visible UI surface).

---

### PR 14 — History (`feat/history`)

`HistoryStore` class reads and writes `history.json`.
- Every successful transcription (local or online) is appended.
- History list in the window: timestamp, model, transcript preview.
- Click to copy. Right-click to delete. Clear All button.
- 200-entry cap, oldest pruned on append.

Files touched: `swift/`, `~/Library/Application Support/Murmur/`

Version bump: `1.7.0` → `1.8.0` (MINOR — new history feature).

---

### PR 15 — Online transcription (`feat/online-transcription`)

Full OpenAI integration.
- `URLSession`-based HTTP client — no third-party dependencies.
- API key entry sheet in the window, stored in Keychain via `SecItemAdd`.
- "OpenAI — gpt-4o-transcribe" appears in the model picker.
- On selection, `OpenAITranscriber` sends the WAV to the API, returns text.
- Fallback: on any error, logs the failure and falls back to the last-used
  local model transparently.

Files touched: `swift/`

Version bump: `1.8.0` → `1.9.0` (MINOR — new online transcription capability).

---

## Architecture after all four PRs

```
AppDelegate (menu bar, hotkeys, paste)
    │
    ├── TranscriptionService (protocol)
    │       ├── LocalMLXTranscriber   (Python subprocess — existing logic)
    │       └── OpenAITranscriber     (URLSession → OpenAI gpt-4o-transcribe)
    │
    ├── HistoryStore                  (JSON on disk, in-memory array)
    │
    └── MurmurWindowController
            └── SwiftUI ContentView
                    ├── ModelPicker
                    ├── APIKeySheet
                    └── HistoryList
```

---

## Notes

- Each PR leaves the app fully working — no half-broken states between merges.
- No third-party Swift dependencies added at any point (URLSession for HTTP,
  Keychain APIs for secrets, SwiftUI + AppKit for UI — all native).
- The fn hotkey flow is untouched throughout. The window is purely additive.
- PLAN.md (this file) is murmur-pro only — not pushed to the public repo.
