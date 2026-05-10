# Settings Redesign — Design Spec

**Date:** 2026-05-10
**Owner:** todd124@gmail.com
**Status:** Design — pending implementation plan

## Background

The current Settings window has two `TabView` tabs:

- **General** (`GeneralSettingsView.swift`) — Hotkey, Microphone, Speech recognition (Whisper), Cleanup (LLM provider), Feedback, Reset.
- **API Keys** (`APIKeysSettingsView.swift`) — Anthropic and OpenAI key fields, reveal toggle, Test buttons, Saved/Unsaved status pills.

The two tabs are functionally coupled: the **Cleanup → Provider** picker on tab 1 decides which API key on tab 2 actually matters at runtime, but nothing in the UI surfaces that link. Users must mentally stitch the two tabs together. Secondary concerns: the form feels unpolished, there is no at-a-glance status of what is wired up, and the tab split is arbitrary.

## Goals

1. **Eliminate the disconnection** between provider selection and its API key — they should live in one section.
2. **Surface system status at a glance** — mic, recognition model, AI provider — without making the user click through tabs.
3. **Order sections by the actual data pipeline** so the mental model maps to what voxline is doing: Hotkey → Mic → Recognition → Cleanup → Feedback.
4. **Add lightweight visibility wins** — live mic level meter, inline Whisper download state.

## Non-goals

- No changes to keychain storage, key validation logic, or LLM provider semantics.
- No new diagnostics screen, log viewer, or account/billing surface.
- No rework of the first-run wizard. (The wizard already does its own setup flow; this redesign is for users returning to tweak settings.)
- No new output destination options or "open at login" toggle in this pass.

## High-level approach

Replace the two-tab `TabView` with a **single scrolling page** organized by pipeline stage. The window keeps its current min/ideal frame (≈540 × 460) but content flows top-to-bottom rather than splitting into tabs.

The provider's API key is fused into the same Cleanup section as the provider picker. The other provider's key is reachable via a disclosure toggle so power users can pre-load both keys for fast switching, without cluttering the default view.

## Layout

```
┌──────────────────────────────────────────────┐
│ ● Ready   🎙 MacBook Mic   🧠 base.en   ✨ Anthropic ✓
│ ── status strip ──
├──────────────────────────────────────────────┤
│ HOTKEY                                       │
│   Press to record           [⌥ Space]        │
├──────────────────────────────────────────────┤
│ MICROPHONE                                   │
│   Input device              [picker]         │
│   Live level                ▰▰▰▰▰▱▱▱▱▱       │
├──────────────────────────────────────────────┤
│ RECOGNITION                                  │
│   Whisper model             [base.en · ✓]    │
│   "Switching downloads on demand."           │
├──────────────────────────────────────────────┤
│ CLEANUP (AI)                                 │
│   Provider     [ Anthropic | OpenAI ]        │
│   API key      ●●●●●●●●●  👁  [Saved]        │
│   Get an Anthropic key →     [Test]  ✓       │
│   ▸ Also store an OpenAI key                 │
├──────────────────────────────────────────────┤
│ FEEDBACK                                     │
│   Play sound on record start/stop  [toggle]  │
├──────────────────────────────────────────────┤
│                            [Reset to Defaults]
└──────────────────────────────────────────────┘
```

### Section details

**Status strip (new).** A single horizontal row at the top:
- `● Ready` (green) when everything required is wired (provider key saved + model downloaded + a mic device exists). Yellow + "Setup needed" when a required piece is missing.
- Mic name, current Whisper model, current provider with a `✓` badge if its key tests/saves successfully.
- Click on any chip scrolls the page to that section.

**Hotkey.** Unchanged — keeps the existing `ChordRecorderView`.

**Microphone.** Existing input device picker, plus a new live level meter row underneath. The meter requires a settings-only audio tap (see "New mechanics" below).

**Recognition.** The existing model picker, but each row in the dropdown shows download state (`✓ downloaded` vs `to download · 142 MB`). The "Switching downloads…" caption is preserved as a one-line note.

**Cleanup (AI).** Single section that fuses today's General "Cleanup" picker with today's API Keys content for the *active* provider only:
- Provider segmented picker (Anthropic | OpenAI).
- API key row for the active provider — `SecureField`/`TextField` with reveal toggle, Saved/Unsaved status pill, inline Test button and result label, "Get a key →" link.
- Disclosure: `▸ Also store an <other-provider> key`. When expanded, shows the same controls for the inactive provider. Collapsed by default.
- Validation hints (prefix mismatch, "this looks like an Anthropic key" warning) carry over unchanged.

**Feedback.** Existing sound toggle.

**Footer.** "Reset to Defaults" right-aligned.

## Components and ownership

The redesign replaces `SettingsView`, `GeneralSettingsView`, and `APIKeysSettingsView` with one unified view, but keeps the two existing view models untouched (no behavior changes, just composition):

