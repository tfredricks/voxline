# Command Mode via a Command Modifier — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the unreliable auto-Cmd+C selection probe with an explicit command modifier held together with the dictation chord, so plain dictation never touches the clipboard and transform is a deliberate gesture.

**Architecture:** The hold-to-talk chord (`HotkeyStateMachine`) is untouched. A new orthogonal *command modifier* is tracked in `HotkeyMonitor`, sampled at recording start, and threaded through `CapturePipeline.startRecording(command:)`. The selection probe runs **only** in command mode; dictation is pure and clipboard-free. Mode is decided at recording start ("hold your keys, then talk").

**Tech Stack:** Swift 6 (strict concurrency, `@MainActor`), AppKit/CoreGraphics, SwiftUI settings, Swift Testing (`import Testing`, `@Test`, `#expect`), UserDefaults-backed settings.

## Global Constraints

- **Default dictation chord** (this plan changes it): `HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)` → displays "Left Shift + Left Control".
- **Default command modifier:** `.leftOption` when the defaults key is unset. `nil` means command mode **off** (never touch clipboard).
- **Off sentinel** stored in UserDefaults for an explicit-off command modifier: the string `"off"`.
- **Exact toast copy** (verbatim): `"Select text to transform"` for a command gesture with no selection.
- **Never** spawn the selection probe (`selectionTask`) in dictation mode (`command == false`). This is the core fix.
- Tests use **per-test isolated UserDefaults suites**: `UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!`.
- TDD: failing test first, then minimal implementation. **Commit after each task.** Each task must leave the build green (`swift build`) and tests passing.
- Build/test command for this repo: `xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | xcbeautify` (or `swift test` if the package target is used — check `CLAUDE.md`/scripts before running; a plain `swift build` from repo root validates compilation).

---

## File Structure

**Modified source:**
- `voxline/Hotkey/HotkeyChord.swift` — new default chord; `Modifier.isHeld(in:)`; `commandModifierConflictWarning(command:chord:)`.
- `voxline/Storage/AppSettings.swift` — `commandModifier` property + key + `defaultCommandModifier`.
- `voxline/Pipeline/CapturePipeline.swift` — `startRecording(command:)`, gated probe, explicit finalize routing, empty-selection toast.
- `voxline/AppState.swift` — `recordingIsCommand` flag for the pill cue.
- `voxline/Hotkey/HotkeyMonitor.swift` — `commandModifier`, `lastCommandFlag`, `commandIsHeld(...)`, `onStartRecording((Bool) -> Void)`.
- `voxline/Settings/GeneralSettingsViewModel.swift` — snapshot field, VM property, `commandModifierWarning`, commit/reset/refresh.
- `voxline/Settings/SettingsView.swift` — command-modifier Picker + warning.
- `voxline/Output/ClipboardInjector.swift` — `chordOrCommandIsHeld(...)`, `makeChordIsHeld(chord:command:)`.
- `voxline/voxlineApp.swift` — thread `command` through monitor→pipeline; wire `commandModifier` into monitor + injector; `apply()` updates monitor.
- `voxline/UI/RecordingPillView.swift` — "Command" cue while recording in command mode.

**Modified tests:**
- `voxlineTests/HotkeyChordTests.swift`, `voxlineTests/AppSettingsTests.swift`, `voxlineTests/CapturePipelineTests.swift`, `voxlineTests/GeneralSettingsViewModelTests.swift`, `voxlineTests/ClipboardInjectorTests.swift`.

**New tests:**
- `voxlineTests/HotkeyMonitorTests.swift` — command sampling predicate + `Modifier.isHeld`.

**Docs:**
- `docs/superpowers/specs/2026-07-10-transform-selection-by-voice-design.md` (superseded note), `docs/features.md`, `CHANGELOG.md`.

---

## Task 1: Change the default dictation chord to Left Shift + Left Control

**Files:**
- Modify: `voxline/Hotkey/HotkeyChord.swift:52`
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift:137` (stale comment)
- Test: `voxlineTests/HotkeyChordTests.swift:8-18`

**Interfaces:**
- Produces: `HotkeyChord.default == HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)` (used everywhere `.default` is referenced).

- [ ] **Step 1: Update the two failing assertions in HotkeyChordTests**

Replace the body of `default_is_right_cmd_plus_right_option` and rename it, and fix `display_name_lists_both_modifiers_in_order`:

```swift
@Test func default_is_left_shift_plus_left_control() {
    let c = HotkeyChord.default
    #expect(c.modifierA == .leftShift)
    #expect(c.modifierB == .leftControl)
}

@Test func display_name_lists_both_modifiers_in_order() {
    #expect(HotkeyChord.default.displayName == "Left Shift + Left Ctrl")
    let c = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
    #expect(c.displayName == "Left Cmd + Left Shift")
}
```

Note: `Modifier.leftControl.displayName` is `"Left Ctrl"` (see `HotkeyChord.swift:37`), so the default display name is `"Left Shift + Left Ctrl"`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests 2>&1 | xcbeautify`
Expected: FAIL — `.default` is still `Right Cmd + Right Option`.

- [ ] **Step 3: Change the default chord**

In `voxline/Hotkey/HotkeyChord.swift:52`:

```swift
    static let `default` = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
```

- [ ] **Step 4: Fix the stale reset comment**

In `voxline/Settings/GeneralSettingsViewModel.swift:137`, change:

```swift
    /// Restore Spec defaults: hotkey to Left Shift + Left Control, system-default
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests 2>&1 | xcbeautify`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Hotkey/HotkeyChord.swift voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/HotkeyChordTests.swift
git commit -m "feat(hotkey): change default dictation chord to Left Shift + Left Control"
```

---

## Task 2: Add `Modifier.isHeld(in:)` and command-modifier conflict warning

**Files:**
- Modify: `voxline/Hotkey/HotkeyChord.swift`
- Test: `voxlineTests/HotkeyChordTests.swift`

**Interfaces:**
- Produces:
  - `func HotkeyChord.Modifier.isHeld(in flags: CGEventFlags) -> Bool`
  - `static func HotkeyChord.commandModifierConflictWarning(command: Modifier?, chord: HotkeyChord) -> String?`
- Consumes: `Modifier.deviceMaskBit` (existing).

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/HotkeyChordTests.swift` (inside the suite):

```swift
    @Test func modifier_isHeld_reads_device_mask_bit() {
        let optionFlags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyChord.Modifier.leftOption.isHeld(in: optionFlags) == true)
        #expect(HotkeyChord.Modifier.leftShift.isHeld(in: optionFlags) == false)
        #expect(HotkeyChord.Modifier.leftOption.isHeld(in: CGEventFlags(rawValue: 0)) == false)
    }

    @Test func command_conflict_warning_nil_when_off() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        #expect(HotkeyChord.commandModifierConflictWarning(command: nil, chord: chord) == nil)
    }

    @Test func command_conflict_warning_fires_when_equal_to_a_chord_key() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        let w = HotkeyChord.commandModifierConflictWarning(command: .leftShift, chord: chord)
        #expect(w != nil)
        #expect(w?.contains("hotkey") == true)
    }

    @Test func command_conflict_warning_fires_for_ctrl_option_voiceover_combo() {
        // chord holds Left Control; adding Left Option forms Ctrl+Option (VoiceOver).
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        let w = HotkeyChord.commandModifierConflictWarning(command: .leftOption, chord: chord)
        #expect(w != nil)
        #expect(w?.contains("VoiceOver") == true)
    }

    @Test func command_conflict_warning_nil_for_safe_combo() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        // Left Command doesn't collide and doesn't form Ctrl+Option.
        #expect(HotkeyChord.commandModifierConflictWarning(command: .leftCommand, chord: chord) == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests 2>&1 | xcbeautify`
Expected: FAIL — `isHeld` and `commandModifierConflictWarning` are undefined.

- [ ] **Step 3: Implement `isHeld` and the warning helper**

In `voxline/Hotkey/HotkeyChord.swift`, add inside `enum Modifier` (after `displayName`):

```swift
        /// True when this modifier's device-mask bit is set in `flags`.
        /// Bit-equivalent to the chord matching in `HotkeyMonitor`'s tap callback.
        func isHeld(in flags: CGEventFlags) -> Bool {
            flags.contains(CGEventFlags(rawValue: deviceMaskBit))
        }
```

Add `import CoreGraphics` if not already present (it is — line 2). Then add to the `HotkeyChord` struct (after `conflictWarning`):

```swift
    /// Soft warning for a chosen command modifier. Returns nil when command
    /// mode is off (`command == nil`) or the choice is clean. Two known problems:
    ///   1. The command modifier equals one of the two chord keys — command mode
    ///      would then be "always on" (dictation impossible). Rejected upstream
    ///      in `HotkeyMonitor`, but warn here so the user understands.
    ///   2. Holding the command modifier together with the chord forms Ctrl+Option,
    ///      the VoiceOver modifier.
    static func commandModifierConflictWarning(command: Modifier?, chord: HotkeyChord) -> String? {
        guard let command else { return nil }
        if command == chord.modifierA || command == chord.modifierB {
            return "The command modifier can't be one of your two hotkey keys. Pick a different key or set it to Off."
        }
        let all = [chord.modifierA, chord.modifierB, command]
        let isControl: (Modifier) -> Bool = { $0 == .leftControl || $0 == .rightControl }
        let isOption:  (Modifier) -> Bool = { $0 == .leftOption  || $0 == .rightOption }
        if all.contains(where: isControl) && all.contains(where: isOption) {
            return "Holding this together with your hotkey forms Ctrl+Option, the VoiceOver modifier. If VoiceOver is on, command mode may conflict."
        }
        return nil
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests 2>&1 | xcbeautify`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Hotkey/HotkeyChord.swift voxlineTests/HotkeyChordTests.swift
git commit -m "feat(hotkey): add Modifier.isHeld and command-modifier conflict warning"
```

---

## Task 3: Add `commandModifier` to AppSettings

**Files:**
- Modify: `voxline/Storage/AppSettings.swift`
- Test: `voxlineTests/AppSettingsTests.swift`

**Interfaces:**
- Produces:
  - `static let AppSettings.defaultCommandModifier: HotkeyChord.Modifier? = .leftOption`
  - `var AppSettings.commandModifier: HotkeyChord.Modifier?` — unset → `.leftOption`; `"off"` → `nil`; else the stored `Modifier`.
  - `AppSettings.Key.commandModifier == "voxline.hotkey.commandModifier"`

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/AppSettingsTests.swift` (inside the suite):

```swift
    @Test func unset_command_modifier_defaults_to_left_option() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).commandModifier == .leftOption)
    }

    @Test func command_modifier_round_trips_a_modifier() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.commandModifier = .rightShift
        #expect(AppSettings(defaults: d).commandModifier == .rightShift)
    }

    @Test func command_modifier_off_round_trips_as_nil() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.commandModifier = nil   // explicit "off"
        #expect(AppSettings(defaults: d).commandModifier == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests 2>&1 | xcbeautify`
Expected: FAIL — `commandModifier` undefined.

- [ ] **Step 3: Implement the setting**

In `voxline/Storage/AppSettings.swift`, add to `enum Key` (after `hotkeyChord`):

```swift
        static let commandModifier = "voxline.hotkey.commandModifier"
```

