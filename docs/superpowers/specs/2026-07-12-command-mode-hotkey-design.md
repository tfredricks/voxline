# Command mode via a command modifier — design

## Problem

The "transform selection by voice" feature (shipped 0.2.5) decides whether spoken
speech is **dictation** or a **transform command** by auto-detecting a selection:
on every recording start it posts a synthetic Cmd+C and treats any non-empty
clipboard result as "there was a selection, so this is a transform command."

That probe is unreliable in editors with `editor.emptySelectionClipboard` enabled
— VS Code's default. In those editors Cmd+C with *nothing* selected copies the
**entire current line** (with its trailing newline), so the probe reports a
selection the user never made. Plain dictation is then misrouted into the
transform path, the LLM returns the line verbatim, and the pill shows
"Couldn't apply that." Symptom: dictation appears broken in VS Code (and any
editor with that setting) while working everywhere else.

The deeper issue: **a synthetic Cmd+C cannot distinguish "user selected text"
from "editor auto-copied the current line."** The clipboard carries no intent.
A trailing-newline heuristic was prototyped and rejected — it silently dictates
deliberately whole-line selections (triple-click, shift-down), which is
unacceptable.

Established apps (Wispr Flow, Superwhisper) don't infer intent from the
clipboard at all — they use an **explicit, separate trigger** for command/edit
mode. This design follows that pattern.

## Approach: command modifier

Keep the existing hold-to-talk dictation chord unchanged. Add an **optional
command modifier** held *together with* the chord to mean "this is a command,"
and **remove the auto-probe** that runs on every recording.

- New setting `commandModifier: HotkeyChord.Modifier?`, default `.rightCommand`.
  - `nil` = command mode **off**: voxline is pure dictation and never touches
    the clipboard (the strongest "leave my clipboard alone" guarantee).
- Transform gesture = dictation chord **+ command modifier** held together →
  the speech is applied as a command against the current selection.
- Plain dictation (command modifier not held) posts **no synthetic Cmd+C,
  ever.** This is the fix: the probe VS Code's line-copy fooled no longer fires
  for dictation.

Default command modifier is **Right Command**: `Shift+Ctrl+Cmd` held with no
letter key triggers nothing in macOS or apps, Command is already a first-class
case in `HotkeyChord.Modifier` (zero new plumbing), and Right Command is added
by the right thumb without disturbing a left-hand chord. The modifier is
configurable; Option is a poor choice (Ctrl+Option is the VoiceOver modifier)
and Fn is special-cased by macOS and not a device-mask modifier.

## Mode timing: decide at recording start

The command modifier's state is sampled at the moment recording begins. If it is
down when the chord completes, the utterance is a command; otherwise it is
dictation. Mental model: **"hold your keys, then talk."**

Rationale: this lets the selection probe fire **once, at start, only in command
mode**, which is exactly what keeps plain dictation clipboard-free. Latching the
mode across the whole recording would require either probing on every dictation
(re-introducing the bug) or probing mid-speech (fiddly), so it is out of scope
for v1. If real-world testing shows the three-key start timing is finicky,
"latch during recording" is a clean follow-up.

## Empty selection in command mode

Command gesture held but nothing selected → show a toast **"Select text to
transform"** and do nothing. No dictation fallback (keeps the mode boundary
crisp) and no clipboard-probe surprise.

## Component changes

### Hotkey core — `HotkeyMonitor`, `HotkeyStateMachine`

- `HotkeyStateMachine` remains a pure two-modifier chord machine — **unchanged**.
  The command modifier is orthogonal and handled entirely in the monitor.
- `HotkeyMonitor`: the tap callback already receives full `event.flags`. It
  tracks the latest observed command-modifier state (mirroring how the state
  machine tracks `lastFlags`, so the resume-on-`recordingFinished` path — which
  emits `startRecording` with no live event — sees the current value). When the
  machine emits `startRecording`, the monitor samples that tracked flag and
  passes it to the observers.
- Observer signatures become `onStartRecording(command: Bool)` and
  `onFinalizeRecording(command: Bool)`. The finalize value is the value latched
  at start (see Mode timing).
