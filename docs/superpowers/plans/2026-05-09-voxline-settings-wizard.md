# voxline — Settings UI + First-Run Wizard Implementation Plan (Plan 4 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the empty General + Modes settings tabs with full functionality (rebindable hotkey, mic input device picker, Whisper model picker, modes CRUD with "Add from running apps") and ship the first-run wizard from spec §6.4 so a fresh install walks the user through permissions, provider+key, and model download before the app starts dictating.

**Architecture:** Three independent subsystems plug into the existing app shell:

- **General settings** — `HotkeyChord` (Codable two-modifier representation) + `AudioDeviceEnumerator` (CoreAudio input device list) + `GeneralSettingsViewModel`. New `AppSettings` keys for chord, audio input UID, and Whisper model. `AppCoordinator` re-binds `HotkeyMonitor`, restarts `AudioCaptureService`, and re-prepares `TranscriptionService` when the user saves a change.
- **Modes settings** — `ModesSettingsViewModel` (load/edit/add/delete + persist via existing `ModeStore`) + `RunningAppsHelper` (snapshot of `NSWorkspace.runningApplications` for the "Add" picker). `AppCoordinator` exposes a single `apply(modes:)` entry point that swaps `ModeRouter.modes` so saves take effect without restart.
- **First-run wizard** — `WizardViewModel` driving a five-step flow (Welcome → Permissions → API Key → Model Download → Done), hosted in a regular activating `NSWindow` via `FirstRunWindowController`. `AppSettings.hasCompletedFirstRun` gates display. `AppCoordinator.startIfNeeded` shows the wizard *before* installing the hotkey tap or starting model prep on a fresh install; on subsequent launches the existing path runs unchanged. The wizard reuses `APIKeysSettingsViewModel` for the key step and `TranscriptionService.prepareModel/prewarm` for the download step.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSWindow`, `NSWorkspace`), CoreAudio (`AudioObject*` APIs for input device enumeration), `CGEvent` (chord recording in the Settings General tab), Swift Testing (`import Testing`).

**Spec reference:** `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` (v0.2). This plan implements §6.1 (Toggle voxline menu item — added now that the hotkey listener can be disabled), §6.3 (General + Modes tabs), §6.4 (first-run wizard). Hardening (§7+ error states, smoke pass) is Plan 5.

**Predecessors:** Plan 3 merged at `7b8c4c1` plus Plan 3 follow-up commits up to `dfcadec`. Tests pass on `main`. This plan starts from current `main`.

**Out of scope (deferred to Plan 5):**
- Error-state polish for Settings (e.g., red-banner network errors during the wizard's "Test connection")
- "Test connection" button in the API Keys settings tab (the wizard validates once; the settings tab does not)
- Per-app overrides for clipboard restore timing
- Non-US-layout virtual key code for synthetic Cmd+V

---

## File Structure

### New files

- **`voxline/Hotkey/HotkeyChord.swift`** — Codable struct: two `Modifier` enum values + helpers (`displayName`, conversion to/from `CGEventFlags` device-bit checks, default = LeftCtrl+LeftOpt). Pure value type, no AppKit dependency.
- **`voxline/Audio/AudioDeviceEnumerator.swift`** — Lists CoreAudio input devices: `AudioDevice` struct (uid, name, isDefault) + `AudioDeviceEnumerator.inputDevices()` static method using `AudioObjectGetPropertyData` (`kAudioObjectSystemObject` → `kAudioHardwarePropertyDevices`). Returns `[]` on CoreAudio failure rather than throwing — Settings UI can fall back to "System default".
- **`voxline/Settings/GeneralSettingsViewModel.swift`** — `@Observable @MainActor`. Holds chord, audio input UID, and Whisper model state. `save()` persists to `AppSettings` and invokes an injected `apply: (GeneralSettingsApplier.Snapshot) -> Void` so the coordinator can re-bind services. Mirror APIKeysSettingsViewModel's shape (init reads, save persists).
- **`voxline/Settings/GeneralSettingsApplier.swift`** — Tiny protocol + `Snapshot` struct decoupling the VM from `AppCoordinator`. Lets us unit-test the VM with a fake applier.
- **`voxline/Settings/ChordRecorderView.swift`** — SwiftUI view that records a chord. `Press chord…` button → installs a *local* `NSEvent.addLocalMonitorForEvents(.flagsChanged)` while focused, captures two distinct modifier-down events, returns the resulting `HotkeyChord`. Cancel restores prior value. Local monitor (not CGEventTap) keeps recording to within the Settings window — no extra TCC prompt needed.
- **`voxline/Settings/ModesSettingsViewModel.swift`** — `@Observable @MainActor`. Loads via `ModeStore`, surfaces `[Mode]` for the table, exposes add/delete/update mutating methods, has `save()` that persists and notifies an injected `apply: ([Mode]) -> Void`.
- **`voxline/Settings/RunningAppsHelper.swift`** — Pure function returning `[(bundleID: String, displayName: String, icon: NSImage?)]` from `NSWorkspace.shared.runningApplications`. Filtered to apps with a non-nil `bundleIdentifier` and `activationPolicy == .regular`.
- **`voxline/Wizard/WizardStep.swift`** — Enum of steps + a "current → next/back" finite state machine. Pure logic, fully unit-testable.
- **`voxline/Wizard/WizardViewModel.swift`** — `@Observable @MainActor`. Owns `currentStep`, exposes `advance()` / `goBack()` / `complete()`, holds child VMs for the API-key step (`APIKeysSettingsViewModel`) and surfaces model-download progress from `AppState`.
- **`voxline/Wizard/WizardWelcomeView.swift`** — Step 1 view.
- **`voxline/Wizard/WizardPermissionsView.swift`** — Step 2 view. Polls `PermissionsService` every 1.5s. Each row: status badge + "Grant" button (deep-link to System Settings or trigger the request). "Continue" enables when mic + accessibility + input monitoring are all granted.
- **`voxline/Wizard/WizardAPIKeyView.swift`** — Step 3 view. Provider picker + secure-field + "Test connection" button that issues a tiny no-op `LLMRequest` and renders ✓/✗.
- **`voxline/Wizard/WizardModelDownloadView.swift`** — Step 4 view. Reuses `ModelDownloadView` styling but binds Continue to `state.status == .idle`.
- **`voxline/Wizard/WizardDoneView.swift`** — Step 5 view. "Hold Left Ctrl + Left Option to dictate. Done." (Hotkey label reads from `AppSettings.hotkeyChord` so it reflects any rebinding the user did mid-wizard, though that's an unusual flow.)
- **`voxline/Wizard/FirstRunWindowController.swift`** — `@MainActor` class that hosts `WizardRootView` in a centered, modal-style `NSWindow`. `show(state:settings:onComplete:)` and `close()`. Window cannot be closed without completing the wizard (close button hidden) — quitting the app via Cmd+Q still works.
- **`voxline/Wizard/WizardRootView.swift`** — Top-level switch on `WizardViewModel.currentStep` rendering the per-step view + a footer with Back/Continue buttons.
- **`voxlineTests/HotkeyChordTests.swift`**
- **`voxlineTests/AudioDeviceEnumeratorTests.swift`** — Smoke-only (CoreAudio is host-dependent).
- **`voxlineTests/GeneralSettingsViewModelTests.swift`**
- **`voxlineTests/ModesSettingsViewModelTests.swift`**
- **`voxlineTests/WizardStepTests.swift`**
- **`voxlineTests/WizardViewModelTests.swift`**

### Modified files

- **`voxline/Storage/AppSettings.swift`** — Add three keys: `hotkeyChord` (encoded as JSON `Data` blob in defaults), `audioInputDeviceUID` (optional `String`; nil = system default), `whisperModel` (`WhisperModel` rawValue), and `hasCompletedFirstRun` (`Bool`).
- **`voxline/Hotkey/HotkeyMonitor.swift`** — Read the configured chord from a passed-in `HotkeyChord` rather than hardcoding LeftCtrl+LeftOpt. Add `update(chord:)` method that swaps the chord at runtime without needing to rebuild the tap.
- **`voxline/Hotkey/HotkeyStateMachine.swift`** — Currently keys on `(leftCtrlDown, leftOptDown)`. Generalize the input to `flagsChanged(modA: Bool, modB: Bool)` (semantic; the chord identity lives in HotkeyMonitor's flag-bit check).
- **`voxline/Audio/AudioCaptureService.swift`** — Add `var preferredInputDeviceUID: String?` and apply it before `engine.start()` via `AVAudioSession`-equivalent on macOS: set `engine.inputNode`'s underlying `AUAudioUnit.deviceID` based on UID lookup. (CoreAudio `kAudioHardwarePropertyTranslateUIDToDevice`.)
- **`voxline/Pipeline/CapturePipeline.swift`** — No new logic, but ensure `transcriber.model` swaps trigger an idle prewarm. The model setter on `TranscriptionService` already invalidates and a subsequent `transcribe()` reloads — the change here is a coordinator-level call to `prewarm()` after a model switch so the user doesn't pay the load cost on first dictation post-switch.
- **`voxline/voxlineApp.swift`** (`AppCoordinator`) — Read first-run flag; if not set, show wizard and defer hotkey + model prep until completion. Wire General + Modes settings VMs' `apply` closures to coordinator methods that update HotkeyMonitor, AudioCaptureService, TranscriptionService, ModeRouter. Pass `state` and `coordinator` into both `SettingsView` and `WizardRootView` via SwiftUI environment.
- **`voxline/Settings/SettingsView.swift`** — Inject `AppCoordinator` via `.environment` so child VMs can resolve their applier closures. (Alternative: route through closures wired in `voxlineApp`. We use environment for VMs, plain init for closures — see Task 6.)
- **`voxline/Settings/GeneralSettingsView.swift`** — Replace stub with full UI.
- **`voxline/Settings/ModesSettingsView.swift`** — Replace stub with full UI.
- **`voxline/MenuBar/MenuBarContent.swift`** — Add the `Toggle voxline` menu item from spec §6.1 (now meaningful because we can pause/resume the hotkey listener).
- **`voxline/AppState.swift`** — Add `hotkeyEnabled: Bool = true`. Used by the menu toggle and by the wizard during the model-download step (we don't install the tap during the wizard).

---

## Build & Test Cadence

Each task ends with `swift test` (or the equivalent xcodebuild test invocation) and a commit. Run from the repo root.

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet
```

