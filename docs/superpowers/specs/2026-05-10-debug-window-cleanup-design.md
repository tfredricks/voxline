# Debug window cleanup — design

**Date:** 2026-05-10
**Topic:** Simplify `DebugView` from a subsystem-organized dump into a scenario-organized triage tool.

## Problem

`voxline/Debug/DebugView.swift` currently renders eight sections (Permissions, Hotkey, Pipeline, Last chord cycle, Recent flagsChanged events, Routing, End-to-end tests, Last test result). The window is visually busy and most of the dense numeric output is rarely read. Some of it duplicates information shown elsewhere (e.g. `audioLevel` and `debugLastPeakLevel`), some is internal-state introspection that no one consults during normal triage (tap callback counts, sample counts, raw `flagsChanged` ring buffer).

Audience: the developer plus power users who may open the window during a bug report. The window is **not** a general user-facing status panel — diagnostics that aren't human-readable should be cut.

## Top diagnostic scenarios (drives prioritization)

1. *"Nothing happens when I press the chord."* → permissions + hotkey/tap state.
2. *"It recorded but pasted wrong/empty text."* → heard transcript vs. cleaned text vs. resolved mode.

Less common but supported:
3. *"Pasting fails or goes to the wrong app."* → frontmost bundle, last insertion result, paste-test button.
4. *"Something is wedged."* → force-finalize, reinstall-tap.

## Design

Three panels, top to bottom, organized by the question the user is asking — not by subsystem.

### Panel 1 — Last attempt

The "what just happened?" view. Renders even when idle (using last values).

```
Status:     idle | recording | thinking | error[category]: msg
Heard:      <raw transcript or "(empty — WhisperKit returned no text)">
Cleaned:    <LLM output or "(none yet)">
Mode:       <displayName>  (<bundleID>)
            └ override: <model> @ <temperature>     ← only if mode.model or .temperature is non-nil
Duration:   <s.s>s · peak <0.000>                   ← only when lastRecordingDuration != nil
Insertion:  <result string>
Reason:     <finalize reason>                       ← only when reason != "(none yet)" and != default chord-release
```

Wire-through:
- `Status` from `state.status` (existing `statusLabel` helper).
- `Heard` from `state.lastTranscript`.
- `Cleaned` from `state.lastCleanedText`.
- `Mode` resolves via `coordinator.modes?.mode(for: coordinator.frontmost?.frontmostBundleID())`. Bundle inline; override row appears only when overridden.
- `Duration` from new `state.lastRecordingDuration` (see Field changes).
- `peak` from renamed `state.lastPeakLevel`.
- `Insertion` from `state.debugLastInsertionResult`.
- `Reason` from `state.debugLastFinalizeReason`, hidden when empty/default.

### Panel 2 — Inputs healthy?

The "can it record?" view. Designed so green/red is at a glance.

```
Microphone:        ✓ authorized
Accessibility:     ✗ denied                       [Open Settings]
Input Monitoring:  ✓ authorized

Hotkey state:      <state>
Tap installed:     yes | no
```

- Each permission row prefixes its existing string with ✓ or ✗ derived from a string check (`status.hasPrefix("authorized")` etc.). Acceptable for now; if richer status is needed, lift permission state to an enum in a follow-up.
- Single contextual `Open Settings` link beside the *failing* row only. If everything is green, no buttons. If both AX and IM are denied, two links (one per failing row).
- Re-prompt buttons (`requestInputMonitoring`, `promptAccessibility`) are removed. The `Open Settings` link is enough; re-prompt UX rarely succeeds twice and the user can always toggle from the System Settings pane.

### Panel 3 — If it's wrong

Recovery + bisection.

```
[ Force-finalize ]   [ Reinstall tap ]
[ Test paste ]   [ Test LLM ]   [ Test transcribe ]
Last test result: <text or "(none)">
```

Behavior identical to today; the section is just relocated and renamed.

## Removed

UI rows and underlying fields removed:

