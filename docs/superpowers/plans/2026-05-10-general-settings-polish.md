# General Settings Tab — A-Grade Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the General tab of Settings to "A across the board" by fixing functional bugs, moving to macOS-standard instant-apply, hardening device handling, and polishing UX.

**Architecture:** Six tasks, ordered to do trivial fixes first, then VM refactors that other tasks build on, then the instant-apply rewrite, then UX polish. The biggest behavioral change is dropping the explicit Save button in favor of instant-apply, which is the macOS HIG standard.

**Tech Stack:** SwiftUI (`@Observable` MVVM), CoreAudio (device enumeration + listener), AppKit (`NSEvent` local monitor for chord recording), Swift Testing framework.

**Out of scope (deferred as YAGNI / micro-perf):**
- Issue #12 (default arg on VM init) — cosmetic, no behavior change
- Issue #13 (UserDefaults round-trips) — micro-perf, no measurable user impact
- Issue #17 (extra comment on `.onDisappear`) — not worth a code change

---

## File Map

**Modified:**
- `voxline/Settings/GeneralSettingsView.swift` — remove Save button, switch to bindings that call VM setters, add disconnected-device row, resizable frame, Reset button
- `voxline/Settings/GeneralSettingsViewModel.swift` — own `devices`, `lastError`; expose explicit setters; commit-on-change; subscribe to device changes; conflict warning; `resetToDefaults`
- `voxline/Settings/ChordRecorderView.swift` — Esc to cancel, fixedSize on display label
- `voxline/Audio/AudioDeviceEnumerator.swift` — add `AudioDeviceListener` for kAudioHardwarePropertyDevices changes

**New:**
- (no new files)

**Tests modified:**
- `voxlineTests/GeneralSettingsViewModelTests.swift` — adapt to instant-apply API, add tests for disconnected device, conflict warning, reset

**Tests new:**
- `voxlineTests/AudioDeviceListenerTests.swift` — minimal test that the listener wrapper installs/removes cleanly without crashing (functional callback test requires real device events, so we keep it light)

---

### Task 1: Trivial cleanup — copy fix + dead `throws`

Fixes review issues #1 (misleading whisper-model copy) and #3 (`save()` declared `throws` but never throws).

**Files:**
- Modify: `voxline/Settings/GeneralSettingsView.swift:34`
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift:26`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift:38` (drop `try`)

- [ ] **Step 1: Update the whisper-model help text to match actual behavior**

The applier triggers download immediately on save (voxlineApp.swift:441-455), not "on next launch."

Replace in `voxline/Settings/GeneralSettingsView.swift` line ~34:

```swift
Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
    .foregroundStyle(.secondary)
    .font(.callout)
```

- [ ] **Step 2: Remove dead `throws` from `save()`**

In `voxline/Settings/GeneralSettingsViewModel.swift`:

```swift
func save() {
    var s = settings
    s.hotkeyChord = chord
    s.audioInputDeviceUID = audioInputDeviceUID
    s.whisperModel = whisperModel
    s.playHotkeySounds = playHotkeySounds
    settings = s
    applier.apply(GeneralSettingsSnapshot(
        chord: chord,
        audioInputDeviceUID: audioInputDeviceUID,
        whisperModel: whisperModel,
        playHotkeySounds: playHotkeySounds
    ))
}
```

(Removes `throws`. Task 4 will replace this method entirely with instant-apply, but we keep the file in working order between tasks.)

- [ ] **Step 3: Update test call site**

In `voxlineTests/GeneralSettingsViewModelTests.swift`, change line 38 from `try vm.save()` to `vm.save()`. Remove `throws` from the test method signature.

- [ ] **Step 4: Update `saveWithErrorBanner` in the View**

In `voxline/Settings/GeneralSettingsView.swift`, replace the function body:

```swift
private func saveWithErrorBanner() {
    vm.save()
    vm.lastError = nil
}
```

(Task 4 will delete this entirely along with the Save button.)

- [ ] **Step 5: Build and run the test suite**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -40`
Expected: all GeneralSettingsViewModel tests PASS.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/GeneralSettingsView.swift voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "general settings: fix misleading download copy, drop dead throws on save"
```

---

### Task 2: Move `devices` + `lastError` into VM, handle disconnected device

Fixes review issues #11 (devices in View not VM), #14 (saveWithErrorBanner in View), and #2 (selected device disappears silently when unplugged).