Add a static default near the top of the struct (after `let defaults`):

```swift
    /// Command modifier applied when the defaults key is unset. `nil` here would
    /// mean "off by default"; we ship command mode ON with Left Option.
    static let defaultCommandModifier: HotkeyChord.Modifier? = .leftOption
```

Add the property (after `hotkeyChord`, before `audioInputDeviceUID`):

```swift
    /// Optional modifier held together with the dictation chord to mean "this
    /// utterance is a command." Absent key → `defaultCommandModifier`
    /// (`.leftOption`). The sentinel string `"off"` → `nil` (command mode off:
    /// pure dictation, clipboard never touched).
    var commandModifier: HotkeyChord.Modifier? {
        get {
            guard let raw = defaults.string(forKey: Key.commandModifier) else {
                return AppSettings.defaultCommandModifier
            }
            if raw == "off" { return nil }
            return HotkeyChord.Modifier(rawValue: raw) ?? AppSettings.defaultCommandModifier
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.commandModifier)
            } else {
                defaults.set("off", forKey: Key.commandModifier)
            }
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests 2>&1 | xcbeautify`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxlineTests/AppSettingsTests.swift
git commit -m "feat(settings): persist optional command modifier (default Left Option)"
```

---

## Task 4: Gate the selection probe on command mode in CapturePipeline

**Files:**
- Modify: `voxline/AppState.swift` (add `recordingIsCommand`)
- Modify: `voxline/Pipeline/CapturePipeline.swift:81` (`startRecording`), `:157` (`finalizeRecording`)
- Test: `voxlineTests/CapturePipelineTests.swift`

**Interfaces:**
- Consumes: existing `selectionSnapshot`, `performTransform`, `showToast`, `resetIdle`.
- Produces:
  - `func CapturePipeline.startRecording(command: Bool = false)` — spawns `selectionTask` only when `command == true`; sets `state.recordingIsCommand`.
  - `func CapturePipeline.finalizeRecording()` — routes on the latched command flag: command+selection → transform; command+empty → toast `"Select text to transform"`; dictation → cleanup (never probes).
  - `var AppState.recordingIsCommand: Bool` — read by the pill.

- [ ] **Step 1: Extend `FakeSelectionSnapshot` with a call counter**

In `voxlineTests/CapturePipelineTests.swift:82-85`, replace `FakeSelectionSnapshot`:

```swift
    final class FakeSelectionSnapshot: SelectionSnapshotting, @unchecked Sendable {
        var selection: String?
        private(set) var readCount = 0
        func readSelection() async -> String? { readCount += 1; return selection }
    }
```

- [ ] **Step 2: Add a `command`-aware helper and write the new failing tests**

In `voxlineTests/CapturePipelineTests.swift`, update the `startAndFinalize` helper (line 89) to accept a command flag:

```swift
    private func startAndFinalize(_ pipe: CapturePipeline, state: AppState, command: Bool = false) async {
        pipe.startRecording(command: command)
        state.lastPeakLevel = 0.5
        await pipe.finalizeRecording()
    }
