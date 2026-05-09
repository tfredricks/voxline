# voxline — Design Spec

**Date:** 2026-05-08
**Status:** Draft, pending review
**Platform:** macOS 14+ (Apple Silicon)
**Template:** SwiftUI App, no storage

## 1. Goal

A hotkey-driven dictation app for macOS. Hold the hotkey, talk, release. Speech is transcribed locally; the transcript is cleaned by an LLM using a per-app prompt, then auto-pasted into the focused field.

Reference apps: Wispr Flow (cloud), Ghost Pepper (local), Superwhisper (modes). voxline takes the per-app prompt model from Wispr/Superwhisper but runs STT locally and uses the user's own LLM API key — no subscription.

## 2. Non-Goals (v1)

- Toggle / hands-free dictation (PTT only)
- Streaming live transcription into the field
- Transcript history view
- Snippets / personal dictionary
- Voice command parsing ("rewrite this politely")
- Window-title or selection-aware context (bundle ID only)
- iCloud sync of modes/settings
- Intel Mac support

## 3. User Flow (happy path)

1. User focuses any text field (Slack, Mail, Cursor, browser textarea, etc.)
2. User holds **Left Ctrl + Left Option**
3. Floating pill appears near the cursor with a waveform animation
4. User speaks
5. User releases either modifier
6. Pill switches to a spinner while:
   a. WhisperKit transcribes the in-memory audio buffer
   b. The frontmost app's bundle ID is resolved
   c. The matching `Mode` prompt is loaded
   d. LLM is called with `{system: prompt, user: transcript}`
7. Cleaned text is auto-pasted into the focused field via clipboard + synthetic `Cmd+V`
8. Pill disappears; clipboard is restored to its prior contents after 300ms

## 4. Architecture

Single SwiftUI macOS app, three subsystems:

### 4.1 Hotkey + Audio Capture