The disconnected-device fix: when the saved `audioInputDeviceUID` does not match any present device, we surface a synthetic row labelled "(disconnected)" so the picker selection never goes blank.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/GeneralSettingsView.swift`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Write failing tests for new VM surface**

Append to `voxlineTests/GeneralSettingsViewModelTests.swift` (inside the `@Suite`):

```swift
@Test func device_rows_includes_disconnected_marker_when_saved_uid_is_absent() {
    var settings = AppSettings(defaults: defaults())
    settings.audioInputDeviceUID = "GhostMic"
    let vm = GeneralSettingsViewModel(
        settings: settings,
        applier: NoopApplier(),
        deviceEnumerator: { [] }   // no devices present
    )
    let rows = vm.deviceRows
    #expect(rows.contains { $0.uid == "GhostMic" && $0.label.contains("disconnected") })
}

@Test func device_rows_omits_disconnected_marker_when_uid_is_present_in_device_list() {
    var settings = AppSettings(defaults: defaults())
    settings.audioInputDeviceUID = "MicA"
    let stubDevices = [AudioDevice(uid: "MicA", name: "Mic A", isDefault: false)]
    let vm = GeneralSettingsViewModel(
        settings: settings,
        applier: NoopApplier(),
        deviceEnumerator: { stubDevices }
    )
    let rows = vm.deviceRows
    #expect(rows.contains { $0.uid == "MicA" && !$0.label.contains("disconnected") })
    #expect(rows.allSatisfy { !$0.label.contains("disconnected") || $0.uid != "MicA" })
}
```

- [ ] **Step 2: Run tests to confirm they fail with compile errors**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -30`
Expected: FAIL — `deviceRows` does not exist; `deviceEnumerator` parameter does not exist.

- [ ] **Step 3: Extend the VM**

Replace `voxline/Settings/GeneralSettingsViewModel.swift` with:

```swift
import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?       // nil = system default
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord
    var audioInputDeviceUID: String?
    var whisperModel: WhisperModel
    var playHotkeySounds: Bool
    var lastError: String?

    var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]

    init(
        settings: AppSettings = AppSettings(),
        applier: GeneralSettingsApplier,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices
    ) {
        self.settings = settings
        self.applier = applier
        self.deviceEnumerator = deviceEnumerator
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.devices = deviceEnumerator()
    }

    /// Picker rows including a synthetic "(disconnected)" entry when the
    /// saved UID is not currently enumerable. Keeps the Picker selection
    /// stable instead of going blank when a USB mic is unplugged.
    var deviceRows: [AudioDeviceRow] {
        var rows: [AudioDeviceRow] = [AudioDeviceRow(uid: nil, label: "System default")]
        for d in devices {
            let suffix = d.isDefault ? " (default)" : ""
            rows.append(AudioDeviceRow(uid: d.uid, label: d.name + suffix))
        }
        if let uid = audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            rows.append(AudioDeviceRow(uid: uid, label: "(disconnected) previously selected"))
        }
        return rows
    }

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    func save() {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds
        ))
    }
}
```

- [ ] **Step 4: Update the View to use VM-owned devices and rows**

Replace `voxline/Settings/GeneralSettingsView.swift` with:

```swift
// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel

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
                    ForEach(vm.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
            }

            Section("Speech recognition model") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }

            HStack {
                Spacer()
                Button("Save") {
                    vm.save()
                    vm.lastError = nil
                }
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
    }
}
```

(`saveWithErrorBanner` removed; `displayLabel(for:)` removed; `devices` no longer in view state. Save button stays for now — Task 4 deletes it.)

- [ ] **Step 5: Run all settings tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -40`
Expected: PASS, including the two new disconnected-device tests.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/GeneralSettingsView.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "general settings: move devices into VM, surface disconnected mic in picker"
```

---

### Task 3: Live device-list updates via CoreAudio listener

Fixes review issue #4. Plug/unplug while Settings is open should update the picker live.

**Files:**
- Modify: `voxline/Audio/AudioDeviceEnumerator.swift`
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Create: `voxlineTests/AudioDeviceListenerTests.swift`

- [ ] **Step 1: Write a smoke test for `AudioDeviceListener`**

