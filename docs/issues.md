# voxline — known issues (code review, 2026-07-09)

Ranked by how hard a real user hits them: impact × likelihood. Every item below was
verified against the source; line numbers are from `main` at d0ee62d. A few
reviewer claims that did **not** survive verification are listed at the bottom.

## High — daily-use pain

### 1. First words of a dictation can be lost; UI stalls at keypress
`AudioCaptureService.swift:39-111` — the engine is fully stopped after every
dictation (deliberate, for the mic indicator) and cold-started **synchronously on
the main actor** at every chord press, followed by a synchronous CoreAudio
device enumeration just for the log line (`resolvedInputDeviceName()`, line 109).
Anything spoken before `engine.start()` returns and the first tap buffer arrives is
never captured. On Bluetooth mics (AirPods switching to HFP) this is hundreds of
ms up to ~1s: clipped first words and a visible UI hitch on every press.

**Fix direction:** pre-arm the engine when the chord goes to `.armed` (one modifier
down), or keep the engine warm briefly between dictations; move the device-name
lookup off the critical path.

### 2. One LLM hiccup destroys the dictation; a hang freezes dictation for a minute
- No timeout: `HTTPClient.swift:13` uses `URLSession.shared` with the default 60s
  request timeout, and the `-1005` retry (lines 20-29) can double it.
- No retry on transient 429/500/503/529 (`HTTPErrorMapping.swift`), even though the
  error text tells the user to "try again in a moment" — which means re-speaking
  everything.
- No fallback: on any LLM error, `CapturePipeline.finalizeRecording`
  (`CapturePipeline.swift:156-162`) just shows the error. The transcription already
  succeeded (`state.lastTranscript` is populated at line 130) but is never offered.
- No cancel: while `.thinking`, `startRecording` rejects all presses
  (`CapturePipeline.swift:66`), so a hung request makes the hotkey dead for up to
  a minute+ with no escape.

**Fix direction:** ~15s request timeout, one retry on 429/5xx, and on failure copy
the raw transcript to the clipboard (or offer it via the pill/menu) instead of
discarding it.

### 3. Back-to-back dictation is unreliable — presses during processing are silently swallowed
`HotkeyStateMachine.swift:50-57` — in `.finalizing`, `flagsChanged` hits the
`default: return []` arm, so re-pressing the chord while the previous dictation is
transcribing/cleaning does nothing. `recordingFinished()` only fires after the
*entire* pipeline (`voxlineApp.swift:271-278`), and because the tap only sees
`flagsChanged`, a user still holding the chord when the machine returns to `.idle`
gets nothing until they fully release and re-press. There is no cue whatsoever
(no sound, no pill) that the speech was dropped.

**Fix direction:** either queue/arm the press seen during `.finalizing`, or at
minimum give explicit feedback (error sound / pill flash) when a press is rejected.

## Medium

### 4. Quick tap → false "No audio captured" error
`CapturePipeline.swift:43-51,109` vs `AudioCaptureService.swift:180-185` — sample
chunks are appended directly in the tap's MainActor task, but `lastPeakLevel` is
updated one extra Task hop later (the `onLevel` closure spawns a nested Task).
`finalizeRecording` reads both synchronously, so on a sub-100ms tap it can see
non-empty samples with peak still 0 and shows "No audio captured. Check that
Microphone permission is granted…" on a perfectly working mic.

### 5. Dictating with no editable field focused "succeeds" silently — the text goes nowhere
`ClipboardInjector.swift:44-48, 597-606` — eligibility passes if the frontmost app
merely *has* an Edit ▸ Paste menu item (almost every app) or the focused element has
a readable `AXValue` (includes read-only static text). Cmd+V then no-ops, verification
returns `.unchanged` with the same element identity, and that is reported as
success (`.unverified`). No error, no fallback; the dictation exists only in history.

### 6. Clipboard restore races slow apps — the OLD clipboard gets pasted
`ClipboardInjector.swift:454, 564, 587` — after posting Cmd+V the code sleeps a fixed
`restoreDelay` of 300ms, then the `defer` restores the previous clipboard. Apps that
service the paste slower than that (Electron under load, remote desktop/VMs, busy
terminals) read the pasteboard after restore and insert the user's *previous*
clipboard instead of the dictation. Anything the user (or a clipboard manager)
writes to the clipboard during the window is also clobbered by the unconditional
restore — no `changeCount` check (`PasteboardSnapshot.swift:54-65`).

### 7. Recording pill can be invisible exactly when you need it
`RecordingPillWindow.swift:66-72` — positioned 24pt *below* the cursor with no
clamping to `visibleFrame`: dictating into a field near the bottom (or edge) of the
screen puts the pill partially or fully off-screen. Line 28 — `collectionBehavior`
omits `.fullScreenAuxiliary`, so the pill never appears over another app's
full-screen Space (full-screen browser/IDE/video call).