| Item | Reason |
|---|---|
| Recent flagsChanged events section + ring buffer | Deep-internal log; only useful when chord detection itself misbehaves, which is rare. Can be re-added behind a hidden default if needed. |
| Tap callbacks count | Internal counter; never resolved a real bug post-instrumentation. |
| Sample count row | Folded into Duration. |
| Audio-level row in Pipeline | Redundant with peak. Live audio level is still tracked for the recording pill. |
| `recordingStartedAt` row | Not actionable. |
| Pipeline phase row | Status enum already covers user-visible state; phase string was internal narrative. |
| Separate Model override / Temperature rows | Folded into Mode line, conditional on `mode.model` / `mode.temperature` being set. |
| `Re-prompt Input Monitoring` button | Redundant with Open Settings. |
| `Re-prompt Accessibility` button | Redundant with Open Settings. |

## Field & wiring changes

`voxline/AppState.swift`:

- **Delete** `debugRecentFlagEvents`, `debugLastTapCallbackCount`, `debugLastSampleCount`, `debugPipelinePhase`.
- **Rename** `debugLastPeakLevel` → `lastPeakLevel`. It is load-bearing for the silent-capture detector at `CapturePipeline.swift:107`, not debug-only. Drop the `debug` prefix and update its doc comment to reflect the dual role (silent-capture detector + debug-window display).
- **Add** `var lastRecordingDuration: TimeInterval?`. Populated by `CapturePipeline.finalizeRecording` once at the moment capture stops, computed as `Double(samples.count) / 16_000.0`. This reflects the audio actually delivered to WhisperKit, not wall-clock — which is what "Duration" in the panel should mean (a 5-second chord that produced 0.5s of audio is itself a useful diagnostic signal).
- **Keep** `debugHotkeyState`, `debugTapInstalled`, `debugMicrophoneStatus`, `debugAccessibilityStatus`, `debugInputMonitoringStatus`, `debugLastInsertionResult`, `debugLastFinalizeReason`, `debugLastTestResult`. Each is referenced by the new view.

`voxline/voxlineApp.swift`:

- **Delete** the `flagsChanged` event logger that writes to `debugRecentFlagEvents` (around lines 227–231). Drop the surrounding entry-formatting helper if it becomes orphaned.

`voxline/Pipeline/CapturePipeline.swift`:

- **Delete** writes to `debugLastTapCallbackCount` (lines 48, 81), `debugLastSampleCount` (line 101), `debugPipelinePhase` (all sites).
- **Rename** the two `debugLastPeakLevel` references (lines 41–42, 80, 107) to `lastPeakLevel`.
- **Add** `state.lastRecordingDuration = Double(samples.count) / 16_000.0` immediately after `let samples = capture.takeSamples()` and before the silent-capture detector runs, so the value is visible even when the run aborts on silence.

`voxline/Debug/DebugView.swift`:

- Full rewrite of the body to the three-panel layout above.
- Drop helpers that are no longer used (`flagEventsSection`, `transcriptsSection`, `pipelineSection`, `modesSection`, `permissionsSection` as currently structured). Keep and adapt: `transcriptBox`, `sectionHeader`, `row`, `openSystemSettings`, `runTestPaste/runTestLLM/runTestTranscribe`, `statusLabel`.

## Testing

`voxlineTests/CapturePipelineTests.swift` and `CapturePipelineErrorTaxonomyTests.swift` currently reference the deleted/renamed fields:

- Drop assertions on `debugLastSampleCount`, `debugLastTapCallbackCount`, `debugPipelinePhase`.
- Rename `debugLastPeakLevel` references to `lastPeakLevel`. The silent-capture-detector test continues to work unchanged after the rename.
- Add (or extend) a test verifying `lastRecordingDuration` is populated by `finalizeRecording` after a non-empty capture, and is non-nil even when the silent-capture detector aborts the pipeline.

No new view-level tests. `DebugView` is a triage UI and is not exercised by automated tests today; that does not change.

## Non-goals

- No "Show internals" disclosure. If a deep-tap bug recurs, re-add the writer behind a hidden default rather than carrying the UI cost forever.
- No changes to the recording pill, the hotkey state machine, or pipeline business logic beyond field renames.
- No changes to the menu-bar Debug section (separate component).
- No promotion to a user-facing status window. Audience remains "developer + power users."

## Risks

- Renaming `debugLastPeakLevel` touches the silent-capture detector. Mitigated by the test suite (the rename is mechanical and the test asserts the same observable behavior).
- Removing `debugPipelinePhase` removes the only field describing *which step* of finalize hung if finalize ever wedges. The `Force-finalize` button + `Status` enum together still expose the wedge; precise step identification can be recovered via logs (`os_log`) if needed.