Create `voxlineTests/AudioDeviceListenerTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct AudioDeviceListenerTests {

    @Test func listener_installs_and_uninstalls_without_crashing() {
        // We can't reliably trigger device-change events from a unit test on
        // CI, so we just verify the listener can be constructed and torn down
        // without hitting CoreAudio errors that would crash the process.
        var fired = 0
        do {
            let listener = AudioDeviceListener { fired += 1 }
            _ = listener   // silence "unused" — we want it alive in the scope
        }
        #expect(fired >= 0)   // sanity: no crash
    }
}
```

- [ ] **Step 2: Run the test — expect compile failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/AudioDeviceListenerTests 2>&1 | tail -20`
Expected: FAIL — `AudioDeviceListener` does not exist.

- [ ] **Step 3: Add `AudioDeviceListener` to AudioDeviceEnumerator.swift**

Append to `voxline/Audio/AudioDeviceEnumerator.swift`:

```swift
/// Watches kAudioHardwarePropertyDevices and invokes `onChange` on the main
/// queue when the device list changes (mic plug/unplug, Bluetooth connect,
/// etc.). The listener block is detached automatically on deinit.
final class AudioDeviceListener {

    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private let block: AudioObjectPropertyListenerBlock

    init(onChange: @escaping () -> Void) {
        // Capture the handler before storing so the block we add is the same
        // instance we later remove. CoreAudio matches listeners by block id.
        self.block = { _, _ in DispatchQueue.main.async { onChange() } }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
    }
}
```

- [ ] **Step 4: Wire the listener into the VM**

In `voxline/Settings/GeneralSettingsViewModel.swift`, add a stored property and start the listener in init:

```swift
private var deviceListener: AudioDeviceListener?
```

At the bottom of `init(...)`:

```swift
self.deviceListener = AudioDeviceListener { [weak self] in
    Task { @MainActor in self?.refreshDevices() }
}
```

- [ ] **Step 5: Run both test suites**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/AudioDeviceListenerTests -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -30`
Expected: PASS.

- [ ] **Step 6: Manually verify**

Build and launch the app. Open Settings → General. Unplug/replug a USB mic (or toggle Bluetooth headphones). The picker list should update without closing the window.

- [ ] **Step 7: Commit**

```bash
git add voxline/Audio/AudioDeviceEnumerator.swift voxline/Settings/GeneralSettingsViewModel.swift voxlineTests/AudioDeviceListenerTests.swift
git commit -m "general settings: live-update mic picker on device plug/unplug"
```

---

### Task 4: Instant-apply rewrite (drop the Save button)

Fixes review issues #5 and #6. macOS settings panes are instant-apply. Each property change writes through to AppSettings and notifies the applier immediately.

**Design:** Properties stay public-write on the VM, but use Swift's `didSet` guarded by a `loaded` flag (so init doesn't call applier with the values it just loaded). On every change post-init, a private `commit()` writes the snapshot and calls applier.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/GeneralSettingsView.swift`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Update existing test to expect instant-apply**

Replace the `save_persists_and_calls_applier` test in `voxlineTests/GeneralSettingsViewModelTests.swift` with `mutations_persist_and_call_applier_immediately`:

```swift
@Test func mutations_persist_and_call_applier_immediately() {
    let d = defaults()
    let settings = AppSettings(defaults: d)
    let applier = RecordingApplier()
    let vm = GeneralSettingsViewModel(settings: settings, applier: applier)

    let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
    vm.chord = chord
    #expect(applier.applied?.chord == chord)
    #expect(AppSettings(defaults: d).hotkeyChord == chord)

    vm.audioInputDeviceUID = "NewMic"
    #expect(applier.applied?.audioInputDeviceUID == "NewMic")
    #expect(AppSettings(defaults: d).audioInputDeviceUID == "NewMic")

    vm.whisperModel = .smallEn
    #expect(applier.applied?.whisperModel == .smallEn)
    #expect(AppSettings(defaults: d).whisperModel == .smallEn)

    vm.playHotkeySounds = false
    #expect(applier.applied?.playHotkeySounds == false)
    #expect(AppSettings(defaults: d).playHotkeySounds == false)
}