- Global hotkey monitoring via `CGEventTap` listening for `flagsChanged` events
- State machine: idle → armed (one modifier down) → recording (both down) → finalizing (any released)
- Mic capture via `AVAudioEngine` at 16 kHz mono PCM (Whisper's native input)
- Audio held in memory only, discarded after transcription
- Requires Accessibility + Microphone permissions on first launch (TCC prompts)

### 4.2 Local Transcription

- `WhisperKit` (`argmaxinc/WhisperKit`)
- Default model: `large-v3-turbo` (~1.5 GB), downloaded on first launch
- Runs on Apple Neural Engine via Core ML
- Synchronous batch transcription — buffer in, text out
- Fallback model: `small.en` selectable in Settings

### 4.3 LLM Cleanup + Output

- Frontmost app detected via `NSWorkspace.shared.frontmostApplication.bundleIdentifier`
- `Mode` lookup: exact bundle ID match → wildcard `*` fallback
- LLM call:
  - Provider chosen at first launch (Anthropic or OpenAI)
  - Default models: Anthropic `claude-haiku-4-5`, OpenAI `gpt-4o-mini`
  - Non-streaming for v1 (we paste atomically)
- Output injection (clipboard-paste pattern, same as Wispr):
  1. Save current `NSPasteboard.general` contents (string + types)
  2. Write cleaned text to pasteboard
  3. Post synthetic `Cmd+V` via `CGEvent`
  4. After 300 ms, restore prior pasteboard contents

## 5. Configuration

### 5.1 `Mode` data model

```swift
struct Mode: Codable {
    let bundleID: String      // e.g. "com.tinyspeck.slackmacgap" or "*"
    let displayName: String   // "Slack"
    let prompt: String        // system prompt for the LLM
    let model: String?        // optional per-mode model override
    let temperature: Double?  // optional
}
```

Stored as JSON at `~/Library/Application Support/voxline/modes.json`.

### 5.2 Shipped defaults

| Bundle ID                          | Prompt                                                         |
| ---------------------------------- | -------------------------------------------------------------- |
| `com.tinyspeck.slackmacgap` (Slack)| "Concise, casual. Strip fillers. No greeting unless dictated." |
| `com.apple.mail`                   | "Format as a professional email body. Punctuate. Preserve meaning." |
| `com.todesktop.230313mzl4w4u92` (Cursor) | "Return as-is, treat as code-adjacent text. Minimal cleanup." |
| `*` (fallback)                     | "Strip fillers. Punctuate. Preserve the speaker's voice."      |

### 5.3 App settings

`UserDefaults` for simple keys (selected provider, Whisper model, hotkey codes). Keychain for API keys.

## 6. UI

### 6.1 Menu bar icon

- Status icon: idle (mic) / recording (filled mic) / thinking (spinner) / error (mic with badge)
- Click → menu: `Toggle voxline`, `Settings…`, `Quit`

### 6.2 Floating recording pill

- Shown near current cursor location while recording
- Waveform animation driven by mic input level
- Switches to spinner during transcription + LLM call
- Click-through (does not steal focus)

### 6.3 Settings window (SwiftUI)

Three tabs:

- **General** — hotkey configuration (record-a-chord UI), input device picker, Whisper model picker
- **API Keys** — Anthropic key field, OpenAI key field, "Test connection" buttons. Keys round-tripped through Keychain.
- **Modes** — table of bundle ID + prompt rows; add/edit/delete; "Add from running apps" helper that lists currently running apps for one-click add.

### 6.4 First-run wizard

A modal walks new users through:

1. Welcome
2. Grant Accessibility permission (deep link to System Settings)
3. Grant Microphone permission (TCC prompt)
4. Pick LLM provider + paste API key (validated with a test call)
5. Download Whisper model (progress bar)
6. Done — show the hotkey reminder

## 7. Privacy & Data

- **Audio:** in-memory only, never written to disk
- **API keys:** macOS Keychain (`Security.framework`, generic password)
- **Modes config:** plaintext JSON in Application Support
- **Transcripts:** not logged in v1
- **Network:** only the LLM provider receives the transcript text; audio never leaves the device
- **Telemetry:** none

## 8. Permissions & Entitlements

- Microphone (`NSMicrophoneUsageDescription`)
- Accessibility (CGEventTap requires it; user must enable manually in System Settings)
- App Sandbox: enabled, with `com.apple.security.device.audio-input` and `com.apple.security.network.client`

## 9. Testing

### 9.1 Unit tests

- `ModeRouter`: bundle-ID matching, wildcard fallback, missing-mode handling
- `ClipboardInjector`: save/restore round-trip with mixed pasteboard types
- `HotkeyStateMachine`: chord detection, partial-release transitions, edge cases (modifier rollover)
- `LLMClient`: request shape per provider, error mapping

### 9.2 Integration tests

- Fixed WAV fixture → real WhisperKit → mock LLM → assert pasted payload
- Mode routing across simulated frontmost-app changes

### 9.3 Manual smoke targets

- Slack desktop, Apple Mail, Cursor, Safari/Chrome textarea, Notes, Terminal

## 10. Build Phases (for the implementation plan)

These are sketch-only; the implementation plan will expand them.

1. **Skeleton:** menu bar app shell, settings window scaffold, permissions plumbing
2. **Hotkey + audio:** chord detection, mic capture into in-memory buffer, recording pill UI
3. **Whisper integration:** WhisperKit wired up, model download flow, batch transcription
4. **LLM client:** Anthropic + OpenAI clients, Keychain-backed key storage, first-run wizard
5. **Mode routing + paste:** bundle-ID lookup, prompt construction, clipboard inject
6. **Settings UI:** General / API Keys / Modes tabs polished
7. **Hardening:** error states, mic-fail / no-key / network-fail messages, smoke pass

## 11. Open Questions / Risks

- **Whisper cold-start latency** on first invocation per session may be 1–3 s; acceptable for v1, optional warm-up if it's too jarring.
- **CGEventTap reliability under load** — known to occasionally drop events on macOS; mitigation is to also subscribe to `NSEvent.addGlobalMonitorForEvents` as a backup signal.
- **Clipboard restore timing** — 300 ms is heuristic. If the target app pastes asynchronously (some Electron apps), restoration may race. May need to bump or add per-app overrides.
- **App Sandbox + Accessibility** — sandboxed apps cannot use AX APIs in some flows. CGEventTap from a sandboxed app *does* work for keyboard events with the right entitlements, but this needs verification on Xcode 26 / macOS 26.
- **WhisperKit Apple Silicon requirement** is a hard constraint; design accepts this.
