# voxline — Design Spec

**Date:** 2026-05-08
**Version:** v0.2
**Status:** Draft, pending review
**Platform:** macOS 14+ (Apple Silicon)
**Template:** SwiftUI App, no storage

## 1. Goal

A hotkey-driven dictation app for macOS. Hold the hotkey, talk, release. Speech is transcribed locally; the transcript is cleaned by an LLM using a per-app prompt, then auto-pasted into the focused field.

voxline runs STT locally and uses the user's own LLM API key — no subscription. The per-app prompt model lets the cleanup adapt to the active app (different tone for chat vs. email vs. code).

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

**Hotkey monitoring:**

- Global hotkey via `CGEventTap` listening for `flagsChanged` events
- State machine: `idle` → `armed` (one chord modifier down) → `recording` (both down) → `finalizing` (any released)

**State-machine fail-safes** (any one of these forces a transition out of `recording`):

1. **Max recording duration** — hard cap, default 60 s, configurable in Settings. Beyond this we finalize regardless of key state.
2. **Tap re-enable handler** — listen for `kCGEventTapDisabledByTimeout` and `kCGEventTapDisabledByUserInput`; re-enable the tap with `CGEvent.tapEnable(tap:enable:)` and finalize the in-flight recording defensively.
3. **Periodic flagsState reconciliation** — while in `recording`, a 250 ms timer polls `CGEventSource.flagsState(.combinedSessionState)`. If the chord is no longer held, we finalize even if no `flagsChanged` event was delivered.
4. **App-deactivation guard** — observe `NSWorkspace.didDeactivateApplicationNotification` for our own app and finalize if focus moves while recording.

**Mic capture pipeline** (two stages — capture in hardware format, then resample):

1. **Capture stage** — install a tap on `AVAudioEngine.inputNode` using `inputNode.outputFormat(forBus: 0)` (the hardware-native format, typically 48 kHz float32 mono on built-in mics, may be stereo on external interfaces). Do not specify a fabricated format — that throws at runtime.
2. **Convert stage** — `AVAudioConverter` from the captured format to WhisperKit's input format: 16 kHz mono Int16 (or Float32, whichever the WhisperKit version expects). Conversion runs incrementally on the audio thread so the buffer handed to WhisperKit is already in the right format.

Audio is held in memory only, discarded immediately after transcription completes (success or failure).

Permissions: Accessibility + Microphone, requested at first launch (TCC prompts).

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
  1. **Snapshot pasteboard** — iterate `NSPasteboard.general.pasteboardItems`; for each item, capture every data-bearing type (`item.types` → `item.data(forType:)`). See §7 for what is and isn't preserved.
  2. **Write cleaned text** — clear pasteboard, write cleaned text as `.string`.
  3. **Wait for chord release** — before posting `Cmd+V`, poll `CGEventSource.flagsState(.combinedSessionState)`. If Left Ctrl or Left Option is still physically held, wait (up to 1 s) for the user's fingers to come off; if the timeout elapses, post a synthetic `flagsChanged` clearing those modifiers. This prevents the synthesized `Cmd+V` from being interpreted as `Ctrl+Cmd+V` or `Option+Cmd+V` by apps that read global modifier state rather than event flags.
  4. **Post synthetic Cmd+V** — `CGEvent` with flags set explicitly to *only* `kCGEventFlagMaskCommand`.
  5. **Restore pasteboard** — after 300 ms, clear and re-write the snapshotted items × types.

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

Stored as JSON at the URL returned by `FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)` joined with `voxline/modes.json`. Under App Sandbox this resolves to `~/Library/Containers/com.voxline.voxline/Data/Library/Application Support/voxline/modes.json`; the literal `~/Library/Application Support/voxline` path is **not** writable from a sandboxed process. All file I/O must go through the FileManager API, never a hard-coded path.

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
  - **Note:** `Toggle voxline` (enable/disable hotkey listener) is deferred until Plan 2 wires the hotkey state machine. Plan 1's menu ships with `Settings…` and `Quit voxline` only — adding a toggle without something to toggle would be misleading UI.

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
- **Modes config:** plaintext JSON under containerized Application Support (see §5.1)
- **Transcripts:** not logged in v1
- **Network:** only the LLM provider receives the transcript text; audio never leaves the device
- **Telemetry:** none

### 7.1 Clipboard preservation (design decision)

voxline temporarily takes over the system pasteboard to inject text. Restoration scope is explicitly bounded:

**Preserved:**
- All `pasteboardItems` (multi-item clipboards)
- All concrete data-bearing types per item (strings, RTF, HTML, image data, file URLs as data, custom UTI types)

**Not preserved:**
- **Promised types** (`NSPasteboardWriting` lazy promises) — the source app provides data on request and is no longer reachable once we clear the pasteboard. Eagerly resolving promises before snapshotting would force expensive work on the source app (e.g., Finder file copies) for every dictation, which we judge worse than losing the promise.
- **Owner-based pasteboards** where the source app retains ownership and serves data dynamically.

**Refuse-to-clobber:** if `pasteboardItems` is `nil` or contains promised types we can't resolve cheaply, voxline aborts the paste and surfaces an error rather than silently destroying the user's clipboard.

This is a tradeoff every clipboard-driven dictation app makes; we document it explicitly so the test suite has a clear contract and so future work (opt-in eager promise resolution? targeted preservation for known apps?) has a defined starting point.

## 8. Permissions & Entitlements

- Microphone (`NSMicrophoneUsageDescription`)
- Accessibility (CGEventTap requires it; user must enable manually in System Settings)
- App Sandbox: enabled, with `com.apple.security.device.audio-input` and `com.apple.security.network.client`

## 9. Testing

### 9.1 Unit tests

- `ModeRouter`: bundle-ID matching, wildcard fallback, missing-mode handling
- `ClipboardInjector`: full multi-item × multi-type round-trip preservation per §7.1 (string + RTF + HTML + file-URL data + custom UTI in the same snapshot must all survive); refuse-to-clobber path when promised types are present; modifier-release gate before paste posts (simulated chord-still-held scenario must defer the synthesized `Cmd+V`)
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
- **Clipboard restore timing** — 300 ms is heuristic. If the target app pastes asynchronously (some Electron apps), restoration may race. May need to bump or add per-app overrides.
- **CGEventTap from sandboxed app** — **VERIFIED PASS on macOS 26.4 (25E246) / Xcode 26.4.1, 2026-05-08** via `spikes/EventTapSandboxSpike/`. With `com.apple.security.app-sandbox` entitlement and Accessibility granted in System Settings, `CGEvent.tapCreate(.cgSessionEventTap, .listenOnly, ...)` returns a working tap and `flagsChanged` callbacks fire as expected. Sandbox stays enabled for v1. Note: sandboxed CLI binaries require a `CFBundleIdentifier` embedded via `__TEXT __info_plist` linker section to avoid SIGTRAP in `_libsecinit_appsandbox` — full apps with a normal Info.plist don't have this issue.
- **WhisperKit Apple Silicon requirement** is a hard constraint; design accepts this.

## 12. Changelog

- **v0.2 (2026-05-08)** — Code-review pass: corrected mic capture format (hardware tap + AVAudioConverter), hardened paste keystroke against modifier leak (chord-release gate before synthetic `Cmd+V`), added state-machine fail-safes (max duration, tap re-enable, flagsState reconciliation, app-deactivation guard), documented clipboard preservation as an explicit design decision (§7.1), fixed sandbox-aware path reference for modes.json.
- **v0.1 (2026-05-08)** — Initial draft.