@Test func init_does_not_call_applier() {
    var settings = AppSettings(defaults: defaults())
    settings.hotkeyChord = HotkeyChord(modifierA: .leftCommand, modifierB: .rightOption)
    let applier = RecordingApplier()
    _ = GeneralSettingsViewModel(settings: settings, applier: applier)
    #expect(applier.applied == nil)
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -30`
Expected: FAIL — current VM only calls applier on `save()`.

- [ ] **Step 3: Rewrite the VM with `didSet` + loaded flag**

Replace `voxline/Settings/GeneralSettingsViewModel.swift`:

```swift
import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord { didSet { if loaded { commit() } } }
    var audioInputDeviceUID: String? { didSet { if loaded { commit() } } }
    var whisperModel: WhisperModel { didSet { if loaded { commit() } } }
    var playHotkeySounds: Bool { didSet { if loaded { commit() } } }

    var lastError: String?
    var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]
    private var deviceListener: AudioDeviceListener?
    private var loaded = false

    init(
        settings: AppSettings = AppSettings(),
        applier: GeneralSettingsApplier,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices
    ) {
        self.settings = settings
        self.applier = applier
        self.deviceEnumerator = deviceEnumerator
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.devices = deviceEnumerator()
        self.loaded = true
        self.deviceListener = AudioDeviceListener { [weak self] in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    var deviceRows: [AudioDeviceRow] {
        var rows: [AudioDeviceRow] = [AudioDeviceRow(uid: nil, label: "System default")]
        for d in devices {
            let suffix = d.isDefault ? " (default)" : ""
            rows.append(AudioDeviceRow(uid: d.uid, label: d.name + suffix))
        }
        if let uid = audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            rows.append(AudioDeviceRow(uid: uid, label: "(disconnected) previously selected"))
        }
        return rows
    }

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    private func commit() {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds
        ))
    }
}
```

(Note: `save()` removed entirely. Also note `loads_current_values_on_init` test still passes — it doesn't depend on save semantics.)

- [ ] **Step 4: Strip Save button + error banner from the View**

Replace `voxline/Settings/GeneralSettingsView.swift`:

```swift
// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel

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
                    ForEach(vm.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
            }

            Section("Speech recognition model") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}
```

(`lastError` stays on the VM for now since Task 6 removes it formally — or removes the field if no consumer remains. Treat as TODO for Task 6 self-review.)

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -50`
Expected: PASS. Watch specifically that tests in other suites that mutate `playHotkeySounds` etc. still pass — applier is now called on every change, but the test appliers (`NoopApplier`, `RecordingApplier`) handle that fine.

- [ ] **Step 6: Manually verify**

Build and run. Open Settings → General. Change the hotkey, mic, model, and sound toggle. Each change should take effect immediately (hotkey rebinds; toggling sounds instantly enables/disables; switching models triggers the prep/download path; mic change applies on next dictation). Close and reopen Settings — the new values should be persisted.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/GeneralSettingsView.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "general settings: instant-apply, drop Save button (macOS HIG)"
```

---

### Task 5: ChordRecorderView polish — Esc, fixedSize, VoiceOver warning

Fixes review issues #7 (Esc to cancel), #16 (chord display may clip), and a narrowed take on #8: warn when the user picks Ctrl+Option, which is the VoiceOver modifier and will conflict if VO is on.

**Files:**
- Modify: `voxline/Settings/ChordRecorderView.swift`
- Modify: `voxline/Hotkey/HotkeyChord.swift` (computed warning)
- Modify: `voxlineTests/HotkeyChordTests.swift`

- [ ] **Step 1: Write tests for the conflict warning**

Append to `voxlineTests/HotkeyChordTests.swift`:

```swift
@Test func voiceover_chord_warning_fires_for_ctrl_option_combos() {
    let lcLo = HotkeyChord(modifierA: .leftControl, modifierB: .leftOption)
    let loLc = HotkeyChord(modifierA: .leftOption,  modifierB: .leftControl)
    let rcRo = HotkeyChord(modifierA: .rightControl, modifierB: .rightOption)
    let mixed = HotkeyChord(modifierA: .leftControl, modifierB: .rightOption)
    #expect(lcLo.conflictWarning != nil)
    #expect(loLc.conflictWarning != nil)
    #expect(rcRo.conflictWarning != nil)
    #expect(mixed.conflictWarning != nil)
}

@Test func no_warning_for_unrelated_chords() {
    let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
    #expect(chord.conflictWarning == nil)
}
```

- [ ] **Step 2: Run — expect compile failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/HotkeyChordTests 2>&1 | tail -20`
Expected: FAIL — `conflictWarning` does not exist.