Expect every task's tests to pass before committing. The xcodebuild line is long; `~/.zshrc` aliases or a `Makefile` target are out of scope here.

---

## Tasks

### Task 1: HotkeyChord model + Codable round-trip

Introduces a value type for the chord so the rest of the app can stop hardcoding LeftCtrl+LeftOpt.

**Files:**
- Create: `voxline/Hotkey/HotkeyChord.swift`
- Create: `voxlineTests/HotkeyChordTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/HotkeyChordTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct HotkeyChordTests {

    @Test func default_is_left_ctrl_plus_left_option() {
        let c = HotkeyChord.default
        #expect(c.modifierA == .leftControl)
        #expect(c.modifierB == .leftOption)
    }

    @Test func display_name_lists_both_modifiers_in_order() {
        #expect(HotkeyChord.default.displayName == "Left Ctrl + Left Option")
        let c = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        #expect(c.displayName == "Left Cmd + Left Shift")
    }

    @Test func codable_round_trip() throws {
        let original = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HotkeyChord.self, from: data)
        #expect(decoded == original)
    }

    @Test func chord_matches_when_both_modifiers_down() {
        let c = HotkeyChord.default
        #expect(c.matches(modAFlag: true, modBFlag: true) == true)
        #expect(c.matches(modAFlag: true, modBFlag: false) == false)
        #expect(c.matches(modAFlag: false, modBFlag: false) == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests -quiet`
Expected: FAIL — `cannot find 'HotkeyChord' in scope`.

- [ ] **Step 3: Implement HotkeyChord**

```swift
// voxline/Hotkey/HotkeyChord.swift
import CoreGraphics
import Foundation
import IOKit.hidsystem

/// Codable value type for the hold-to-talk chord.
/// Pure data; flag-bit matching uses CGEventFlags via `Modifier.deviceMask`.
struct HotkeyChord: Codable, Equatable {

    enum Modifier: String, Codable, CaseIterable {
        case leftControl
        case leftOption
        case leftCommand
        case leftShift
        case rightControl
        case rightOption
        case rightCommand
        case rightShift

        /// CGEventFlags raw bit that distinguishes left vs right per-device modifiers.
        /// Sourced from <IOKit/hidsystem/IOLLEvent.h> NX_DEVICE*KEYMASK constants.
        var deviceMaskBit: UInt64 {
            switch self {
            case .leftControl:  return UInt64(NX_DEVICELCTLKEYMASK)
            case .leftOption:   return UInt64(NX_DEVICELALTKEYMASK)
            case .leftCommand:  return UInt64(NX_DEVICELCMDKEYMASK)
            case .leftShift:    return UInt64(NX_DEVICELSHIFTKEYMASK)
            case .rightControl: return UInt64(NX_DEVICERCTLKEYMASK)
            case .rightOption:  return UInt64(NX_DEVICERALTKEYMASK)
            case .rightCommand: return UInt64(NX_DEVICERCMDKEYMASK)
            case .rightShift:   return UInt64(NX_DEVICERSHIFTKEYMASK)
            }
        }

        var displayName: String {
            switch self {
            case .leftControl:  return "Left Ctrl"
            case .leftOption:   return "Left Option"
            case .leftCommand:  return "Left Cmd"
            case .leftShift:    return "Left Shift"
            case .rightControl: return "Right Ctrl"
            case .rightOption:  return "Right Option"
            case .rightCommand: return "Right Cmd"
            case .rightShift:   return "Right Shift"
            }
        }
    }

    let modifierA: Modifier
    let modifierB: Modifier

    static let `default` = HotkeyChord(modifierA: .leftControl, modifierB: .leftOption)

    var displayName: String { "\(modifierA.displayName) + \(modifierB.displayName)" }

    /// Returns true when both modifier device-bits are present in `flags.rawValue`.
    /// Caller derives the two booleans from the live CGEventFlags before calling.
    func matches(modAFlag: Bool, modBFlag: Bool) -> Bool { modAFlag && modBFlag }
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyChordTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Hotkey/HotkeyChord.swift voxlineTests/HotkeyChordTests.swift
git commit -m "Add HotkeyChord value type for rebindable chord"
```

---

### Task 2: AppSettings — chord, audio device, model, first-run flag

Threads the new persistence keys through `AppSettings` so the rest of the plan has a place to read/write user preferences.

**Files:**
- Modify: `voxline/Storage/AppSettings.swift`
- Modify: `voxlineTests/AppSettingsTests.swift`

- [ ] **Step 1: Write failing tests (append to existing AppSettingsTests)**

```swift
@Test func unset_hotkey_chord_returns_default() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    #expect(AppSettings(defaults: d).hotkeyChord == .default)
}

@Test func hotkey_chord_round_trips() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    var s = AppSettings(defaults: d)
    let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
    s.hotkeyChord = chord
    #expect(AppSettings(defaults: d).hotkeyChord == chord)
}

@Test func unset_audio_input_device_uid_is_nil() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    #expect(AppSettings(defaults: d).audioInputDeviceUID == nil)
}

@Test func audio_input_device_uid_round_trips() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    var s = AppSettings(defaults: d)
    s.audioInputDeviceUID = "BuiltInMicrophoneDevice"
    #expect(AppSettings(defaults: d).audioInputDeviceUID == "BuiltInMicrophoneDevice")
    s.audioInputDeviceUID = nil
    #expect(AppSettings(defaults: d).audioInputDeviceUID == nil)
}

@Test func unset_whisper_model_returns_default() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    #expect(AppSettings(defaults: d).whisperModel == .default)
}

@Test func whisper_model_round_trips() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    var s = AppSettings(defaults: d)
    s.whisperModel = .smallEn
    #expect(AppSettings(defaults: d).whisperModel == .smallEn)
}

@Test func first_run_flag_defaults_false_and_round_trips() {
    let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    #expect(AppSettings(defaults: d).hasCompletedFirstRun == false)
    var s = AppSettings(defaults: d)
    s.hasCompletedFirstRun = true
    #expect(AppSettings(defaults: d).hasCompletedFirstRun == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests -quiet`
Expected: FAIL — properties not defined.

- [ ] **Step 3: Add the new keys + properties to AppSettings**