### 8. Mic disappearing mid-recording silently truncates the dictation
`AudioCaptureService.swift` — no `AVAudioEngineConfigurationChange` observer and no
engine-running re-check. AirPods dying or a USB mic unplug mid-sentence stops tap
delivery with no error: the level meter freezes, the rest of the speech is lost, and
since peak > 0 the silent-capture detector doesn't fire either.

### 9. Every paste does a full menu-bar AX walk on the main actor, with no AX timeout anywhere
`ClipboardInjector.swift:60-76` — `frontmostAppHasPasteMenuItem()` walks every menu
bar item → submenu → item, one cross-process AX round-trip per node, on the main
actor, per dictation. `AXUIElementSetMessagingTimeout` is never called anywhere in
the codebase, so each call can block for the system default (~6s) when the frontmost
app is busy — that's a multi-second beachball between key-release and paste against
a beachballing app, and measurable added latency in menu-heavy apps even when
healthy. Related: `PasteboardSnapshot.capture` (`PasteboardSnapshot.swift:31-37`)
forces promised/lazy pasteboard data synchronously — dictating right after copying
something huge (Photoshop/Office) freezes the app while the payload materializes.

### 10. Re-recording the hotkey in Settings can trigger a live dictation
`ChordRecorderView.swift:45-61` — the recorder installs only local `NSEvent`
monitors; the global CGEventTap is never suspended. Pressing the *current* chord's
modifiers while recording a new chord starts a real dictation, and the result is
pasted into the Settings window.

### 11. Custom chords built from common modifiers misfire on every OS shortcut that supersets them
`HotkeyMonitor.swift:35` + `HotkeyStateMachine.swift:60-64` — only `flagsChanged` is
observed and `(true, true)` starts recording regardless of other keys. A user who
picks e.g. LCmd+LShift gets a recording started by every Cmd+Shift+4 screenshot,
and ambient audio is later transcribed and pasted. The default RCmd+ROpt chord is
mostly immune; the recorder allows conflict-prone chords with no warning
(`HotkeyChord.swift:58-67` warns only about the VoiceOver pair).

### 12. Accessibility revoked (or hotkey toggled off) mid-hold wedges the app in `.recording`
`HotkeyMonitor.swift:56-64` — `stop()` disables the tap and invalidates the
60s fail-safe timer but never feeds a finalize, and the reconcile loop
(`voxlineApp.swift:357-364`) calls it whenever AX drops or `hotkeyEnabled` flips.
The key-up is never seen: mic stays hot, pill stuck on screen, status stuck at
`.recording`, and all future dictation is blocked until relaunch.

### 13. Keychain read errors are indistinguishable from "no key" — and the wizard can then delete real keys
`DataProtectionKeychain.swift:44-46` — reads map `errSecMissingEntitlement` to `nil`
(writes throw for the same status), so a signing/entitlement problem surfaces as
"No API key configured" with empty Settings fields, and re-saving throws.
`APIKeysSettingsViewModel.swift:39-42` swallows *all* read errors into `""`;
`WizardViewModel.commitProgress()` commits those fields on every advance, and
committing `""` deletes the stored key — a transient read failure during a re-run
wizard permanently deletes both keys on one click.

### 14. OpenAI reasoning models can paste nothing — empty output treated as success
`OpenAIClient.swift:25-27, 46-64` — `max_completion_tokens: 1024` is shared with
hidden reasoning tokens on gpt-5-family models (which the comment explicitly
supports), so the model can burn the whole budget reasoning and return
`content: ""` with `finish_reason: "length"` — never checked, returned as success:
the user waits, nothing pastes, an empty history entry is recorded.
(Anthropic-side truncation is largely mitigated by the 60s recording cap — see
"rejected findings" below.)

## Smaller but real

15. **Reset to Defaults wipes custom vocabulary** with no confirmation — the button
    copy is about hotkey/mic/model, but `GeneralSettingsViewModel.swift:141-150`
    also does `vocabulary.save([])`. User-authored data, gone permanently.
16. **Typing fallback mangles emoji** — `ClipboardInjector.swift:359-364` chunks
    UTF-16 at a fixed 20 units with no surrogate-pair check; a pair split across
    two CGEvents renders as U+FFFD.