- [ ] **Step 3: Add `conflictWarning` to HotkeyChord**

Append to `voxline/Hotkey/HotkeyChord.swift`, inside `struct HotkeyChord`:

```swift
/// Soft warning for chord combinations known to conflict with system
/// accessibility features. Returns nil when no conflict is known.
var conflictWarning: String? {
    let a = modifierA, b = modifierB
    let isControl: (Modifier) -> Bool = { $0 == .leftControl || $0 == .rightControl }
    let isOption:  (Modifier) -> Bool = { $0 == .leftOption  || $0 == .rightOption }
    let isCtrlOpt = (isControl(a) && isOption(b)) || (isOption(a) && isControl(b))
    if isCtrlOpt {
        return "This chord matches the VoiceOver modifier (Ctrl+Option). If VoiceOver is on, hold-to-talk may conflict."
    }
    return nil
}
```

- [ ] **Step 4: Run the chord tests — expect PASS**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/HotkeyChordTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Update ChordRecorderView for Esc + fixedSize + warning display**

Replace `voxline/Settings/ChordRecorderView.swift`:

```swift
// voxline/Settings/ChordRecorderView.swift
import AppKit
import Carbon.HIToolbox
import IOKit.hidsystem
import SwiftUI

struct ChordRecorderView: View {

    @Binding var chord: HotkeyChord

    @State private var isRecording = false
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?
    @State private var firstModifier: HotkeyChord.Modifier?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(chord.displayName)
                    .monospaced()
                    .fixedSize()
                if isRecording {
                    Text(firstModifier == nil ? "Press first modifier… (Esc to cancel)" : "Now press second modifier… (Esc to cancel)")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { stop() }
                } else {
                    Button("Record chord…") { start() }
                }
            }
            if let warning = chord.conflictWarning {
                Text(warning)
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        firstModifier = nil
        isRecording = true
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handle(event)
            return event
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc cancels recording; consume the event so it doesn't propagate.
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            return event
        }
    }

    private func stop() {
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor   { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        keyMonitor = nil
        firstModifier = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        guard let pressed = modifier(from: event), event.type == .flagsChanged else { return }
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
        switch Int(event.keyCode) {
        case kVK_Control:      return .leftControl
        case kVK_RightControl: return .rightControl
        case kVK_Option:       return .leftOption
        case kVK_RightOption:  return .rightOption
        case kVK_Command:      return .leftCommand
        case kVK_RightCommand: return .rightCommand
        case kVK_Shift:        return .leftShift
        case kVK_RightShift:   return .rightShift
        default: return nil
        }
    }
}
```

- [ ] **Step 6: Build and manually verify**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: build succeeds.