```swift
// In AppSettings.swift, add to enum Key:
enum Key {
    static let provider = "voxline.llm.provider"
    static let model = "voxline.llm.model"
    static let hotkeyChord = "voxline.hotkey.chord"
    static let audioInputDeviceUID = "voxline.audio.inputDeviceUID"
    static let whisperModel = "voxline.whisper.model"
    static let hasCompletedFirstRun = "voxline.firstRun.completed"
}

// And add the new computed properties (after llmModel):
var hotkeyChord: HotkeyChord {
    get {
        guard
            let data = defaults.data(forKey: Key.hotkeyChord),
            let chord = try? JSONDecoder().decode(HotkeyChord.self, from: data)
        else { return .default }
        return chord
    }
    set {
        let data = try? JSONEncoder().encode(newValue)
        defaults.set(data, forKey: Key.hotkeyChord)
    }
}

var audioInputDeviceUID: String? {
    get { defaults.string(forKey: Key.audioInputDeviceUID) }
    set {
        if let newValue {
            defaults.set(newValue, forKey: Key.audioInputDeviceUID)
        } else {
            defaults.removeObject(forKey: Key.audioInputDeviceUID)
        }
    }
}

var whisperModel: WhisperModel {
    get {
        guard
            let raw = defaults.string(forKey: Key.whisperModel),
            let m = WhisperModel(rawValue: raw)
        else { return .default }
        return m
    }
    set { defaults.set(newValue.rawValue, forKey: Key.whisperModel) }
}

var hasCompletedFirstRun: Bool {
    get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
    set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
}
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests -quiet`
Expected: PASS for both old and new tests.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxlineTests/AppSettingsTests.swift
git commit -m "Add chord, audio device, model, first-run keys to AppSettings"
```

---

### Task 3: Generalize HotkeyStateMachine + HotkeyMonitor to a configurable chord

Replaces hardcoded LeftCtrl+LeftOpt with the `HotkeyChord` from settings. Keep behavior identical when the chord is `.default`.

**Files:**
- Modify: `voxline/Hotkey/HotkeyStateMachine.swift`
- Modify: `voxline/Hotkey/HotkeyMonitor.swift`
- Modify: `voxlineTests/HotkeyStateMachineTests.swift`

- [ ] **Step 1: Update HotkeyStateMachineTests for the renamed input**

In `HotkeyStateMachineTests.swift`, replace every occurrence of:

```swift
.flagsChanged(leftCtrlDown:
```

with:

```swift
.flagsChanged(modAFlag:
```

and `leftOptDown:` with `modBFlag:`. Behavior is unchanged — only naming.

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyStateMachineTests -quiet`
Expected: FAIL with "no such argument label" — confirms tests now exercise the renamed input.

- [ ] **Step 3: Rename the Input case in HotkeyStateMachine**

In `voxline/Hotkey/HotkeyStateMachine.swift`, change:

```swift
case flagsChanged(leftCtrlDown: Bool, leftOptDown: Bool)
```

to:

```swift
case flagsChanged(modAFlag: Bool, modBFlag: Bool)
```

And in the `handle(_:)` body, rename the destructured locals (`ctrl, opt` → `modA, modB`). The semantics ("both modifiers down → recording") are unchanged; only the labels are now chord-agnostic.

- [ ] **Step 4: Plumb HotkeyChord into HotkeyMonitor**

```swift
// In HotkeyMonitor.swift:

@MainActor
final class HotkeyMonitor {
    // ... existing properties ...

    /// Active chord. Read by the tap callback to test the right device-mask bits.
    /// Defaults to .default; AppCoordinator overrides from AppSettings on launch.
    var chord: HotkeyChord = .default

    // ... in the tap callback, replace the leftCtrl/leftOpt extraction:
    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .flagsChanged:
            let flags = event.flags
            let chord = monitor.chord
            let modA = flags.contains(CGEventFlags(rawValue: chord.modifierA.deviceMaskBit))
            let modB = flags.contains(CGEventFlags(rawValue: chord.modifierB.deviceMaskBit))
            // Coalesced bits kept for the debug log line, useful for diagnosing rollover.
            let anyCtrl = flags.contains(.maskControl)
            let anyOpt  = flags.contains(.maskAlternate)
            let raw = String(flags.rawValue, radix: 16)
            let line = "raw=0x\(raw) modA=\(modA) modB=\(modB) anyCtrl=\(anyCtrl) anyOpt=\(anyOpt)"
            Task { @MainActor in
                monitor.onDebugFlagEvent?(line)
                monitor.feed(.flagsChanged(modAFlag: modA, modBFlag: modB))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Task { @MainActor in
                monitor.feed(.tapDisabled)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    // Add a runtime updater (no need to rebuild the tap):
    func update(chord: HotkeyChord) {
        self.chord = chord
    }

    // And update reasonLabel(for:) to use the new label names:
    private func reasonLabel(for input: HotkeyStateMachine.Input) -> String {
        switch input {
        case .flagsChanged(let a, let b):
            return "chord-release (modA=\(a), modB=\(b))"
        case .maxDurationElapsed: return "max-duration"
        case .tapDisabled:        return "tap-disabled"
        case .recordingFinished:  return "recording-finished"
        }
    }
}
```

- [ ] **Step 5: Run all hotkey tests, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/HotkeyStateMachineTests -quiet`
Expected: PASS.

Then run the full test suite to catch any references to `leftCtrlDown:` from other tests:

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: PASS (or fail-loudly with a use-site that needs updating).

- [ ] **Step 6: Wire AppCoordinator to read the chord from settings**

In `voxlineApp.swift`'s `AppCoordinator.startIfNeeded(state:)`, immediately after `let monitor = HotkeyMonitor()`, set:

```swift
monitor.chord = AppSettings().hotkeyChord
```

- [ ] **Step 7: Commit**

```bash
git add voxline/Hotkey/HotkeyStateMachine.swift voxline/Hotkey/HotkeyMonitor.swift voxline/voxlineApp.swift voxlineTests/HotkeyStateMachineTests.swift
git commit -m "Make hotkey chord configurable via HotkeyChord"
```

---

### Task 4: AudioDeviceEnumerator (input devices)

Lists CoreAudio input devices for the General settings picker.

**Files:**
- Create: `voxline/Audio/AudioDeviceEnumerator.swift`
- Create: `voxlineTests/AudioDeviceEnumeratorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/AudioDeviceEnumeratorTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct AudioDeviceEnumeratorTests {

    /// Smoke test: on any host running the test (CI or laptop), CoreAudio
    /// returns at least the system default input device. Exact list varies.
    @Test func returns_at_least_one_input_device_on_a_real_host() {
        let devices = AudioDeviceEnumerator.inputDevices()
        #expect(!devices.isEmpty)
        #expect(devices.contains { !$0.uid.isEmpty && !$0.name.isEmpty })
    }

    @Test func exactly_one_default_device() {
        let devices = AudioDeviceEnumerator.inputDevices()
        let defaults = devices.filter(\.isDefault)
        #expect(defaults.count <= 1) // Zero is acceptable on a headless box without a default mic.
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AudioDeviceEnumeratorTests -quiet`
Expected: FAIL — `AudioDeviceEnumerator` undefined.

- [ ] **Step 3: Implement AudioDeviceEnumerator**

```swift
// voxline/Audio/AudioDeviceEnumerator.swift
import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    /// Stable UID across reboots. Stored in AppSettings.audioInputDeviceUID.
    let uid: String
    /// Human-readable name shown in the picker.
    let name: String
    /// True if this is the system's current default input device.
    let isDefault: Bool
}

enum AudioDeviceEnumerator {

    /// Returns the current list of input-capable CoreAudio devices.
    /// Returns [] on CoreAudio failure — callers should surface "System default" as a fallback.
    static func inputDevices() -> [AudioDevice] {
        let allIDs = systemDeviceIDs()
        let defaultID = defaultInputDeviceID()
        var result: [AudioDevice] = []
        for id in allIDs where hasInputStreams(id) {
            guard
                let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal),
                let name = stringProperty(id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
            else { continue }
            result.append(AudioDevice(uid: uid, name: name, isDefault: id == defaultID))
        }
        return result
    }

    // MARK: - CoreAudio plumbing

    private static func systemDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cfString as String? else { return nil }
        return s
    }

    /// Look up the AudioDeviceID for a UID stored in AppSettings.
    /// Returns nil if the device is no longer present (e.g., USB mic unplugged).
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var translation = AudioValueTranslation(
            mInputData: UnsafeMutableRawPointer(mutating: (uid as NSString).utf8String),
            mInputDataSize: UInt32(uid.utf8.count + 1),
            mOutputData: &deviceID,
            mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &translation
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AudioDeviceEnumeratorTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Audio/AudioDeviceEnumerator.swift voxlineTests/AudioDeviceEnumeratorTests.swift
git commit -m "Add AudioDeviceEnumerator for input device picker"
```

---

### Task 5: AudioCaptureService honors a preferred input device UID

Lets the user pick a non-default mic in Settings. Falls back to the system default when the configured device is unplugged.

**Files:**
- Modify: `voxline/Audio/AudioCaptureService.swift`

- [ ] **Step 1: Add the property and apply it before engine.start()**

In `AudioCaptureService`, add:

```swift
/// Optional CoreAudio UID for the preferred input device. nil = system default.
/// AppCoordinator applies this from AppSettings before each capture.
var preferredInputDeviceUID: String?
```

In `start()`, just before reading `inputFormat(forBus: 0)`, add:

```swift
// Apply the preferred device, if set and currently present.
if let uid = preferredInputDeviceUID, let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid) {
    var mutableID = deviceID
    let status = AudioUnitSetProperty(
        engine.inputNode.audioUnit!,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &mutableID,
        UInt32(MemoryLayout<AudioDeviceID>.size)
    )
    if status != noErr {
        // Fall through to default device. Don't throw — a mic that was
        // present at Settings-save time may have been unplugged since.
    }
}
```

Add `import CoreAudio` and `import AudioToolbox` at the top.

- [ ] **Step 2: Build to make sure no test regression**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: PASS — existing AudioCapture tests don't exercise the preferred-device path; this is unit-tested manually in Plan 5 smoke.

- [ ] **Step 3: Commit**

```bash
git add voxline/Audio/AudioCaptureService.swift
git commit -m "Plumb preferred input device UID through AudioCaptureService"
```

---

### Task 6: GeneralSettingsApplier protocol + GeneralSettingsViewModel

Decouples the VM from `AppCoordinator` so it's unit-testable.

**Files:**
- Create: `voxline/Settings/GeneralSettingsApplier.swift`
- Create: `voxline/Settings/GeneralSettingsViewModel.swift`
- Create: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/GeneralSettingsViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct GeneralSettingsViewModelTests {

    private func defaults() -> UserDefaults {
        let n = "voxline-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: n)!
    }

    @Test func loads_current_values_on_init() {
        var settings = AppSettings(defaults: defaults())
        let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        settings.hotkeyChord = chord
        settings.audioInputDeviceUID = "MyMic"
        settings.whisperModel = .smallEn

        let vm = GeneralSettingsViewModel(settings: settings, applier: NoopApplier())
        #expect(vm.chord == chord)
        #expect(vm.audioInputDeviceUID == "MyMic")
        #expect(vm.whisperModel == .smallEn)
    }

    @Test func save_persists_and_calls_applier() throws {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let applier = RecordingApplier()
        let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        vm.chord = chord
        vm.audioInputDeviceUID = "NewMic"
        vm.whisperModel = .smallEn
        try vm.save()

        let reread = AppSettings(defaults: d)
        #expect(reread.hotkeyChord == chord)
        #expect(reread.audioInputDeviceUID == "NewMic")
        #expect(reread.whisperModel == .smallEn)

        #expect(applier.applied?.chord == chord)
        #expect(applier.applied?.audioInputDeviceUID == "NewMic")
        #expect(applier.applied?.whisperModel == .smallEn)
    }
}

private struct NoopApplier: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}

@MainActor
private final class RecordingApplier: GeneralSettingsApplier {
    var applied: GeneralSettingsSnapshot?
    func apply(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/GeneralSettingsViewModelTests -quiet`
Expected: FAIL — types don't exist.

- [ ] **Step 3: Implement applier protocol**

```swift
// voxline/Settings/GeneralSettingsApplier.swift
import Foundation

/// Snapshot the General settings VM hands to the coordinator on save.
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let audioInputDeviceUID: String?
    let whisperModel: WhisperModel
}

/// Coordinator hook: receive a saved snapshot and apply it to running services.
@MainActor
protocol GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot)
}
```

- [ ] **Step 4: Implement the view model**

```swift
// voxline/Settings/GeneralSettingsViewModel.swift
import Foundation
import Observation

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord
    var audioInputDeviceUID: String?
    var whisperModel: WhisperModel
    var lastError: String?

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier

    init(settings: AppSettings = AppSettings(), applier: GeneralSettingsApplier) {
        self.settings = settings
        self.applier = applier
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
    }

    func save() throws {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel
        ))
    }
}
```

- [ ] **Step 5: Run test, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/GeneralSettingsViewModelTests -quiet`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/GeneralSettingsApplier.swift voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "Add GeneralSettingsViewModel + applier protocol"
```

---

### Task 7: ChordRecorderView (record-a-chord UI)

Compact SwiftUI control: shows current chord, "Press chord…" button activates a local NSEvent monitor, captures the next two-modifier combo. Cancel button restores the prior value.

**Files:**
- Create: `voxline/Settings/ChordRecorderView.swift`

- [ ] **Step 1: Implement the view**

```swift
// voxline/Settings/ChordRecorderView.swift
import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

struct ChordRecorderView: View {

    @Binding var chord: HotkeyChord

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var firstModifier: HotkeyChord.Modifier?

    var body: some View {
        HStack(spacing: 12) {
            Text(chord.displayName)
                .monospaced()
                .frame(minWidth: 200, alignment: .leading)
            if isRecording {
                Text(firstModifier == nil ? "Press first modifier…" : "Now press second modifier…")
                    .foregroundStyle(.secondary)
                Button("Cancel") { stop() }
            } else {
                Button("Record chord…") { start() }
            }
        }
    }

    private func start() {
        firstModifier = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        firstModifier = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        guard let pressed = modifier(from: event), event.type == .flagsChanged else { return }
        // Edge: only react on key-DOWN (modifier mask non-zero for that bit)
        let bit = pressed.deviceMaskBit
        let raw = UInt64(event.cgEvent?.flags.rawValue ?? 0)
        let isDown = (raw & bit) != 0
        guard isDown else { return }

        if let first = firstModifier {
            guard pressed != first else { return }
            chord = HotkeyChord(modifierA: first, modifierB: pressed)
            stop()
        } else {
            firstModifier = pressed
        }
    }

    private func modifier(from event: NSEvent) -> HotkeyChord.Modifier? {
        // event.keyCode for flagsChanged identifies which physical modifier key.
        // Carbon kVK_* constants:
        switch Int(event.keyCode) {
        case kVK_Control:     return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Option:      return .leftOption
        case kVK_RightOption: return .rightOption
        case kVK_Command:     return .leftCommand
        case kVK_RightCommand: return .rightCommand
        case kVK_Shift:       return .leftShift
        case kVK_RightShift:  return .rightShift
        default: return nil
        }
    }
}
```

- [ ] **Step 2: Build (no test — UI is exercised manually)**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add voxline/Settings/ChordRecorderView.swift
git commit -m "Add ChordRecorderView for hotkey rebinding"
```

---

### Task 8: GeneralSettingsView (full UI) + AppCoordinator wiring

Replaces the stub. Provides the chord recorder, input device picker, and Whisper model picker. Wires the VM's applier closure to AppCoordinator methods that re-bind the live services.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsView.swift`
- Modify: `voxline/Settings/SettingsView.swift`
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Replace GeneralSettingsView with the real UI**

```swift
// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel
    @State private var devices: [AudioDevice] = []

    init(vm: GeneralSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                ChordRecorderView(chord: $vm.chord)
            }

            Section("Microphone") {
                Picker("Input device", selection: $vm.audioInputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices, id: \.uid) { device in
                        Text(displayLabel(for: device)).tag(String?.some(device.uid))
                    }
                }
            }

            Section("Speech recognition model") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model on next launch (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }

            if let err = vm.lastError {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
        .onAppear { devices = AudioDeviceEnumerator.inputDevices() }
    }

    private func displayLabel(for device: AudioDevice) -> String {
        device.isDefault ? "\(device.name) (default)" : device.name
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 2: Update SettingsView to inject the VM**

```swift
// voxline/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    let generalVM: GeneralSettingsViewModel
    let modesVM: ModesSettingsViewModel
    // (modesVM is wired in Task 11; for now a placeholder is fine — see Task 11.)

    var body: some View {
        TabView {
            GeneralSettingsView(vm: generalVM)
                .tabItem { Label("General", systemImage: "gear") }

            APIKeysSettingsView()
                .tabItem { Label("API Keys", systemImage: "key") }

            ModesSettingsView(vm: modesVM)
                .tabItem { Label("Modes", systemImage: "rectangle.3.group") }
        }
    }
}
```

(Note: ModesSettingsView's `init(vm:)` lands in Task 12. Until then, `SettingsView` won't compile. Either implement Tasks 9-12 immediately after this one, or temporarily revert ModesSettingsView's init to a parameterless version. Recommended: do Tasks 9-12 next without committing/merging this task in isolation.)

- [ ] **Step 3: Implement AppCoordinator's GeneralSettingsApplier**

In `voxlineApp.swift`, extend `AppCoordinator` to conform to `GeneralSettingsApplier`:

```swift
extension AppCoordinator: GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot) {
        hotkeyMonitor?.update(chord: snapshot.chord)
        // AudioCaptureService reads preferredInputDeviceUID at next start();
        // capture pipeline restarts on every chord, so the new device kicks
        // in on the next dictation.
        pipeline?.capture.preferredInputDeviceUID = snapshot.audioInputDeviceUID
        // Switching Whisper model: invalidate the loaded pipeline; the next
        // transcribe re-loads from the (possibly cached) new variant. Trigger
        // a background prepare/prewarm so the user doesn't pay it on next dictation.
        if transcriber?.model != snapshot.whisperModel {
            transcriber?.model = snapshot.whisperModel
            Task { @MainActor [weak self] in
                guard let self, let t = self.transcriber else { return }
                if !TranscriptionService.isModelCached(snapshot.whisperModel) {
                    try? await t.prepareModel { _ in }
                }
                try? await t.prewarm()
            }
        }
    }
}
```

To make `pipeline?.capture` reachable, expose `capture` on `CapturePipeline`:

```swift
// In CapturePipeline.swift, add:
var capture: AudioCaptureService { _capture }
// And rename the existing private field to _capture, or just make it `let capture: AudioCaptureService`
// if it isn't already exposed. (Audit the existing source — it may already be accessible.)
```

- [ ] **Step 4: Wire SettingsView in voxlineApp.swift**

```swift
// In voxlineApp.swift's body:

Settings {
    SettingsView(
        generalVM: GeneralSettingsViewModel(applier: delegate.coordinator),
        modesVM: ModesSettingsViewModel(applier: delegate.coordinator) // implemented in Task 11
    )
    .environment(delegate.appState)
}
```

- [ ] **Step 5: Build and run tests**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: Compilation will fail until Task 11's ModesSettingsViewModel exists. Proceed to Task 9 without committing this task in isolation.

- [ ] **Step 6: Commit (after Task 12 lands and the project compiles)**

```bash
git add voxline/Settings/GeneralSettingsView.swift voxline/Settings/SettingsView.swift voxline/voxlineApp.swift voxline/Pipeline/CapturePipeline.swift
git commit -m "Wire General settings UI + apply path"
```

---

### Task 9: ModeStore.save support, Mode mutation helpers

`Mode` is currently a `let`-only struct. The Modes editor needs in-memory edits + a way to save, so the VM needs mutable copies. Make the fields `var` (Codable still works) and add a Mode initializer that the "Add new" button uses.

**Files:**
- Modify: `voxline/Modes/Mode.swift`

- [ ] **Step 1: Make Mode fields mutable**

```swift
// voxline/Modes/Mode.swift
import Foundation

struct Mode: Codable, Equatable, Identifiable {
    static let wildcardBundleID = "*"