```
SettingsView (new, single page)
├── SettingsStatusStrip            (new)
├── HotkeySection                  (wraps existing ChordRecorderView)
├── MicrophoneSection              (existing picker + new MicLevelMeter)
├── RecognitionSection             (existing picker, enriched row labels)
├── CleanupSection                 (new: provider picker + active key + disclosure)
│    └── APIKeyRow                 (new, used twice — active and disclosed)
├── FeedbackSection                (existing toggle)
└── Footer                         (Reset button)
```

`GeneralSettingsViewModel` and `APIKeysSettingsViewModel` keep their current responsibilities. `CleanupSection` consumes both: provider state from `GeneralSettingsViewModel`, key state from `APIKeysSettingsViewModel`. No shared coordinator is introduced — the views compose the existing models.

A small new view-only helper, `SettingsStatusViewModel`, derives the status strip's state by observing the two existing models plus a "model download/prewarm OK" signal from `AppState` (already exposed for wizard error UI).

## New mechanics (real implementation work)

These are surfaced honestly because they are not free:

1. **Settings-only mic level tap.** `AudioCaptureService` already publishes `onLevel` (peak amplitude, ~60 Hz) but only while a real recording is in progress. The Settings panel needs its own short-lived audio tap that runs while the panel is open and stops when it closes, or when a real recording starts (to avoid contention). Suggested boundary: a new `MicLevelMonitor` actor with `start()`/`stop()` that opens an `AVAudioEngine` input tap on the currently-selected device, computes peak level the same way as production, and publishes via `@Observable`. The Microphone section starts it on appear and stops on disappear.

2. **Whisper model download state for picker rows.** `WhisperModel` already knows `approxSizeMB`. We need a way to ask "is this model already on disk?" — likely a small `ModelInventoryService` that checks the WhisperKit model cache directory (see `whisperkit_load_gotchas.md` and `sandbox_paths.md` in memory; the cache lives in the sandbox container, not `~/Documents`). Picker rows render `✓ downloaded` or `· <size> MB` based on the inventory.

3. **"Ready" derivation.** Compose status from: provider key saved (`isPersisted` already exists on `APIKeysSettingsViewModel`) AND model on disk AND mic device present. No persistence needed — purely derived.

## Data flow

- Provider change (`GeneralSettingsViewModel.provider`): unchanged behavior; status strip recomputes its provider chip.
- Key edit + commit (`APIKeysSettingsViewModel.commitAnthropic/commitOpenAI`): unchanged; status strip recomputes via `isPersisted(activeProvider)`.
- Whisper model change: unchanged — switching still triggers the existing download-on-demand flow. Picker rows additionally read from `ModelInventoryService` to label download state.
- Mic level: `MicLevelMonitor` publishes a `Float` ∈ [0, 1]; meter view reads it directly. Lifecycle is bound to the Microphone section's appearance.

## Error handling

- **Test failures** — existing `testResult` flow renders inline next to the Test button (today's behavior, just relocated).
- **Keychain save failures** — existing `lastError` shown in red below the active key row; same as today.
- **Mic monitor failure** (no permission, device gone) — meter row shows a small "Mic unavailable" subtitle and does not block the page.
- **Model inventory failure** — picker rows fall back to "· <size> MB" with no checkmark; not a blocker.

## Testing

- Unit: extend `APIKeysSettingsViewModel` tests only if new logic lands there (currently none planned). New `SettingsStatusViewModel` gets unit tests for "Ready" derivation across the matrix of (key saved, model present, mic present).
- Unit: `MicLevelMonitor` gets a tested wrapper around its peak computation; engine lifecycle is exercised with a fake input.
- Snapshot/UI: new `SettingsView` gets at least three states — fully configured, missing key, missing model — to lock in layout and status strip behavior.
- Manual smoke (matches `docs/insertion-smoke-matrix.md` style):
  - Empty state (no key, no model) → status strip shows "Setup needed", clicking Cleanup chip scrolls to that section.
  - Switching provider preserves both keys; disclosure remembers which one is the inactive provider.
  - Mic meter responds to actual speech, stops when window closes.
  - Whisper picker rows update from "to download" → "✓ downloaded" after a switch completes.

## Open questions deliberately deferred

- A future "Advanced" disclosure for diagnostics, model paths, log export. Not in this pass.
- "Open at login" / launch agent. Not in this pass.
- Per-provider model selection (e.g., choose Claude Opus vs Sonnet within Anthropic). Not in this pass.

## Migration

- Window controller / `Settings` scene wiring updates from a `TabView` host to the new single view. Keyboard shortcuts and ⌘, opening behavior preserved.
- No persisted-settings migration: all underlying keys (`AppSettings`, keychain) are unchanged.
- Existing `GeneralSettingsApplier` continues to apply changes the same way.