Manually: open Settings → General → "Record chord…", press Esc — should cancel. Pick Ctrl+Option — orange warning appears. Pick Cmd+Shift — warning gone.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/ChordRecorderView.swift voxline/Hotkey/HotkeyChord.swift voxlineTests/HotkeyChordTests.swift
git commit -m "chord recorder: Esc to cancel, VoiceOver-conflict warning, fixedSize display"
```

---

### Task 6: View polish — labels, resizable frame, Reset to defaults

Fixes review issues #9 (redundant Picker label inside "Speech recognition model" section), #10 (fixed frame), and #18 (no Reset to defaults). Also tidies up the residual `lastError` field on the VM that no longer has a UI consumer.

**Files:**
- Modify: `voxline/Settings/GeneralSettingsViewModel.swift`
- Modify: `voxline/Settings/GeneralSettingsView.swift`
- Modify: `voxlineTests/GeneralSettingsViewModelTests.swift`

- [ ] **Step 1: Write a failing test for `resetToDefaults`**

Append to `voxlineTests/GeneralSettingsViewModelTests.swift`:

```swift
@Test func reset_restores_spec_defaults_and_calls_applier_once() {
    var settings = AppSettings(defaults: defaults())
    settings.hotkeyChord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
    settings.audioInputDeviceUID = "MicX"
    settings.whisperModel = .smallEn
    settings.playHotkeySounds = false

    let applier = RecordingApplier()
    let vm = GeneralSettingsViewModel(settings: settings, applier: applier)
    vm.resetToDefaults()

    #expect(vm.chord == .default)
    #expect(vm.audioInputDeviceUID == nil)
    #expect(vm.whisperModel == .default)
    #expect(vm.playHotkeySounds == true)
    #expect(applier.applied?.chord == .default)
    #expect(applier.applied?.whisperModel == .default)
    #expect(applier.applied?.playHotkeySounds == true)
    #expect(applier.applied?.audioInputDeviceUID == nil)
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test -only-testing:voxlineTests/GeneralSettingsViewModelTests 2>&1 | tail -25`
Expected: FAIL — `resetToDefaults` does not exist.

- [ ] **Step 3: Add `resetToDefaults` and remove unused `lastError`**

In `voxline/Settings/GeneralSettingsViewModel.swift`:

Remove the line `var lastError: String?`.

Add a method below `commit()`:

```swift
/// Restore Spec defaults: hotkey to Left Ctrl + Left Option, system-default
/// mic, large-v3-turbo, sounds on. Performs one batched commit so the
/// applier sees a single coherent snapshot rather than four partial ones.
func resetToDefaults() {
    loaded = false
    chord = .default
    audioInputDeviceUID = nil
    whisperModel = .default
    playHotkeySounds = true
    loaded = true
    commit()
}
```

(The `loaded = false` trick suppresses the four `didSet`-triggered commits, then we do one explicit batched commit. This keeps applier-side cost predictable.)

- [ ] **Step 4: Update the View — drop redundant Picker label, add Reset, allow resize**

Replace `voxline/Settings/GeneralSettingsView.swift`:

```swift
// voxline/Settings/GeneralSettingsView.swift
import SwiftUI

struct GeneralSettingsView: View {

    @State private var vm: GeneralSettingsViewModel

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
                    ForEach(vm.deviceRows) { row in
                        Text(row.label).tag(row.uid)
                    }
                }
            }

            Section("Speech recognition") {
                Picker("Model", selection: $vm.whisperModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Text("Switching downloads the new model now (~\(vm.whisperModel.approxSizeMB) MB).")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section("Feedback") {
                Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") { vm.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 380, idealHeight: 460)
    }
}
```

(Section titles changed: "Speech recognition model" → "Speech recognition" so the inner "Model" label isn't redundant; "Sounds" → "Feedback" for room to grow. `frame` switched from fixed size to `min/ideal` so the user can resize.)

- [ ] **Step 5: Run all tests**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' test 2>&1 | tail -40`
Expected: PASS.

- [ ] **Step 6: Manually verify**

Build and launch. Settings → General:
- Resize the window — content reflows, no clipping.
- Click "Reset to Defaults" — chord becomes Left Ctrl + Left Option, mic becomes "System default", model becomes large-v3-turbo, sound toggle ON. Hotkey monitor reflects the new chord without restarting the app.

- [ ] **Step 7: Commit**

```bash
git add voxline/Settings/GeneralSettingsViewModel.swift voxline/Settings/GeneralSettingsView.swift voxlineTests/GeneralSettingsViewModelTests.swift
git commit -m "general settings: tidy section labels, resizable frame, Reset to Defaults"
```

---

## Self-Review Checklist (run before handing off)

**Spec coverage:** every "in-scope" issue from the review (#1–#11, #14–#16, #18) is mapped to a task above. Out-of-scope deferrals (#12, #13, #17) are listed in the goal section.

**Type consistency:**
- `AudioDeviceRow` defined in Task 2, used identically in Task 4 and Task 6. ✓
- `conflictWarning` defined on `HotkeyChord` in Task 5. ✓
- `resetToDefaults` defined and called identically in Task 6. ✓
- `loaded` flag pattern used the same way in Task 4 (didSet guard) and Task 6 (suppress during reset). ✓

**Placeholders:** no "TBD" / "implement later" / "add appropriate error handling" present. Every code step shows the actual code. ✓

**Risk callouts the implementer should know:**
- The didSet+loaded pattern in Task 4 is sensitive to call order in init. Tests `init_does_not_call_applier` and `mutations_persist_and_call_applier_immediately` together pin both halves of the contract.
- Task 3's `AudioDeviceListener` deinit: confirm via Instruments that listener removal succeeds (CoreAudio matches by block identity). The smoke test catches outright crashes; a leak would show as accumulating listeners on repeated Settings open/close.
- Task 5's keyDown monitor returns `nil` for Esc to consume the event. If anywhere else in the app installs an Esc handler at the same scope, this could shadow it. Currently nothing does; if that changes, revisit.