- The monitor reads `commandModifier` the same way it reads `chord` today
  (settings-provided, overridable on apply).

### `CapturePipeline`

- `startRecording(command:)`: spawn the selection probe (`selectionTask`) **only
  when `command` is true**. Delete the unconditional `selectionTask` spawn in
  `startRecording`. The context task (frontmost app + focused field) still runs
  for both modes — it feeds mode routing and cleanup.
- `finalizeRecording(command:)`: route explicitly:
  - `command == true` and selection non-empty → `performTransform(...)`.
  - `command == true` and no selection → toast "Select text to transform",
    reset to idle.
  - `command == false` → dictation path (never probed the clipboard).
  - Remove the `if let selection, !selection.isEmpty` inference branch.
- `performTransform`, `SelectionSnapshot`, the `transform()` LLM path, and
  transform review sessions are **unchanged** — they are simply reached
  deliberately now.

### Settings — `AppSettings`, `GeneralSettingsViewModel`, `GeneralSettingsSnapshot`, `SettingsView`, `voxlineApp.apply()`

- New UserDefaults key `voxline.hotkey.commandModifier`; unset → `.rightCommand`.
  Stored/read alongside `hotkeyChord` (same JSON-in-defaults pattern; a single
  `Modifier?` — encode `nil` as absent/"off").
- A single **Picker** in the hotkey settings section (not a full chord
  recorder): the eight `Modifier` cases plus an **"Off"** entry.
- Validation: the command modifier must differ from both chord modifiers; a soft
  warning (mirroring `HotkeyChord.conflictWarning`) surfaces a known conflict
  (e.g. Option → VoiceOver).
- `GeneralSettingsSnapshot` and `voxlineApp.apply(_:)` carry the new field so a
  settings change re-applies to the running `HotkeyMonitor`.

### App wiring — `voxlineApp.installHotkey`

- Thread the `command` boolean from the monitor callbacks into
  `pipeline.startRecording(command:)` / `finalizeRecording(command:)`.
- Start/stop sounds, pill visibility, and prewarm behave identically for both
  modes.

### Pill UI

- Minimal: display a "Command" cue while recording in command mode. Downstream
  is already handled — the review session distinguishes `.dictation` vs
  `.transform`.

## Known risk: paste while modifiers are held

During a transform paste the user may still be holding the chord **and** the
command modifier (e.g. Left Shift + Left Control + Right Command). The injector
posts Cmd+V; if physical modifiers merge with the synthetic event, it becomes
Shift+Ctrl+Cmd+V rather than a clean paste. The existing
`ClipboardInjector.makeChordIsHeld` logic gates pasting on chord release; it
**must also account for the command modifier**, or the transform paste can
misfire. This is exercised explicitly during verification.

## Migration

Existing users keep their dictation chord untouched. With the command modifier
defaulting to Right Command, transform stays available — now via the explicit
`chord + Right Command` gesture instead of auto-detection. No data migration is
required beyond the new defaults key falling back to `.rightCommand` when unset.

## Testing

- `HotkeyMonitor`: command-flag sampling at start (down → command; up →
  dictation); command modifier equal to a chord modifier is rejected upstream.
- `CapturePipelineTests`: existing transform cases move from "selection
  detected" to `command: true`; new cases for `command: true` + empty selection
  → toast, and `command: false` → dictation never spawns a selection probe.
- `AppSettingsTests`: round-trip of `commandModifier`, default `.rightCommand`,
  and the "Off" (`nil`) case.
- `GeneralSettingsViewModelTests`: validation that command modifier ≠ chord
  modifiers, and the apply path carries the new field.
- `HotkeyStateMachineTests`: unchanged (machine is untouched).

## Docs

- Reverse the "Auto-detect selection. No new hotkey or gesture." decision in
  `docs/superpowers/specs/2026-07-10-transform-selection-by-voice-design.md`
  (note it as superseded by this design).
- Update `docs/features.md` and `CHANGELOG.md`.

## Out of scope (v1)

- Wispr-style "generate/answer at cursor when nothing is selected."
- Latch-during-recording mode timing.
- Per-app command configuration.