```

Update the existing transform tests to press the command modifier. In each of these tests, change the recording line from
`pipe.startRecording(); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()`
to
`pipe.startRecording(command: true); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()`:

- `finalize_withSelection_transformsAndOpensTransformReview`
- `refine_onTransformSession_usesTransformOnCurrentText`
- `finalize_withSelection_unchangedResult_showsToastNoWrite`
- `finalize_withSelection_llmError_setsError`
- `finalize_withSelection_injectFails_fallsBackToClipboard`
- `finalize_withSelection_overLimit_refusesWithToast`
- `finalize_withSelection_focusMovedDuringLLM_fallsBackToClipboard`

Leave `finalize_withEmptySelection_usesDictationPath` calling `pipe.startRecording()` (no command) — it now asserts the command-off dictation path, which is still correct.

Add these NEW tests to the "Selection detection + transform" section:

```swift
    @Test func finalize_commandMode_emptySelection_showsSelectToast() async {
        let (pipe, state, llm, injector, history) = makeTransformPipeline(selection: "")
        pipe.startRecording(command: true); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(llm.transformCalls.isEmpty)      // no transform attempted
        #expect(llm.calls.isEmpty)               // no dictation cleanup either
        #expect(injector.injected.isEmpty)
        #expect(history.items.isEmpty)
        #expect(state.reviewSession == nil)
        #expect(state.toastMessage == "Select text to transform")
        if case .idle = state.status {} else { Issue.record("expected .idle") }
    }

    @Test func finalize_dictationMode_neverSpawnsSelectionProbe() async {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let llm = FakeLLM()
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector()
        let injector = FakeInjector()
        let snap = FakeSelectionSnapshot(); snap.selection = "user had something selected"
        let router = ModeRouter(modes: [
            Mode(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
            Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
        ])
        let name = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state, capture: capture, transcriber: transcriber,
            llm: llm, modes: router, frontmost: front,
            fieldInspector: inspector, injector: injector,
            historyStore: history, contextCapture: FakeContextCapture(),
            selectionSnapshot: snap
        )

        pipe.startRecording(command: false); state.lastPeakLevel = 0.5; await pipe.finalizeRecording()

        #expect(snap.readCount == 0)             // THE FIX: dictation never touches the selection
        #expect(llm.transformCalls.isEmpty)
        #expect(llm.calls.count == 1)            // dictation cleanup ran
        #expect(injector.injected.last == "cleaned")
        #expect(state.reviewSession?.kind == .dictation)
    }

    @Test func startRecording_command_sets_recordingIsCommand_flag() {
        let (pipe, state, _, _, _, _, _, _, _) = makePipeline()
        pipe.startRecording(command: true)
        #expect(state.recordingIsCommand == true)
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests 2>&1 | xcbeautify`
Expected: FAIL — `startRecording(command:)` and `state.recordingIsCommand` don't exist; several existing transform tests fail because the new dictation routing ignores the probe.

- [ ] **Step 4: Add `recordingIsCommand` to AppState**

In `voxline/AppState.swift`, add after `var recordingStartedAt: Date?` (line 67):

```swift
    /// True while the current recording is a command gesture (command modifier
    /// held at start). Read by the recording pill to show a "Command" cue.
    /// Set at `startRecording`; only meaningful while `status == .recording`.
    var recordingIsCommand: Bool = false
```

- [ ] **Step 5: Gate the probe in `startRecording`**

In `voxline/Pipeline/CapturePipeline.swift`, change the signature (line 81) and the selection-task spawn (lines 130-133).

Signature:

```swift
    /// Begin a new recording. Caller must ensure we're not already recording.
    /// `command` reflects whether the command modifier was held at chord
    /// completion; when true this is a transform gesture and the selection is
    /// probed once, here at start. When false (plain dictation) the clipboard
    /// is never touched.
    func startRecording(command: Bool = false) {
```

Just before `state.status = .recording` (currently line 125), record the mode:

```swift
        state.recordingIsCommand = command
        state.status = .recording
```

Replace the unconditional selection-task block (lines 130-133):

```swift
        // Selection probe runs ONLY in command mode. In dictation the clipboard
        // is never touched — this is the fix for VS Code's line-copy false
        // positive (empty-selection Cmd+C copies the whole line).
        if command {
            let snapshotter = selectionSnapshot
            selectionTask = Task.detached(priority: .userInitiated) {
                await snapshotter.readSelection()
            }
        } else {
            selectionTask = nil
        }
```

- [ ] **Step 6: Route explicitly in `finalizeRecording`**

In `voxline/Pipeline/CapturePipeline.swift`, replace the selection-inference block (currently lines 210-219):

```swift
        // 3. LLM cleanup.
        let context = await contextTask?.value ?? .empty
        contextTask = nil
        // If text was selected when recording started, treat the speech as a
        // command to transform that selection instead of as dictation.
        if let selection, !selection.isEmpty {
            await performTransform(command: transcript, selection: selection, mode: mode, context: context)
            return
        }
```

with command-driven routing:

```swift
        // 3. Route by mode. `recordingIsCommand` was latched at recording start.
        let context = await contextTask?.value ?? .empty
        contextTask = nil
        if state.recordingIsCommand {
            let selection = await selectionTask?.value ?? nil
            selectionTask = nil
            guard let selection, !selection.isEmpty else {
                // Command gesture but nothing selected: keep the mode boundary
                // crisp — no dictation fallback, no clipboard-probe surprise.
                resetIdle()
                showToast("Select text to transform")
                return
            }
            await performTransform(command: transcript, selection: selection, mode: mode, context: context)
            return
        }
        // Dictation path: selectionTask was never spawned, so the clipboard was
        // never touched.
```

The remaining dictation code (the `if !context.captureNotes.isEmpty` log and the `llm.cleanup` call, currently lines 220 onward) stays exactly as-is directly below.

- [ ] **Step 7: Run to verify pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/CapturePipelineTests 2>&1 | xcbeautify`
Expected: PASS (all transform, dictation, empty-command, and no-probe tests green).

- [ ] **Step 8: Commit**

```bash
git add voxline/AppState.swift voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineTests.swift
git commit -m "feat(pipeline): gate selection probe on command mode; explicit finalize routing"
```

---

## Task 5: HotkeyMonitor command sampling + thread into voxlineApp

This task changes `HotkeyMonitor.onStartRecording` to carry a `Bool`, so its only consumer (`voxlineApp.installHotkey`) is updated in the same commit to keep the build green.

**Files:**
- Modify: `voxline/Hotkey/HotkeyMonitor.swift`
- Modify: `voxline/voxlineApp.swift:297-318` (`installHotkey`), `:576-608` (`apply`)
- Test: `voxlineTests/HotkeyMonitorTests.swift` (new)

**Interfaces:**
- Consumes: `HotkeyChord.Modifier.isHeld(in:)` (Task 2), `AppSettings.commandModifier` (Task 3), `CapturePipeline.startRecording(command:)` (Task 4).
- Produces:
  - `var HotkeyMonitor.commandModifier: HotkeyChord.Modifier?` (default `.leftOption`)
  - `var HotkeyMonitor.onStartRecording: ((Bool) -> Void)?`
  - `static func HotkeyMonitor.commandIsHeld(in flags: CGEventFlags, chord: HotkeyChord, commandModifier: HotkeyChord.Modifier?) -> Bool`

- [ ] **Step 1: Write the failing sampling tests (new file)**

Create `voxlineTests/HotkeyMonitorTests.swift`:

```swift
import Testing
import CoreGraphics
@testable import voxline

@MainActor
@Suite struct HotkeyMonitorTests {

    private let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)

    @Test func command_held_true_when_command_modifier_bit_set() {
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftOption) == true)
    }

    @Test func command_held_false_when_bit_absent() {
        let flags = CGEventFlags(rawValue: 0)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftOption) == false)
    }

    @Test func command_held_false_when_modifier_is_off() {
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: nil) == false)
    }

    @Test func command_held_false_when_modifier_collides_with_chord_key() {
        // Even with the bit set, a command modifier equal to a chord key is
        // ignored (rejected upstream) so dictation stays possible.
        let flags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftShift.deviceMaskBit)
        #expect(HotkeyMonitor.commandIsHeld(in: flags, chord: chord, commandModifier: .leftShift) == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyMonitorTests 2>&1 | xcbeautify`
Expected: FAIL — `HotkeyMonitor.commandIsHeld` undefined.

- [ ] **Step 3: Add the sampling function, property, and observer signature**

In `voxline/Hotkey/HotkeyMonitor.swift`:

Change the observer property (line 13):

```swift
    /// Observer notified when the state machine produces `startRecording`.
    /// The `Bool` is whether the command modifier was held at recording start
    /// (command gesture) vs plain dictation. Runs on the main actor.
    var onStartRecording: ((Bool) -> Void)?
```

Add the command-modifier property after `chord` (line 27):

```swift
    /// Command modifier sampled at recording start. `nil` = command mode off.
    /// Defaults to `.leftOption`; AppCoordinator overrides from AppSettings on
    /// launch and on every settings change.
    var commandModifier: HotkeyChord.Modifier? = .leftOption

    /// Latest observed command-modifier state, updated on EVERY flagsChanged
    /// (mirroring `HotkeyStateMachine.lastFlags`) so the resume-on-
    /// `recordingFinished` path — which emits `startRecording` with no live
    /// event — samples the current value.
    private var lastCommandFlag = false
```

Add the pure static helper (place it near the top of the type, e.g. after the properties block):

```swift
    /// Pure sampling predicate — testable without a CGEventTap. Whether the
    /// command modifier is held in `flags`. A modifier that collides with a
    /// chord key (or `nil`) is treated as "not a command", so command mode can
    /// never make plain dictation impossible.
    nonisolated static func commandIsHeld(in flags: CGEventFlags, chord: HotkeyChord, commandModifier: HotkeyChord.Modifier?) -> Bool {
        guard let cmd = commandModifier,
              cmd != chord.modifierA,
              cmd != chord.modifierB else { return false }
        return cmd.isHeld(in: flags)
    }
```

In the tap callback (the `.flagsChanged` branch, inside `MainActor.assumeIsolated`, lines 98-102), add the command sampling before `feed`:

```swift
            MainActor.assumeIsolated {
                let chord = monitor.chord
                let modA = flags.contains(CGEventFlags(rawValue: chord.modifierA.deviceMaskBit))
                let modB = flags.contains(CGEventFlags(rawValue: chord.modifierB.deviceMaskBit))
                monitor.lastCommandFlag = HotkeyMonitor.commandIsHeld(
                    in: flags, chord: chord, commandModifier: monitor.commandModifier
                )
                monitor.feed(.flagsChanged(modAFlag: modA, modBFlag: modB))
            }
```

In `feed`, pass the flag on start (line 125-127):

```swift
            case .startRecording:
                scheduleMaxDurationTimer()
                onStartRecording?(lastCommandFlag)
```

- [ ] **Step 4: Update voxlineApp wiring**

In `voxline/voxlineApp.swift`, `installHotkey` — set the command modifier and thread the flag (lines 298-304):

```swift
        let monitor = HotkeyMonitor()
        monitor.chord = settings.hotkeyChord
        monitor.commandModifier = settings.commandModifier
        monitor.onStartRecording = { [weak self, weak state] command in
            self?.soundPlayer?.playStart()
            self?.pipeline?.startRecording(command: command)
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
```

In `apply(_:)` (lines 576-608), update the monitor's command modifier alongside the chord (after line 580 `hotkeyMonitor?.chord = snapshot.chord`):

```swift
        hotkeyMonitor?.chord = snapshot.chord
        hotkeyMonitor?.commandModifier = snapshot.commandModifier
```

(Note: `snapshot.commandModifier` is added in Task 6. If executing strictly in order, this line will not compile until Task 6 adds the snapshot field — so add this single line as part of Task 6's edit instead, OR complete Task 6 immediately after. To keep Task 5 self-contained and green, temporarily read from `AppSettings().commandModifier` here and switch to `snapshot.commandModifier` in Task 6:)

```swift
        hotkeyMonitor?.chord = snapshot.chord
        hotkeyMonitor?.commandModifier = AppSettings().commandModifier   // Task 6 switches to snapshot.commandModifier
```

- [ ] **Step 5: Run to verify pass (targeted + full build)**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyMonitorTests 2>&1 | xcbeautify`
Expected: PASS.

Run: `swift build 2>&1 | tail -5` (or a full `xcodebuild build`) to confirm `voxlineApp.swift` compiles with the new `onStartRecording` signature.
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add voxline/Hotkey/HotkeyMonitor.swift voxline/voxlineApp.swift voxlineTests/HotkeyMonitorTests.swift
git commit -m "feat(hotkey): sample command modifier at recording start and thread into pipeline"
```

---

## Task 6: Carry `commandModifier` through GeneralSettings (snapshot, VM, validation)

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/voxlineApp.swift:581` (switch to `snapshot.commandModifier`)
- Test: `voxlineTests/GeneralSettingsViewModelTests.swift`

**Interfaces:**
- Consumes: `AppSettings.commandModifier` (Task 3), `HotkeyChord.commandModifierConflictWarning` (Task 2).
- Produces:
  - `GeneralSettingsSnapshot.commandModifier: HotkeyChord.Modifier?`
  - `var GeneralSettingsViewModel.commandModifier: HotkeyChord.Modifier?`
  - `var GeneralSettingsViewModel.commandModifierWarning: String?`

- [ ] **Step 1: Write the failing tests**

Add to `voxlineTests/GeneralSettingsViewModelTests.swift` (inside the suite):

```swift
    @Test func loads_command_modifier_on_init() {
        var settings = AppSettings(defaults: defaults())
        settings.commandModifier = .rightShift
        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        #expect(vm.commandModifier == .rightShift)
    }

    @Test func command_modifier_mutation_persists_and_applies() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(settings: settings, onApply: { recorder.record($0) })

        vm.commandModifier = .rightControl
        #expect(recorder.applied?.commandModifier == .rightControl)
        #expect(AppSettings(defaults: d).commandModifier == .rightControl)

        vm.commandModifier = nil   // "Off"
        #expect(recorder.applied?.commandModifier == nil)
        #expect(AppSettings(defaults: d).commandModifier == nil)
    }

    @Test func command_modifier_warning_fires_when_equal_to_chord_key() {
        let settings = AppSettings(defaults: defaults())
        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        vm.chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        vm.commandModifier = .leftShift
        #expect(vm.commandModifierWarning != nil)
    }

    @Test func command_modifier_warning_nil_for_clean_default() {
        let settings = AppSettings(defaults: defaults())
        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        vm.chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)
        vm.commandModifier = .leftCommand
        #expect(vm.commandModifierWarning == nil)
    }

    @Test func reset_restores_default_command_modifier() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.commandModifier = .rightShift
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: { recorder.record($0) },
            loginItemService: LoginItemService(),
            vocabulary: CustomVocabularyStore(defaults: d)
        )
        vm.resetToDefaults()
        #expect(vm.commandModifier == AppSettings.defaultCommandModifier)
        #expect(recorder.applied?.commandModifier == AppSettings.defaultCommandModifier)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | xcbeautify`