17. **Clipboard restore loses pasteboard type order** —
    `PasteboardSnapshot.swift:8-10, 57-61` stores types in a `Dictionary` (the
    comment claims order is preserved; it isn't). Order-sensitive consumers can
    paste the wrong representation (plain instead of rich) after any dictation.
18. **Anthropic refusal/max_tokens surfaces as a parse error** —
    `AnthropicClient.swift:46-62` never decodes `stop_reason`; a refusal shows
    "Could not parse provider response: no text blocks in response".
19. **Latent Codable trap in `Mode`** — `Mode.swift:41-43`: the `= .general`
    default does *not* apply during synthesized decode; any future non-optional
    field added the same way makes the all-or-nothing `[Mode]` decode discard the
    user's entire modes.json (silent fallback to shipped defaults,
    `voxlineApp.swift:211-218`). All tagged releases already write `category`, so
    this is latent today.
20. **Fail-safe and reconcile timers stall while the menu-bar menu is open** —
    `HotkeyMonitor.swift:133` and `voxlineApp.swift:323` use
    `Timer.scheduledTimer` (`.default` run-loop mode only; the tap source is in
    `.commonModes`). Holding the menu open during a recording suspends the 60s
    fail-safe and permission reconciliation.
21. **First-run wizard is a dead end offline** — the download step's Continue is
    disabled unless `.idle` (`WizardRootView.swift:54`), the window has no close
    button (`FirstRunWindowController.swift:31-36`), and the only affordance is a
    Retry that re-fails. Quit from the menu bar is the only exit.
22. **Hotkey dead over Screen Sharing / synthetic input** —
    `HotkeyChord.swift:22-33` + `HotkeyMonitor.swift:96-97` match only the
    device-specific left/right flag bits (`NX_DEVICE*`), which remote/synthetic
    events often omit; the generic `maskCommand`/`maskAlternate` bits are ignored.
23. **Trailing ~20-60ms of audio dropped at release** —
    `AudioCaptureService.swift:124-131, 181`: `stop()` bumps the epoch before
    pending chunk tasks land, and the converter is never flushed; releasing right
    on a word boundary can clip the final syllable.

## Follow-ups from the pill refine-actions feature (2026-07-10)

Non-blocking items surfaced by the whole-branch review of the post-dictation
refine pill (commits `7e88720..67958b6`). None block shipping; the feature is on
`main` with the full suite green.

24. **Hover-during-refine can restart the auto-dismiss countdown** —
    `CapturePipeline.refine(_:)` calls `resumeReviewExpiry()` unconditionally on
    completion, and SwiftUI `.onHover` on the remounted `ReviewControls`
    (`RecordingPillView.swift`) does not re-fire "entered" for an already-stationary
    cursor. So after clicking a refine button and holding the cursor still through
    the LLM round-trip, the 7s dismiss timer can restart while the pointer is still
    on the buttons. Non-corrupting (worst case: pill vanishes, user re-dictates; any
    mouse movement re-pauses it). Robust fix: track hover via an `NSTrackingArea` on
    the panel instead of view-local `.onHover`.
25. **Duplicated clipboard-write block in `ClipboardInjector`** — the
    clearContents / setString / setData×2 (`autoGeneratedType` + `concealedType`)
    sequence is duplicated between `replace()`'s fallback and
    `injectViaClipboardPaste()`. Extract a `writeHinted(_:)` helper so the two
    hint-stamp sites can't drift.
26. **Duplicated toast pattern** — `CapturePipeline.showToast` repeats the
    set-message / `Task.sleep(2s)` / clear-if-unchanged pattern already in
    `HistoryView.swift`. Extract a shared `AppState.flashToast(_:for:)` helper.
27. **Review pill grows off-center** — entering review resizes the pill 140→300pt
    from a fixed origin (`RecordingPillWindow.updateVisibility`), so it extends
    rightward rather than staying centered on the cursor point. Cosmetic; spec only
    required the origin not to move.

## Reviewer claims rejected during verification

- **"Anthropic silently truncates long dictations at 1024 max_tokens" — mostly
  can't trigger.** The 60s `maxRecordingDuration` fail-safe caps a dictation at
  ~150-200 spoken words (~250-300 output tokens), far under 1024. Real only if the
  cap is raised or removed; the unchecked `stop_reason` remains item 18.
- **"Task cancellation during the restore sleep pastes the old clipboard and
  double-inserts" — no live trigger.** Nothing ever cancels the inject task
  (`CapturePipeline.swift:169` awaits it; only `contextTask` is cancelled).
  Latent if a cancel affordance is added later (see item 2's fix).
- **"Mic-level monitor keeps running after Settings closes" — not supported.**
  `SettingsView.swift:134` has `.onDisappear { levelMonitor.stop() }`.
- **"Out-of-order audio chunks from unordered Tasks" — theoretical.** Same-priority
  unstructured tasks to one actor are near-FIFO in the current runtime; no
  practical repro path identified.