    /// Stable ID for SwiftUI ForEach. Bundle ID is stable enough as long as
    /// the user doesn't have two modes with the same bundle ID — the editor
    /// enforces uniqueness on save.
    var id: String { bundleID }

    var bundleID: String
    var displayName: String
    var prompt: String
    var model: String?
    var temperature: Double?

    /// Convenience initializer for "Add new mode" with sensible defaults.
    static func newDraft(bundleID: String = "", displayName: String = "") -> Mode {
        Mode(
            bundleID: bundleID,
            displayName: displayName,
            prompt: "Strip fillers. Punctuate. Preserve the speaker's voice.",
            model: nil,
            temperature: nil
        )
    }
}
```

- [ ] **Step 2: Update ModeTests / ModeStoreTests for any breakage**

Existing tests likely build a `Mode` via positional init. That still works (Swift's memberwise init is generated). Run:

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ModeTests -only-testing:voxlineTests/ModeStoreTests -quiet`
Expected: PASS without changes.

- [ ] **Step 3: Commit**

```bash
git add voxline/Modes/Mode.swift
git commit -m "Make Mode mutable + Identifiable for editor"
```

---

### Task 10: ModesSettingsViewModel + tests

CRUD-style VM with persistence and an applier hook so saves take effect live.

**Files:**
- Create: `voxline/Settings/ModesSettingsViewModel.swift`
- Create: `voxlineTests/ModesSettingsViewModelTests.swift`

- [ ] **Step 1: Define the applier protocol (inline) and write the failing test**

```swift
// voxlineTests/ModesSettingsViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct ModesSettingsViewModelTests {

    private func tempStore() throws -> ModeStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voxline-modes-\(UUID().uuidString).json")
        return ModeStore(fileURL: url)
    }

    @Test func loads_modes_from_store_on_init() throws {
        let store = try tempStore()
        try store.save([
            Mode(bundleID: "com.foo", displayName: "Foo", prompt: "p", model: nil, temperature: nil),
            Mode(bundleID: "*", displayName: "Default", prompt: "d", model: nil, temperature: nil)
        ])

        let vm = ModesSettingsViewModel(store: store, applier: NoopApplier())
        #expect(vm.modes.count == 2)
        #expect(vm.modes.first?.bundleID == "com.foo")
    }

    @Test func add_appends_a_draft_mode() throws {
        let vm = ModesSettingsViewModel(store: try tempStore(), applier: NoopApplier())
        let before = vm.modes.count
        vm.addNewDraft()
        #expect(vm.modes.count == before + 1)
        #expect(vm.modes.last?.bundleID == "")
    }

    @Test func delete_removes_at_index() throws {
        let store = try tempStore()
        try store.save([
            Mode(bundleID: "com.a", displayName: "A", prompt: "x", model: nil, temperature: nil),
            Mode(bundleID: "com.b", displayName: "B", prompt: "y", model: nil, temperature: nil)
        ])
        let vm = ModesSettingsViewModel(store: store, applier: NoopApplier())
        vm.delete(at: IndexSet(integer: 0))
        #expect(vm.modes.count == 1)
        #expect(vm.modes.first?.bundleID == "com.b")
    }

    @Test func save_persists_and_calls_applier() throws {
        let store = try tempStore()
        let applier = RecordingModesApplier()
        let vm = ModesSettingsViewModel(store: store, applier: applier)

        vm.modes = [
            Mode(bundleID: "com.zap", displayName: "Zap", prompt: "p", model: nil, temperature: nil)
        ]
        try vm.save()

        let reread = try store.load()
        #expect(reread.first?.bundleID == "com.zap")
        #expect(applier.applied?.first?.bundleID == "com.zap")
    }

    @Test func save_rejects_duplicate_bundle_ids() throws {
        let vm = ModesSettingsViewModel(store: try tempStore(), applier: NoopApplier())
        vm.modes = [
            Mode(bundleID: "com.dup", displayName: "A", prompt: "p", model: nil, temperature: nil),
            Mode(bundleID: "com.dup", displayName: "B", prompt: "q", model: nil, temperature: nil)
        ]
        #expect(throws: ModesSettingsError.duplicateBundleID(let id) where id == "com.dup") {
            try vm.save()
        }
    }
}

private struct NoopApplier: ModesApplier {
    func apply(modes: [Mode]) {}
}

@MainActor
private final class RecordingModesApplier: ModesApplier {
    var applied: [Mode]?
    func apply(modes: [Mode]) { applied = modes }
}
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ModesSettingsViewModelTests -quiet`
Expected: FAIL — types undefined.

- [ ] **Step 3: Implement the VM**

```swift
// voxline/Settings/ModesSettingsViewModel.swift
import Foundation
import Observation

@MainActor
protocol ModesApplier {
    func apply(modes: [Mode])
}

enum ModesSettingsError: Error, Equatable {
    case duplicateBundleID(String)
}

@Observable
@MainActor
final class ModesSettingsViewModel {

    var modes: [Mode] = []
    var lastError: String?

    private let store: ModeStore
    private let applier: ModesApplier

    init(store: ModeStore, applier: ModesApplier) {
        self.store = store
        self.applier = applier
        self.modes = (try? store.load()) ?? ModeStore.shippedDefaults
    }

    /// Convenience for the production code path: uses the canonical app-support file.
    convenience init(applier: ModesApplier) {
        let store = (try? ModeStore()) ?? ModeStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        self.init(store: store, applier: applier)
    }

    func addNewDraft() {
        modes.append(.newDraft())
    }

    func delete(at indexSet: IndexSet) {
        modes.remove(atOffsets: indexSet)
    }

    func addOrUpdate(_ mode: Mode) {
        if let i = modes.firstIndex(where: { $0.bundleID == mode.bundleID }) {
            modes[i] = mode
        } else {
            modes.append(mode)
        }
    }

    func save() throws {
        let ids = modes.map(\.bundleID)
        if let dup = firstDuplicate(in: ids) {
            throw ModesSettingsError.duplicateBundleID(dup)
        }
        try store.save(modes)
        applier.apply(modes: modes)
    }

    private func firstDuplicate(in ids: [String]) -> String? {
        var seen = Set<String>()
        for id in ids where !seen.insert(id).inserted { return id }
        return nil
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/ModesSettingsViewModelTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Settings/ModesSettingsViewModel.swift voxlineTests/ModesSettingsViewModelTests.swift
git commit -m "Add ModesSettingsViewModel with CRUD + duplicate guard"
```

---

### Task 11: RunningAppsHelper + AppCoordinator's ModesApplier

**Files:**
- Create: `voxline/Settings/RunningAppsHelper.swift`
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Implement helper**

```swift
// voxline/Settings/RunningAppsHelper.swift
import AppKit

struct RunningAppEntry: Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    let displayName: String

    static func == (lhs: RunningAppEntry, rhs: RunningAppEntry) -> Bool {
        lhs.bundleID == rhs.bundleID && lhs.displayName == rhs.displayName
    }
}

enum RunningAppsHelper {
    /// Snapshot of currently running, regular-activation apps with a bundle ID.
    /// Sorted by display name, case-insensitive. Excludes voxline itself.
    static func snapshot() -> [RunningAppEntry] {
        let me = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppEntry? in
                guard let bundleID = app.bundleIdentifier, bundleID != me else { return nil }
                let name = app.localizedName ?? bundleID
                return RunningAppEntry(bundleID: bundleID, displayName: name)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
```

- [ ] **Step 2: Implement ModesApplier on AppCoordinator**

In `voxlineApp.swift`:

```swift
extension AppCoordinator: ModesApplier {
    func apply(modes: [Mode]) {
        // ModeRouter is a value type stored on the coordinator; rebuild it.
        self.modes = ModeRouter(modes: modes)
        // CapturePipeline holds its own reference to ModeRouter; update it too.
        pipeline?.modes = self.modes
    }
}
```