Expected: FAIL — `commandModifier` / `commandModifierWarning` / snapshot field undefined.

- [ ] **Step 3: Add the snapshot field**

In `voxline/Settings/GeneralSettingsViewModel.swift`, add to `GeneralSettingsSnapshot` (after `chord`):

```swift
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let commandModifier: HotkeyChord.Modifier?
    let audioInputDeviceUID: String?
    let whisperModel: WhisperModel
    let playHotkeySounds: Bool
    let provider: LLMProvider
}
```

- [ ] **Step 4: Add the VM property, warning, and wire commit/reset/refresh/init**

Add the observable property (after `var chord`):

```swift
    var commandModifier: HotkeyChord.Modifier? { didSet { if loaded { commit() } } }
```

Add the warning computed property (near `deviceRows`):

```swift
    /// Soft warning for the current command-modifier choice, or nil when clean.
    var commandModifierWarning: String? {
        HotkeyChord.commandModifierConflictWarning(command: commandModifier, chord: chord)
    }
```

In **both** `init`s, initialize it. The designated `init` (lines 65-90) already sets `self.chord = settings.hotkeyChord`; add right after:

```swift
        self.commandModifier = settings.commandModifier
```

In `refreshFromUserDefaults()` (inside `withoutCommitting`, after `chord = settings.hotkeyChord`):

```swift
            commandModifier = settings.commandModifier
```

In `resetToDefaults()` (inside `withoutCommitting`, after `chord = .default`):

```swift
            commandModifier = AppSettings.defaultCommandModifier
```

In `commit()`, persist and include in the snapshot (after `s.hotkeyChord = chord`):

```swift
        s.hotkeyChord = chord
        s.commandModifier = commandModifier
```

and in the `GeneralSettingsSnapshot(...)` constructor within `commit()`:

```swift
        onApply(GeneralSettingsSnapshot(
            chord: chord,
            commandModifier: commandModifier,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds,
            provider: provider
        ))
```

- [ ] **Step 5: Switch voxlineApp.apply to the snapshot field**

In `voxline/voxlineApp.swift` (the line added in Task 5), change:

```swift
        hotkeyMonitor?.commandModifier = snapshot.commandModifier
```

- [ ] **Step 6: Run to verify pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | xcbeautify`
Expected: PASS.

Also run the full suite once to confirm no snapshot consumers broke:
Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | xcbeautify`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/voxlineApp.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "feat(settings): carry command modifier through view model, validation, and apply"
```

---

## Task 7: Command-modifier Picker in SettingsView

UI-only. Verified by build + manual check (SwiftUI views have no unit tests in this codebase).

**Files:**
- Modify: `voxline/Settings/SettingsView.swift:66-68`

**Interfaces:**
- Consumes: `generalVM.commandModifier`, `generalVM.commandModifierWarning`, `HotkeyChord.Modifier.allCases` / `.displayName`.

- [ ] **Step 1: Add the Picker and warning to the Hotkey section**

In `voxline/Settings/SettingsView.swift`, replace the Hotkey section (lines 66-69):

```swift
                    Section("Hotkey") {
                        ChordRecorderView(chord: $generalVM.chord)
                        Picker("Command modifier", selection: $generalVM.commandModifier) {
                            Text("Off").tag(HotkeyChord.Modifier?.none)
                            ForEach(HotkeyChord.Modifier.allCases, id: \.self) { m in
                                Text(m.displayName).tag(HotkeyChord.Modifier?.some(m))
                            }
                        }
                        if let warning = generalVM.commandModifierWarning {
                            Text(warning)
                                .foregroundStyle(.orange)
                                .font(.callout)
                        }
                        Text("Hold the command modifier together with your hotkey to transform the selected text by voice instead of dictating. Set to Off for pure dictation — voxline then never touches the clipboard.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .id(SettingsAnchor.hotkey)
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5` (or `xcodebuild build -scheme voxline -destination 'platform=macOS' 2>&1 | xcbeautify`)
Expected: build succeeds. (`HotkeyChord.Modifier` is a `String` enum → `Hashable`, satisfying `ForEach(id: \.self)` and optional `.tag`.)

- [ ] **Step 3: Commit**

```bash
git add voxline/Settings/SettingsView.swift
git commit -m "feat(settings): add command-modifier picker with conflict warning"
```

---

## Task 8: Account for the command modifier in the paste-release gate

Fixes the "paste while modifiers held" risk: during a transform paste the user may still hold the chord **and** the command modifier; the Cmd+V release gate must wait for the command modifier too, or the synthetic paste merges into Cmd+Option+V.

**Files:**
- Modify: `voxline/Output/ClipboardInjector.swift:346-358`
- Modify: `voxline/voxlineApp.swift:243-257` (`buildServices` injector wiring)
- Test: `voxlineTests/ClipboardInjectorTests.swift`

**Interfaces:**
- Consumes: `HotkeyChord.Modifier.isHeld(in:)` (Task 2), `AppSettings.commandModifier` (Task 3).
- Produces:
  - `static func ClipboardInjector.chordOrCommandIsHeld(in flags: CGEventFlags, chord: HotkeyChord, command: HotkeyChord.Modifier?) -> Bool`
  - `static func ClipboardInjector.makeChordIsHeld(chord:command:) -> @Sendable () -> Bool` (signature gains `command:`)

- [ ] **Step 1: Write the failing test**

Add to `voxlineTests/ClipboardInjectorTests.swift` (near the existing `chord_held_predicate...` test):

```swift
    @Test func chord_or_command_held_predicate_includes_command_modifier() {
        let chord = HotkeyChord(modifierA: .leftShift, modifierB: .leftControl)

        let optionFlags = CGEventFlags(rawValue: HotkeyChord.Modifier.leftOption.deviceMaskBit)
        let shiftFlags  = CGEventFlags(rawValue: HotkeyChord.Modifier.leftShift.deviceMaskBit)
        let none        = CGEventFlags(rawValue: 0)

        // Command modifier alone (Left Option) counts as "held".
        #expect(ClipboardInjector.chordOrCommandIsHeld(in: optionFlags, chord: chord, command: .leftOption) == true)
        // Chord key alone still counts.
        #expect(ClipboardInjector.chordOrCommandIsHeld(in: shiftFlags, chord: chord, command: .leftOption) == true)
        // Nothing held.
        #expect(ClipboardInjector.chordOrCommandIsHeld(in: none, chord: chord, command: .leftOption) == false)
        // Command mode off: Left Option no longer gates the paste.
        #expect(ClipboardInjector.chordOrCommandIsHeld(in: optionFlags, chord: chord, command: nil) == false)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | xcbeautify`
Expected: FAIL — `chordOrCommandIsHeld` undefined.

- [ ] **Step 3: Implement the combined predicate and factory**

In `voxline/Output/ClipboardInjector.swift`, add after `chordIsHeld(in:chord:)` (line 350):

```swift
    /// Like `chordIsHeld`, but also returns true when the optional command
    /// modifier is held. Gating the paste on this prevents a transform paste
    /// from merging a still-held command modifier (e.g. Left Option) into the
    /// synthetic Cmd+V (→ Cmd+Option+V).
    nonisolated static func chordOrCommandIsHeld(in flags: CGEventFlags, chord: HotkeyChord, command: HotkeyChord.Modifier?) -> Bool {
        if chordIsHeld(in: flags, chord: chord) { return true }
        if let command { return command.isHeld(in: flags) }
        return false
    }
```

Replace `makeChordIsHeld(chord:)` (lines 353-358) with a two-provider version:

```swift
    /// Late-binds the chord and command modifier so Settings updates take effect
    /// without rebuilding the injector.
    nonisolated static func makeChordIsHeld(
        chord: @escaping @Sendable () -> HotkeyChord,
        command: @escaping @Sendable () -> HotkeyChord.Modifier?
    ) -> @Sendable () -> Bool {
        {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            return chordOrCommandIsHeld(in: flags, chord: chord(), command: command())
        }
    }
```

Update the doc comment on `defaultChordIsHeld` (line 360) to reference `makeChordIsHeld(chord:command:)`.

- [ ] **Step 4: Update the production injector wiring**

In `voxline/voxlineApp.swift`, `buildServices` (lines 243, 253-257):

```swift
        let chordProvider: @Sendable () -> HotkeyChord = { AppSettings().hotkeyChord }
        let commandModifierProvider: @Sendable () -> HotkeyChord.Modifier? = { AppSettings().commandModifier }
```

and:

```swift
        let injector = ClipboardInjector(
            focusedTextSystem: focusedTextSystem,
            pasteEligibility: AlwaysPasteEligible(),
            chordIsHeld: ClipboardInjector.makeChordIsHeld(chord: chordProvider, command: commandModifierProvider)
        )
```

- [ ] **Step 5: Run to verify pass + full build**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ClipboardInjectorTests 2>&1 | xcbeautify`
Expected: PASS. (Existing `chordIsHeld(in:chord:)` test and the `chordIsHeld:` init-parameter tests are unaffected — the instance parameter name is unchanged.)

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add voxline/Output/ClipboardInjector.swift voxline/voxlineApp.swift voxlineTests/ClipboardInjectorTests.swift
git commit -m "fix(paste): gate transform paste on command-modifier release too"
```

---

## Task 9: Show a "Command" cue in the recording pill

UI-only. Verified by build + manual check.

**Files:**
- Modify: `voxline/UI/RecordingPillView.swift:12-18`

**Interfaces:**
- Consumes: `AppState.recordingIsCommand` (Task 4).

- [ ] **Step 1: Add the cue to the `.recording` case**

In `voxline/UI/RecordingPillView.swift`, replace the `.recording` case (lines 12-18):

```swift
            case .recording:
                HStack(spacing: 10) {
                    WaveformBars(level: state.audioLevel)
                    if state.recordingIsCommand {
                        Text("Command")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    Text(elapsed)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add voxline/UI/RecordingPillView.swift
git commit -m "feat(ui): show Command cue in recording pill during command mode"
```

---

## Task 10: Documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-07-10-transform-selection-by-voice-design.md:37`
- Modify: `docs/features.md`
- Modify: `CHANGELOG.md:9` (`## [Unreleased]`)

- [ ] **Step 1: Mark the auto-detect decision superseded**

In `docs/superpowers/specs/2026-07-10-transform-selection-by-voice-design.md`, at the "Auto-detect selection. No new hotkey or gesture." decision (line 37), append a note:

```markdown
**Auto-detect selection.** No new hotkey or gesture.

> **Superseded (2026-07-12).** Auto-detecting a selection via a synthetic Cmd+C
> is unreliable in editors with `editor.emptySelectionClipboard` (VS Code
> default), where an empty-selection Cmd+C copies the whole line and misroutes
> dictation into the transform path. Replaced by an explicit **command modifier**
> held with the dictation chord. See
> `docs/superpowers/specs/2026-07-12-command-mode-hotkey-design.md` and
> `docs/superpowers/plans/2026-07-12-command-mode-hotkey.md`.
```

- [ ] **Step 2: Update features.md**

In `docs/features.md`, update the "Selection rewriting" row (line 38) to reflect the explicit gesture:

```markdown
| Selection rewriting | Rewrites selected text intelligently — hold the command modifier (default Left Option) with the hotkey and speak a command |
```

- [ ] **Step 3: Add a CHANGELOG entry**

In `CHANGELOG.md`, under `## [Unreleased]` (line 9), add:

```markdown
## [Unreleased]

### Added

- **Command mode via a command modifier.** Hold an optional command modifier
  (default **Left Option**) together with the dictation hotkey and speak a
  command to transform the selected text. A "Command" cue appears in the pill
  while recording; the modifier is configurable (or set to **Off**) in
  Settings → Hotkey.

### Changed

- **Default dictation hotkey is now Left Shift + Left Control** (was Right Cmd +
  Right Option). Existing users who customized their hotkey keep their choice;
  only the untouched default moves.
- **Plain dictation never touches the clipboard.** The previous release
  auto-detected a selection by posting a synthetic Cmd+C on every recording,
  which misfired in editors that copy the whole line on an empty selection
  (VS Code default) and misrouted dictation into the transform path. Transform
  is now an explicit gesture and the selection is only read in command mode.
```

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/specs/2026-07-10-transform-selection-by-voice-design.md docs/features.md CHANGELOG.md
git commit -m "docs: command-mode hotkey — supersede auto-detect, update features and changelog"
```

---

## Task 11: Full verification pass

- [ ] **Step 1: Run the entire test suite**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | xcbeautify`
Expected: all tests PASS, no build warnings introduced by these changes.

- [ ] **Step 2: Manual end-to-end verification (required — the hotkey path is not unit-tested)**

Build and run the app (see `/run` or `scripts/`), then confirm:

1. **Dictation is clipboard-free.** Put distinctive text on the clipboard. In **VS Code** (with default `editor.emptySelectionClipboard`), place the cursor on a line with **nothing selected**, hold the dictation chord (Left Shift + Left Control) *without* Left Option, dictate a sentence. Expect: the sentence is inserted as dictation; the pill shows **no** "Command" cue; the clipboard still holds your distinctive text (no line-copy, no "Couldn't apply that").
2. **Transform works via the explicit gesture.** Select a phrase, hold Left Shift + Left Control + **Left Option**, speak "make this all caps." Expect: pill shows "Command"; the selection is rewritten in place.
3. **Empty command gesture.** With nothing selected, hold the chord + Left Option and speak. Expect: toast **"Select text to transform"**, no insertion.
4. **Paste-while-held.** During a transform, keep holding all three keys through the LLM round-trip; release only after. Expect: a clean paste (no stray characters from Cmd+Option+V), because the release gate now waits on Left Option too.
5. **Settings.** Open Settings → Hotkey. Change the command modifier to **Off** and confirm command mode no longer triggers (all utterances dictate). Set it to a key that collides with a chord key and confirm the orange warning appears and command mode is still ignored (dictation works). Re-run app / reopen Settings to confirm the choice persisted.

- [ ] **Step 3: Confirm and report**

Summarize the manual verification results. If any step fails, treat it as a bug to fix before considering the feature complete.

---

## Self-Review notes (author)

- **Spec coverage:** command modifier setting (T3/T6/T7), remove unconditional probe (T4), decide-at-start timing (T4/T5), empty-selection toast (T4), HotkeyMonitor sampling incl. resume path (T5), CapturePipeline routing (T4), settings plumbing + validation (T6), pill cue (T9), paste-while-held gate (T8), migration/docs (T10). All mapped.
- **Deliberate deviation from the design doc:** the design proposed `onFinalizeRecording(command:)` with the value latched in the monitor. This plan latches the command flag in `CapturePipeline` (`state.recordingIsCommand`) instead — a single source of truth that avoids a start/finalize mismatch — so `onFinalizeRecording` keeps its no-arg signature. Behaviorally identical.
- **Default-modifier decision (user, 2026-07-12):** default chord → Left Shift + Left Control; default command modifier → Left Option. This resolves the design's Right-Command default, which collided with the shipped right-handed chord.
- **Known VoiceOver overlap:** chord (holds Left Control) + Left Option = Ctrl+Option. Surfaced as a soft warning (T2/T6/T7); harmless unless VoiceOver is enabled.
- **Type consistency:** `startRecording(command:)`, `commandModifier: HotkeyChord.Modifier?`, `commandIsHeld(in:chord:commandModifier:)`, `chordOrCommandIsHeld(in:chord:command:)`, `makeChordIsHeld(chord:command:)`, `GeneralSettingsSnapshot.commandModifier`, `AppState.recordingIsCommand` — names used identically across tasks.