For this to compile, `CapturePipeline.modes` needs to be a `var` (audit existing source). If it's currently `let`, change to `var`.

- [ ] **Step 3: Build (no new tests beyond Task 10's)**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED (assuming Task 10 is in place).

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/RunningAppsHelper.swift voxline/voxlineApp.swift voxline/Pipeline/CapturePipeline.swift
git commit -m "Add RunningAppsHelper + apply modes live"
```

---

### Task 12: ModesSettingsView (full UI) + reachable via SettingsView

**Files:**
- Modify: `voxline/Settings/ModesSettingsView.swift`

- [ ] **Step 1: Replace the stub**

```swift
// voxline/Settings/ModesSettingsView.swift
import SwiftUI

struct ModesSettingsView: View {

    @State private var vm: ModesSettingsViewModel
    @State private var selection: Mode.ID?
    @State private var showingRunningApps = false

    init(vm: ModesSettingsViewModel) {
        _vm = State(wrappedValue: vm)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                modesList
                    .frame(minWidth: 200)
                if let mode = bindingForSelection() {
                    ModeEditor(mode: mode)
                        .frame(minWidth: 320)
                        .padding()
                } else {
                    Text("Select a mode to edit")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 320)
                }
            }
            Divider()
            HStack {
                Button { vm.addNewDraft() } label: { Image(systemName: "plus") }
                Button { showingRunningApps = true } label: { Label("Add from running apps", systemImage: "rectangle.stack") }
                Button {
                    if let selection, let i = vm.modes.firstIndex(where: { $0.id == selection }) {
                        vm.delete(at: IndexSet(integer: i))
                    }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
                Button("Save") { saveWithErrorBanner() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(8)
            if let err = vm.lastError {
                Text(err).foregroundStyle(.red).font(.callout).padding(.horizontal)
            }
        }
        .frame(width: 720, height: 480)
        .sheet(isPresented: $showingRunningApps) {
            RunningAppsPickerView { entry in
                vm.addOrUpdate(.newDraft(bundleID: entry.bundleID, displayName: entry.displayName))
                showingRunningApps = false
            } cancel: {
                showingRunningApps = false
            }
        }
    }

    private var modesList: some View {
        List(selection: $selection) {
            ForEach(vm.modes) { mode in
                VStack(alignment: .leading) {
                    Text(mode.displayName.isEmpty ? "(unnamed)" : mode.displayName)
                    Text(mode.bundleID).font(.caption).foregroundStyle(.secondary)
                }
                .tag(mode.id)
            }
        }
    }

    private func bindingForSelection() -> Binding<Mode>? {
        guard
            let selection,
            let i = vm.modes.firstIndex(where: { $0.id == selection })
        else { return nil }
        return Binding(
            get: { vm.modes[i] },
            set: { vm.modes[i] = $0 }
        )
    }

    private func saveWithErrorBanner() {
        do {
            try vm.save()
            vm.lastError = nil
        } catch {
            vm.lastError = "Save failed: \(error.localizedDescription)"
        }
    }
}

private struct ModeEditor: View {
    @Binding var mode: Mode
    var body: some View {
        Form {
            TextField("Display name", text: $mode.displayName)
            TextField("Bundle ID (or *)", text: $mode.bundleID).monospaced()
            Section("Prompt") {
                TextEditor(text: $mode.prompt).frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RunningAppsPickerView: View {
    let onPick: (RunningAppEntry) -> Void
    let cancel: () -> Void

    @State private var apps: [RunningAppEntry] = []

    var body: some View {
        VStack {
            Text("Pick a running app").font(.headline).padding(.top)
            List(apps) { app in
                Button {
                    onPick(app)
                } label: {
                    VStack(alignment: .leading) {
                        Text(app.displayName)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 420, height: 360)
        .onAppear { apps = RunningAppsHelper.snapshot() }
    }
}
```

- [ ] **Step 2: Build to validate**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED. The full project should now compile end-to-end (Task 8's Settings wiring is satisfied).

- [ ] **Step 3: Run all tests**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: PASS.

- [ ] **Step 4: Commit (this batch closes Tasks 8 + 12 simultaneously)**

```bash
git add voxline/Settings/ModesSettingsView.swift
git commit -m "Implement full Modes settings UI"
```

---

### Task 13: Add "Toggle voxline" menu item

The menu currently lists only Settings/Debug/Quit (per spec §6.1's Plan-1 deferral note). The hotkey listener is now toggleable via `AppState.hotkeyEnabled`.

**Files:**
- Modify: `voxline/AppState.swift`
- Modify: `voxline/MenuBar/MenuBarContent.swift`
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Add hotkeyEnabled to AppState**

```swift
// In AppState, add (with the other UI state at the top):
var hotkeyEnabled: Bool = true
```

- [ ] **Step 2: Add menu item**

```swift
// In MenuBarContent.swift, before the Settings… button:
Button(state.hotkeyEnabled ? "Pause voxline" : "Resume voxline") {
    state.hotkeyEnabled.toggle()
}
Divider()
```

- [ ] **Step 3: Wire AppCoordinator to react**

In `AppCoordinator.startIfNeeded`, add an Observation withObservationTracking pattern (or just a Task that polls — simpler given the frequency is "user click rate"):

```swift
// At the end of startIfNeeded (after monitor.start()):
observeHotkeyEnabled(state: state)

// New method:
private func observeHotkeyEnabled(state: AppState) {
    // Poll once per second — toggling is rare and a notifier would
    // require a rewrite of AppState into Combine.
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak state] _ in
        Task { @MainActor in
            guard let self, let state else { return }
            let enabled = state.hotkeyEnabled
            let installed = self.hotkeyMonitor?.isTapInstalled ?? false
            if enabled && !installed {
                try? self.hotkeyMonitor?.start()
            } else if !enabled && installed {
                self.hotkeyMonitor?.stop()
            }
        }
    }
}
```

- [ ] **Step 4: Build + run tests**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/AppState.swift voxline/MenuBar/MenuBarContent.swift voxline/voxlineApp.swift
git commit -m "Add Pause/Resume voxline menu item"
```

---

### Task 14: WizardStep finite state machine + tests

Pure-logic step navigation. Lets us test the wizard's flow without touching SwiftUI.

**Files:**
- Create: `voxline/Wizard/WizardStep.swift`
- Create: `voxlineTests/WizardStepTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/WizardStepTests.swift
import Testing
@testable import voxline

@Suite struct WizardStepTests {

    @Test func first_step_is_welcome() {
        #expect(WizardStep.first == .welcome)
    }

    @Test func steps_advance_in_order() {
        #expect(WizardStep.welcome.next == .permissions)
        #expect(WizardStep.permissions.next == .apiKey)
        #expect(WizardStep.apiKey.next == .modelDownload)
        #expect(WizardStep.modelDownload.next == .done)
        #expect(WizardStep.done.next == nil)
    }

    @Test func steps_go_back_in_order() {
        #expect(WizardStep.welcome.previous == nil)
        #expect(WizardStep.permissions.previous == .welcome)
        #expect(WizardStep.apiKey.previous == .permissions)
        #expect(WizardStep.modelDownload.previous == .apiKey)
        #expect(WizardStep.done.previous == .modelDownload)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WizardStepTests -quiet`
Expected: FAIL.

- [ ] **Step 3: Implement WizardStep**

```swift
// voxline/Wizard/WizardStep.swift
enum WizardStep: CaseIterable {
    case welcome
    case permissions
    case apiKey
    case modelDownload
    case done

    static let first: WizardStep = .welcome

    var next: WizardStep? {
        let all = WizardStep.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    var previous: WizardStep? {
        let all = WizardStep.allCases
        guard let i = all.firstIndex(of: self), i > 0 else { return nil }
        return all[i - 1]
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WizardStepTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Wizard/WizardStep.swift voxlineTests/WizardStepTests.swift
git commit -m "Add WizardStep state machine"
```

---

### Task 15: WizardViewModel + tests

Drives navigation, owns the API-key step's child VM, exposes a `complete()` that flips the `hasCompletedFirstRun` flag.

**Files:**
- Create: `voxline/Wizard/WizardViewModel.swift`
- Create: `voxlineTests/WizardViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/WizardViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct WizardViewModelTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    }

    @Test func starts_at_welcome() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        #expect(vm.currentStep == .welcome)
    }

    @Test func advance_walks_through_steps() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        vm.advance()
        #expect(vm.currentStep == .permissions)
        vm.advance()
        #expect(vm.currentStep == .apiKey)
        vm.advance()
        #expect(vm.currentStep == .modelDownload)
        vm.advance()
        #expect(vm.currentStep == .done)
    }

    @Test func go_back_steps_backwards() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        vm.advance(); vm.advance()
        #expect(vm.currentStep == .apiKey)
        vm.goBack()
        #expect(vm.currentStep == .permissions)
    }

    @Test func complete_sets_first_run_flag_and_calls_callback() {
        let d = defaults()
        let vm = WizardViewModel(settings: AppSettings(defaults: d))
        var didCallback = false
        vm.onComplete = { didCallback = true }

        // Walk to done and complete
        vm.advance(); vm.advance(); vm.advance(); vm.advance()
        vm.complete()

        #expect(didCallback == true)
        #expect(AppSettings(defaults: d).hasCompletedFirstRun == true)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WizardViewModelTests -quiet`
Expected: FAIL.

- [ ] **Step 3: Implement WizardViewModel**

```swift
// voxline/Wizard/WizardViewModel.swift
import Foundation
import Observation

@Observable
@MainActor
final class WizardViewModel {

    var currentStep: WizardStep = .first
    var onComplete: (() -> Void)?

    /// The API-key step reuses APIKeysSettingsViewModel directly.
    let apiKeyVM: APIKeysSettingsViewModel

    private var settings: AppSettings

    init(
        settings: AppSettings = AppSettings(),
        keychain: Keychain = Keychain()
    ) {
        self.settings = settings
        self.apiKeyVM = APIKeysSettingsViewModel(settings: settings, keychain: keychain)
    }

    var canAdvance: Bool { currentStep.next != nil }
    var canGoBack: Bool { currentStep.previous != nil }

    func advance() {
        if let next = currentStep.next { currentStep = next }
    }

    func goBack() {
        if let prev = currentStep.previous { currentStep = prev }
    }

    func complete() {
        var s = settings
        s.hasCompletedFirstRun = true
        settings = s
        onComplete?()
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WizardViewModelTests -quiet`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Wizard/WizardViewModel.swift voxlineTests/WizardViewModelTests.swift
git commit -m "Add WizardViewModel"
```

---

### Task 16: Wizard step views (Welcome, Permissions, APIKey, ModelDownload, Done)

All five SwiftUI views in one task. They're small and read-only over the VM.

**Files:**
- Create: `voxline/Wizard/WizardWelcomeView.swift`
- Create: `voxline/Wizard/WizardPermissionsView.swift`
- Create: `voxline/Wizard/WizardAPIKeyView.swift`
- Create: `voxline/Wizard/WizardModelDownloadView.swift`
- Create: `voxline/Wizard/WizardDoneView.swift`

- [ ] **Step 1: Write WizardWelcomeView**

```swift
// voxline/Wizard/WizardWelcomeView.swift
import SwiftUI

struct WizardWelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to voxline").font(.largeTitle.bold())
            Text("Hold a chord to dictate. Speak. Release. voxline transcribes locally and pastes cleaned text into the focused field.")
                .foregroundStyle(.secondary)
            Text("Setup takes about a minute. We'll grant a few macOS permissions, set an LLM provider, and download the speech recognition model.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Write WizardPermissionsView**

```swift
// voxline/Wizard/WizardPermissionsView.swift
import AppKit
import SwiftUI

struct WizardPermissionsView: View {
    @State private var perms = PermissionsService()
    @State private var mic: PermissionStatus = .notDetermined
    @State private var ax: PermissionStatus = .notDetermined
    @State private var im: PermissionStatus = .notDetermined
    @State private var pollTimer: Timer?

    var allGranted: Bool { mic == .granted && ax == .granted && im == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant permissions").font(.title.bold())
            Text("voxline needs three macOS permissions. Grant each, then continue.")
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Microphone",
                detail: "To capture your voice for transcription.",
                status: mic,
                grantLabel: "Grant",
                action: { Task { mic = await perms.requestMicrophone() } }
            )

            permissionRow(
                title: "Accessibility",
                detail: "To listen for the hold-to-talk chord and paste cleaned text.",
                status: ax,
                grantLabel: "Open System Settings",
                action: openAccessibilitySettings
            )

            permissionRow(
                title: "Input Monitoring",
                detail: "Required for the chord to work outside voxline itself.",
                status: im,
                grantLabel: "Grant",
                action: { im = perms.requestInputMonitoring() }
            )
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionStatus,
        grantLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol(status))
                .foregroundStyle(statusColor(status))
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(grantLabel, action: action)
                .disabled(status == .granted)
        }
    }

    private func statusSymbol(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "circle"
        }
    }

    private func statusColor(_ s: PermissionStatus) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }

    private func openAccessibilitySettings() {
        perms.promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        mic = perms.microphoneStatus
        ax = perms.accessibilityStatus
        im = perms.inputMonitoringStatus
    }
}
```

- [ ] **Step 3: Write WizardAPIKeyView**

```swift
// voxline/Wizard/WizardAPIKeyView.swift
import SwiftUI

struct WizardAPIKeyView: View {
    @Bindable var vm: APIKeysSettingsViewModel
    @State private var testResult: TestResult = .untested
    @State private var testing = false

    enum TestResult: Equatable { case untested, success, failed(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a provider").font(.title.bold())
            Text("voxline uses your own API key for the LLM cleanup step. Pick a provider and paste a key.")
                .foregroundStyle(.secondary)

            Picker("Provider", selection: $vm.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if vm.provider == .anthropic {
                SecureField("Anthropic API key", text: $vm.anthropicKey).textContentType(.password)
            } else {
                SecureField("OpenAI API key", text: $vm.openaiKey).textContentType(.password)
            }

            HStack {
                Button("Test connection") { Task { await runTest() } }
                    .disabled(testing || activeKey.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                resultView
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activeKey: String {
        vm.provider == .anthropic ? vm.anthropicKey : vm.openaiKey
    }

    @ViewBuilder
    private var resultView: some View {
        switch testResult {
        case .untested: EmptyView()
        case .success: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        }
    }

    private func runTest() async {
        testing = true
        defer { testing = false }
        do {
            try vm.save() // persists key first so LLMService can read it
            let llm = LLMService(settings: AppSettings(), keychain: Keychain())
            let request = LLMRequest(
                model: vm.provider.defaultModel,
                systemPrompt: "Return the word 'ok' and nothing else.",
                userPrompt: "ping",
                temperature: 0
            )
            _ = try await llm.cleanup(request)
            testResult = .success
        } catch let err as LLMError {
            testResult = .failed(err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Write WizardModelDownloadView**

```swift
// voxline/Wizard/WizardModelDownloadView.swift
import SwiftUI

struct WizardModelDownloadView: View {
    @Bindable var state: AppState
    let model: WhisperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download speech recognition model").font(.title.bold())
            Text("\(model.displayName) — about \(model.approxSizeMB) MB. Runs entirely on your Mac; audio never leaves the device.")
                .foregroundStyle(.secondary)

            ModelDownloadView(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 5: Write WizardDoneView**

```swift
// voxline/Wizard/WizardDoneView.swift
import SwiftUI

struct WizardDoneView: View {
    let chord: HotkeyChord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're set up").font(.title.bold())
            Text("Hold **\(chord.displayName)** in any text field, talk, release. voxline will transcribe locally and paste cleaned text.")
                .foregroundStyle(.secondary)
            Text("Open Settings from the menu bar to add per-app prompts, change the chord, or pick a different mic.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 6: Build to verify**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add voxline/Wizard/WizardWelcomeView.swift voxline/Wizard/WizardPermissionsView.swift voxline/Wizard/WizardAPIKeyView.swift voxline/Wizard/WizardModelDownloadView.swift voxline/Wizard/WizardDoneView.swift
git commit -m "Add wizard step views"
```

---

### Task 17: WizardRootView + FirstRunWindowController

Hosts the wizard in a regular `NSWindow`. Wires Continue/Back footer.

**Files:**
- Create: `voxline/Wizard/WizardRootView.swift`
- Create: `voxline/Wizard/FirstRunWindowController.swift`

- [ ] **Step 1: Implement WizardRootView**

```swift
// voxline/Wizard/WizardRootView.swift
import SwiftUI

struct WizardRootView: View {
    @Bindable var vm: WizardViewModel
    @Bindable var state: AppState
    let model: WhisperModel
    let chord: HotkeyChord

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if vm.canGoBack {
                    Button("Back") { vm.goBack() }
                }
                Spacer()
                primaryButton
            }
            .padding()
        }
        .frame(width: 600, height: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.currentStep {
        case .welcome: WizardWelcomeView()
        case .permissions: WizardPermissionsView()
        case .apiKey: WizardAPIKeyView(vm: vm.apiKeyVM)
        case .modelDownload: WizardModelDownloadView(state: state, model: model)
        case .done: WizardDoneView(chord: chord)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch vm.currentStep {
        case .done:
            Button("Get started") { vm.complete() }
                .keyboardShortcut(.defaultAction)
        case .modelDownload:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.status != .idle)
        default:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
```

- [ ] **Step 2: Implement FirstRunWindowController**

```swift
// voxline/Wizard/FirstRunWindowController.swift
import AppKit
import SwiftUI

@MainActor
final class FirstRunWindowController {

    private var window: NSWindow?

    func show(
        state: AppState,
        settings: AppSettings,
        model: WhisperModel,
        chord: HotkeyChord,
        onComplete: @escaping () -> Void
    ) {
        if let window {
            window.makeKeyAndOrderFront(nil); NSApp.activate(); return
        }
        let vm = WizardViewModel(settings: settings)
        vm.onComplete = { [weak self] in
            self?.close()
            onComplete()
        }
        let root = WizardRootView(vm: vm, state: state, model: model, chord: chord)
        let host = NSHostingView(rootView: root)

        // Hide close + minimize so the user can't dismiss without completing.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "Welcome to voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add voxline/Wizard/WizardRootView.swift voxline/Wizard/FirstRunWindowController.swift
git commit -m "Add WizardRootView + FirstRunWindowController"
```

---

### Task 18: Gate AppCoordinator on first-run flag

On a fresh launch with `hasCompletedFirstRun == false`, show the wizard *before* installing the hotkey tap or kicking off the existing model-prep flow. The wizard's model-download step shares `state.status` with the existing prepareIfNeeded(), so reuse it directly: kick off `prepareIfNeeded(...)` *while the wizard is on its model-download step* and let the wizard's "Continue" button block on `state.status == .idle`.

**Files:**
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Restructure startIfNeeded**

```swift
// In AppCoordinator:

func startIfNeeded(state: AppState) {
    guard !didStart else { return }
    didStart = true

    let settings = AppSettings()
    if !settings.hasCompletedFirstRun {
        startWizardThenApp(state: state, settings: settings)
    } else {
        startApp(state: state, settings: settings)
    }
}

private func startWizardThenApp(state: AppState, settings: AppSettings) {
    // Build the services up front so the wizard's model-download step can
    // share state.status with prepareIfNeeded().
    let services = buildServices(state: state, settings: settings)

    let wizard = FirstRunWindowController()
    self.firstRunWindow = wizard
    wizard.show(
        state: state,
        settings: settings,
        model: settings.whisperModel,
        chord: settings.hotkeyChord
    ) { [weak self] in
        guard let self else { return }
        self.firstRunWindow = nil
        self.installHotkey(state: state, settings: settings)
    }

    // While the user is on Welcome/Permissions/API-Key, eagerly start the
    // model download in the background so by the time they land on the
    // download step, progress is already advancing.
    prepareIfNeeded(state: state, transcriber: services.transcriber)
}

private func startApp(state: AppState, settings: AppSettings) {
    let services = buildServices(state: state, settings: settings)
    installHotkey(state: state, settings: settings)
    prepareIfNeeded(state: state, transcriber: services.transcriber)
}

// buildServices: move the existing capture/transcriber/router/llm/pipeline
// construction here, returning a tuple. installHotkey: the existing
// HotkeyMonitor setup + start() + accessibility-retry loop.
//
// (Note: this is a refactor of existing startIfNeeded — preserve the
// observers and the input-monitoring watchdog. Do NOT skip them.)
```

Add the new property:

```swift
private var firstRunWindow: FirstRunWindowController?
```

- [ ] **Step 2: Build (no new tests — wizard flow is verified manually in Plan 5 smoke)**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -quiet`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "Show first-run wizard before installing hotkey + starting app"
```

---

## Manual Verification (Plan 4 acceptance)

After all 18 tasks land, walk this smoke before declaring Plan 4 done. (Plan 5 will harden the rough edges this surfaces.)

1. **Fresh-install wizard.** Delete `~/Library/Containers/com.voxline.voxline/`. Build + run. Wizard appears. Walk Welcome → Permissions (grant all three) → API Key (paste a real key, "Test connection" returns ✓) → Model Download (progress, then Continue enables) → Done → "Get started". Wizard closes; menu icon goes to `mic`.
2. **Subsequent launch skips the wizard.** Quit. Relaunch. No wizard.
3. **Hotkey rebind.** Open Settings → General. Click "Record chord…", press Right Cmd then Right Shift. Save. Hold Right Cmd + Right Shift in TextEdit, dictate. Cleaned text pastes.
4. **Mic device switch.** Plug in an external USB mic. Settings → General. Pick the USB mic. Save. Dictate. Confirm via System Settings → Sound that voxline used the picked mic (or by speaking only into the external mic).
5. **Model switch.** Settings → General. Switch to small.en. Save. Dictate; first time pays a download (progress in menu bar) + prewarm; subsequent dictations are fast.
6. **Modes editor.** Settings → Modes. Click "Add from running apps", pick TextEdit. Edit prompt to "ALL CAPS THE TRANSCRIPT." Save. Dictate in TextEdit; output is uppercase. Delete the TextEdit mode. Save. Dictate again; falls back to `*` mode.
7. **Pause/Resume.** Click menu bar → "Pause voxline". Hold the chord; nothing happens. Click "Resume voxline". Chord works again.

Tag `settings-wizard-complete` after this passes.

---

## Self-Review

**Spec coverage:**

- §6.1 Toggle voxline menu item — Task 13 ✓
- §6.3 General tab (hotkey, input device, Whisper model) — Tasks 1, 2, 4, 5, 6, 7, 8 ✓
- §6.3 Modes tab (CRUD + Add from running apps) — Tasks 9, 10, 11, 12 ✓
- §6.4 First-run wizard (5 steps) — Tasks 14, 15, 16, 17, 18 ✓
- §5.1 modes.json sandbox path — already correct via `AppPaths.modesFile()` (Plan 3); ModeStore reused unchanged ✓
- §5.3 UserDefaults for chord/model/device — Task 2 ✓

**Placeholder scan:**
- Task 8's note about ModesSettingsView's parameterless init being temporarily missing is a real ordering concern, not a TBD. The fix is "do Tasks 9-12 next without committing 8 in isolation," which the task explicitly states.
- Task 18 references `buildServices` and `installHotkey` as refactor extractions of the current `startIfNeeded` body. Implementer must move existing code, not write new logic. The "Note" makes this explicit.
- No "TBD" / "implement later" / "similar to" elsewhere.

**Type consistency:**
- `HotkeyChord.Modifier` cases (leftControl, leftOption, leftCommand, leftShift + right variants) used in Tasks 1, 7. `default` constant used in Tasks 1, 2, 3.
- `GeneralSettingsSnapshot` fields (chord, audioInputDeviceUID, whisperModel) used in Tasks 6, 8.
- `WizardStep` cases (welcome, permissions, apiKey, modelDownload, done) used in Tasks 14, 15, 16, 17.
- `ModesSettingsError.duplicateBundleID(String)` used in Task 10's test and implementation.
- `ModesApplier.apply(modes:)` matches between Task 10 (definition) and Task 11 (AppCoordinator extension).
- `GeneralSettingsApplier.apply(_:)` matches between Task 6 (definition) and Task 8 (AppCoordinator extension).

**Risks / gotchas the implementer should know:**

- **WhisperKit gotcha (memory record):** Task 8's model-switch path uses `prepareModel` then `prewarm` — DO NOT pass `download: false` with a `modelFolder` argument; that combination hangs prewarm. The existing TranscriptionService internals are correct; just don't try to optimize them.
- **Sandbox path (memory record):** modes.json + model cache live in `~/Library/Containers/com.voxline.voxline/Data/...`, not `~/Documents` or `~/Library/Application Support` directly. All file I/O routes through `FileManager`/`AppPaths`. When debugging "did the file save?", look in the container.
- **CGEvent flags rawValue uses the device-bit bits (NX_DEVICELCTLKEYMASK etc.), which differ from the coalesced .maskControl bits.** HotkeyChord.Modifier.deviceMaskBit is the source of truth. The existing tap callback (Task 3) already uses these correctly.
- **AVAudioEngine.inputNode device switching:** the AudioUnit-level device-set call in Task 5 only takes effect at next `engine.start()`. Plan 2's pipeline restarts the engine on every chord, so the new device picks up on the next dictation — no explicit teardown needed. If a future plan keeps the engine running across captures, this assumption changes.
- **NSEvent.addLocalMonitorForEvents in ChordRecorderView (Task 7) only fires while the Settings window is the key window.** That's exactly what we want — we don't need a global tap for chord recording, and a local monitor avoids triggering another TCC prompt or fighting the live HotkeyMonitor's tap.
- **First-run wizard + parallel model download (Task 18):** the model download starts as soon as the wizard appears, *not* when the user reaches the download step. The user's wall-clock time on Welcome/Permissions/API-Key bootstraps the download for free. The download step's "Continue" button gates on `state.status == .idle`, so if the user is fast, they wait; if slow, they continue immediately.
- **`Pause voxline` (Task 13) uses a 1-second polling timer to react to the menu toggle.** This is correct because `AppState` is `@Observable` but the coordinator isn't a SwiftUI view — wiring `withObservationTracking` to a non-View consumer is more code for a once-per-toggle reaction. The polling cost is negligible.

---

## Plan complete and saved to `docs/superpowers/plans/2026-05-09-voxline-settings-wizard.md`.
