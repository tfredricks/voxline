# Settings Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two-tab Settings window with a single pipeline-ordered scrolling page that fuses the LLM provider with its API key, surfaces app-readiness at a glance, and adds a live mic level + Whisper download state.

**Architecture:** Drop `TabView` from `SettingsView`. Compose a single page from focused section components. Reuse the existing `GeneralSettingsViewModel` and `APIKeysSettingsViewModel` unchanged. Add three new pieces of plumbing: a derived-state `SettingsStatusViewModel` for the top status strip, a settings-only `MicLevelMonitor` audio tap for the live meter, and inline use of the existing `TranscriptionService.isModelCached(_:)` for Whisper picker labels. No persistence/keychain/LLM behavior changes.

**Tech Stack:** Swift 6, SwiftUI (`@Observable`), AVFoundation (AVAudioEngine input tap), Swift Testing (`@Suite`/`@Test`/`#expect`).

---

## File Structure

**New files:**
- `voxline/Audio/MicLevelMonitor.swift` — settings-scoped audio tap that publishes peak level [0,1].
- `voxline/Settings/SettingsStatusViewModel.swift` — derived "Ready" / chip data from existing models + AppState.
- `voxline/Settings/Components/SettingsStatusStrip.swift` — header status row.
- `voxline/Settings/Components/MicLevelMeter.swift` — animated level bar.
- `voxline/Settings/Components/APIKeyRow.swift` — extracted reusable key field (used by Cleanup section twice).
- `voxline/Settings/Components/CleanupSection.swift` — provider picker + active key row + disclosure for inactive provider.
- `voxlineTests/MicLevelMonitorTests.swift`
- `voxlineTests/SettingsStatusViewModelTests.swift`

**Modified files:**
- `voxline/Settings/SettingsView.swift` — replace `TabView` with single-page composition.
- `voxline/voxlineApp.swift:27` — pass any new dependencies into `SettingsView`.

**Deleted files:**
- `voxline/Settings/GeneralSettingsView.swift` — sections inlined into the new `SettingsView`.
- `voxline/Settings/APIKeysSettingsView.swift` — replaced by `CleanupSection` + `APIKeyRow`.

**Note on Xcode targets:** Each new `.swift` file must be added to the `voxline` (or `voxlineTests`) target in `voxline.xcodeproj`. Use Xcode's "Add Files to voxline…" command on the file with the correct target checkbox; do not hand-edit `project.pbxproj`.

---

## Task 1: Add `MicLevelMonitor` (audio tap)

A settings-only AVAudioEngine input tap that publishes peak level. It must NOT contend with the production `AudioCaptureService` — start it only when the Settings window is visible and stop it on disappear or when a real recording starts. The peak math is delegated to the existing `AudioFormat.peakLevel(samples:)` so behavior matches production.

**Files:**
- Create: `voxline/Audio/MicLevelMonitor.swift`
- Test: `voxlineTests/MicLevelMonitorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/MicLevelMonitorTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct MicLevelMonitorTests {

    @Test @MainActor
    func starts_with_zero_level() {
        let monitor = MicLevelMonitor()
        #expect(monitor.level == 0)
    }

    @Test @MainActor
    func stop_resets_level_to_zero() {
        let monitor = MicLevelMonitor()
        monitor._setLevelForTesting(0.7)
        #expect(monitor.level == 0.7)
        monitor.stop()
        #expect(monitor.level == 0)
    }

    @Test @MainActor
    func ignores_nan_and_clamps_to_unit_range() {
        let monitor = MicLevelMonitor()
        monitor._publishLevelForTesting(.nan)
        #expect(monitor.level == 0)
        monitor._publishLevelForTesting(2.5)
        #expect(monitor.level == 1.0)
        monitor._publishLevelForTesting(-0.3)
        #expect(monitor.level == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/MicLevelMonitorTests 2>&1 | tail -30`
Expected: FAIL — `MicLevelMonitor` not defined.

- [ ] **Step 3: Implement `MicLevelMonitor`**

```swift
// voxline/Audio/MicLevelMonitor.swift
import AVFoundation
import CoreAudio
import Foundation
import Observation

/// Settings-only audio level tap. Publishes peak amplitude in [0, 1] while
/// active. Independent of `AudioCaptureService` — Settings opens its own
/// engine so a live meter works without interfering with real recordings.
/// Callers must `stop()` before a production recording starts.
@MainActor
@Observable
final class MicLevelMonitor {

    /// Most recent peak level [0, 1]. 0 when stopped or no audio.
    private(set) var level: Float = 0

    /// Optional CoreAudio UID for the preferred input device. nil = system default.
    var preferredInputDeviceUID: String?

    private let engine = AVAudioEngine()
    private var running = false

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        if let uid = preferredInputDeviceUID,
           let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid),
           let au = engine.inputNode.audioUnit {
            var mutableID = deviceID
            _ = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * 0.05))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channelData, count: count))
            let peak = AudioFormat.peakLevel(samples: chunk)
            Task { @MainActor [weak self] in
                self?.publishLevel(peak)
            }
        }

        try engine.start()
        running = true
    }

    func stop() {
        guard running else {
            level = 0
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        running = false
        level = 0
    }

    private func publishLevel(_ raw: Float) {
        guard raw.isFinite else { level = 0; return }
        level = max(0, min(1, raw))
    }

    // Test hooks — internal access; do not call from production code.
    func _setLevelForTesting(_ v: Float) { level = v }
    func _publishLevelForTesting(_ v: Float) { publishLevel(v) }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/MicLevelMonitorTests 2>&1 | tail -20`
Expected: 3 tests pass.

- [ ] **Step 5: Add file to Xcode targets**

In Xcode, add `voxline/Audio/MicLevelMonitor.swift` to the `voxline` target and `voxlineTests/MicLevelMonitorTests.swift` to `voxlineTests`. Verify the project builds (⌘B).

- [ ] **Step 6: Commit**

```bash
git add voxline/Audio/MicLevelMonitor.swift voxlineTests/MicLevelMonitorTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): add MicLevelMonitor for live mic preview"
```

---

## Task 2: Add `SettingsStatusViewModel` (derived state)

Pure logic. Given the two existing settings VMs and `AppState`, derive: overall ready/setup-needed, mic chip text, model chip (model + downloaded?), provider chip (provider + key saved?). No persistence, no IO.

**Files:**
- Create: `voxline/Settings/SettingsStatusViewModel.swift`
- Test: `voxlineTests/SettingsStatusViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// voxlineTests/SettingsStatusViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct SettingsStatusViewModelTests {

    @MainActor
    private func makeFixtures(
        provider: LLMProvider = .anthropic,
        model: WhisperModel = .smallEn,
        anthropicKey: String = "sk-ant-good",
        openaiKey: String = "",
        deviceLabel: String = "MacBook Mic",
        modelCached: Bool = true
    ) -> (general: GeneralSettingsViewModel, keys: APIKeysSettingsViewModel, status: SettingsStatusViewModel) {
        let applier = NoopApplier()
        let general = GeneralSettingsViewModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "test-\(UUID())")!),
            applier: applier,
            deviceEnumerator: { [AudioDevice(uid: "uid-1", name: deviceLabel, isDefault: true)] }
        )
        general.provider = provider
        general.whisperModel = model
        let keys = APIKeysSettingsViewModel(
            keychain: InMemoryKeychain(initial: [
                Keychain.Account.anthropic: anthropicKey,
                Keychain.Account.openai: openaiKey
            ])
        )
        let status = SettingsStatusViewModel(
            general: general,
            keys: keys,
            isModelCached: { _ in modelCached }
        )
        return (general, keys, status)
    }

    @Test @MainActor
    func ready_when_provider_key_saved_and_model_cached_and_mic_present() {
        let f = makeFixtures()
        #expect(f.status.isReady == true)
        #expect(f.status.providerChipShowsCheck == true)
        #expect(f.status.modelChipShowsCheck == true)
    }

    @Test @MainActor
    func setup_needed_when_active_provider_key_missing() {
        let f = makeFixtures(provider: .openai, openaiKey: "")
        #expect(f.status.isReady == false)
        #expect(f.status.providerChipShowsCheck == false)
    }

    @Test @MainActor
    func setup_needed_when_model_not_cached() {
        let f = makeFixtures(modelCached: false)
        #expect(f.status.isReady == false)
        #expect(f.status.modelChipShowsCheck == false)
    }

    @Test @MainActor
    func mic_chip_uses_selected_device_label_or_default() {
        let f = makeFixtures(deviceLabel: "Studio Mic")
        f.general.audioInputDeviceUID = "uid-1"
        #expect(f.status.micChipText.contains("Studio Mic"))
    }
}

// Test doubles
private final class NoopApplier: GeneralSettingsApplier, @unchecked Sendable {
    func apply(_ snapshot: GeneralSettingsSnapshot) {}
}

private final class InMemoryKeychain: Keychain {
    private var store: [String: String]
    init(initial: [String: String] = [:]) {
        self.store = initial
        super.init()
    }
    override func string(forKey account: String) throws -> String? { store[account] }
    override func set(_ value: String, forKey account: String) throws { store[account] = value }
    override func delete(forKey account: String) throws { store.removeValue(forKey: account) }
}
```

> **Note:** If `Keychain` is a struct or its methods aren't overridable, instead inject via the existing `keychain:` parameter to `APIKeysSettingsViewModel.init` using whatever protocol/extension pattern this codebase already uses for `KeychainTests`. Check `voxlineTests/KeychainTests.swift` and `voxlineTests/APIKeysSettingsViewModelTests.swift` for the project's existing test double pattern, and adapt the fixture above to match.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/SettingsStatusViewModelTests 2>&1 | tail -30`
Expected: FAIL — `SettingsStatusViewModel` not defined.

- [ ] **Step 3: Implement `SettingsStatusViewModel`**

```swift
// voxline/Settings/SettingsStatusViewModel.swift
import Foundation
import Observation

/// Derives the Settings status strip's chip data and overall readiness from
/// the existing settings view models. Pure derived state — no IO.
@Observable
@MainActor
final class SettingsStatusViewModel {

    private let general: GeneralSettingsViewModel
    private let keys: APIKeysSettingsViewModel
    private let isModelCached: (WhisperModel) -> Bool

    init(
        general: GeneralSettingsViewModel,
        keys: APIKeysSettingsViewModel,
        isModelCached: @escaping (WhisperModel) -> Bool = { TranscriptionService.isModelCached($0) }
    ) {
        self.general = general
        self.keys = keys
        self.isModelCached = isModelCached
    }

    var isReady: Bool {
        providerKeySaved && modelCached && micPresent
    }

    var modelChipShowsCheck: Bool { modelCached }
    var providerChipShowsCheck: Bool { providerKeySaved }

    var micChipText: String {
        guard let row = general.deviceRows.first(where: { $0.uid == general.audioInputDeviceUID }) else {
            return "System default mic"
        }
        return row.label
    }

    var modelChipText: String {
        general.whisperModel.displayName
    }

    var providerChipText: String {
        general.provider.displayName
    }

    private var providerKeySaved: Bool {
        let live: String
        switch general.provider {
        case .anthropic: live = keys.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openai:    live = keys.openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !live.isEmpty && keys.isPersisted(general.provider)
    }

    private var modelCached: Bool {
        isModelCached(general.whisperModel)
    }

    private var micPresent: Bool {
        !general.devices.isEmpty || general.audioInputDeviceUID == nil
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -only-testing:voxlineTests/SettingsStatusViewModelTests 2>&1 | tail -20`
Expected: 4 tests pass.

- [ ] **Step 5: Add file to Xcode targets and verify build**

Add the new `.swift` files to the appropriate targets. ⌘B should succeed.

- [ ] **Step 6: Commit**

```bash
git add voxline/Settings/SettingsStatusViewModel.swift voxlineTests/SettingsStatusViewModelTests.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): add SettingsStatusViewModel for status strip"
```

---

## Task 3: Add `SettingsStatusStrip` view

Renders the top status row. Reads from `SettingsStatusViewModel`. Each chip is a `Button` that calls a `scrollTo(_:)` closure provided by the parent (so the strip itself doesn't need a `ScrollViewReader`).

**Files:**
- Create: `voxline/Settings/Components/SettingsStatusStrip.swift`

- [ ] **Step 1: Write the implementation**

```swift
// voxline/Settings/Components/SettingsStatusStrip.swift
import SwiftUI

enum SettingsAnchor: Hashable {
    case hotkey, microphone, recognition, cleanup, feedback
}

struct SettingsStatusStrip: View {
    let status: SettingsStatusViewModel
    var scrollTo: (SettingsAnchor) -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(status.isReady ? "Ready" : "Setup needed")
                    .fontWeight(.semibold)
            }

            chip(text: status.micChipText, showsCheck: false) { scrollTo(.microphone) }
            chip(text: status.modelChipText, showsCheck: status.modelChipShowsCheck) { scrollTo(.recognition) }
            chip(text: status.providerChipText, showsCheck: status.providerChipShowsCheck) { scrollTo(.cleanup) }

            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private func chip(text: String, showsCheck: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).foregroundStyle(.secondary)
                if showsCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Jump to section")
    }
}
```

- [ ] **Step 2: Add file to Xcode target and verify build**

⌘B should succeed.

- [ ] **Step 3: Commit**

```bash
git add voxline/Settings/Components/SettingsStatusStrip.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): add SettingsStatusStrip view"
```

---

## Task 4: Add `MicLevelMeter` view

Animated horizontal bar from `0...1`. Reads from a `MicLevelMonitor`.

**Files:**
- Create: `voxline/Settings/Components/MicLevelMeter.swift`

- [ ] **Step 1: Write the implementation**

```swift
// voxline/Settings/Components/MicLevelMeter.swift
import SwiftUI

struct MicLevelMeter: View {
    let monitor: MicLevelMonitor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary.opacity(0.5))
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(
                        colors: [.green, .yellow, .red],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: max(2, geo.size.width * CGFloat(monitor.level)))
                    .animation(.easeOut(duration: 0.08), value: monitor.level)
            }
        }
        .frame(height: 8)
        .accessibilityLabel("Microphone input level")
        .accessibilityValue("\(Int(monitor.level * 100)) percent")
    }
}
```

- [ ] **Step 2: Add file to Xcode target, verify build, commit**

```bash
git add voxline/Settings/Components/MicLevelMeter.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): add MicLevelMeter view"
```

---

## Task 5: Extract `APIKeyRow` from current API keys view

Pull the per-provider key UI out of `APIKeysSettingsView` into a reusable view. Behavior must be identical — same `SecureField`/`TextField`, same reveal toggle, same Saved/Unsaved pill, same prefix-mismatch hint, same `Test` action and result label, same "Get a key →" link, same focus-loss commit.

**Files:**
- Create: `voxline/Settings/Components/APIKeyRow.swift`

- [ ] **Step 1: Write the implementation**

```swift
// voxline/Settings/Components/APIKeyRow.swift
import SwiftUI

struct APIKeyRow: View {

    let title: String
    let provider: LLMProvider
    @Binding var key: String
    @Binding var revealed: Bool
    let getKeyURL: URL
    let expectedPrefix: String
    let isPersisted: Bool
    let testing: LLMProvider?
    let testResult: APIKeyTestResult
    let lastError: String?
    var onCommit: () -> Void
    var onTest: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Section(title) {
            HStack {
                Group {
                    if revealed {
                        TextField("API key", text: $key)
                    } else {
                        SecureField("API key", text: $key)
                    }
                }
                .textContentType(.password)
                .focused($focused)
                .onSubmit(onCommit)

                Button {
                    revealed.toggle()
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealed ? "Hide key" : "Reveal key")

                statusPill
            }

            HStack(spacing: 8) {
                Link("Get a \(title) key →", destination: getKeyURL).font(.callout)
                Spacer()
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefixMismatch = !trimmed.isEmpty && !trimmed.hasPrefix(expectedPrefix)
                let antInOpenAI = (provider == .openai) && trimmed.hasPrefix("sk-ant-")
                if prefixMismatch || antInOpenAI {
                    Label(
                        antInOpenAI ? "This looks like an Anthropic key" : "Expected prefix \(expectedPrefix)",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.callout)
                }
            }

            HStack {
                Button("Test") { onTest() }
                    .disabled(testing != nil || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if testing == provider { ProgressView().controlSize(.small) }
                testResultLabel
                Spacer()
            }

            if let err = lastError {
                Text(err).foregroundStyle(.red).font(.callout)
            }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { onCommit() }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        let trimmedEmpty = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if trimmedEmpty {
            EmptyView()
        } else if isPersisted {
            Text("Saved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Text("Unsaved")
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var testResultLabel: some View {
        switch testResult {
        case .untested: EmptyView()
        case .success(let p) where p == provider:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed(let p, let msg) where p == provider:
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red).font(.callout)
        default: EmptyView()
        }
    }
}
```

- [ ] **Step 2: Add file to Xcode target, verify build, commit**

```bash
git add voxline/Settings/Components/APIKeyRow.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): extract reusable APIKeyRow view"
```

---

## Task 6: Add `CleanupSection` (provider + active key + disclosure)

Provider segmented picker on top, active provider's `APIKeyRow` directly under it, then a disclosure that reveals the inactive provider's `APIKeyRow`.

**Files:**
- Create: `voxline/Settings/Components/CleanupSection.swift`

- [ ] **Step 1: Write the implementation**

```swift
// voxline/Settings/Components/CleanupSection.swift
import SwiftUI

struct CleanupSection: View {

    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel

    @State private var showOtherKey: Bool = false
    @State private var anthropicRevealed = false
    @State private var openaiRevealed = false

    var body: some View {
        Section("Cleanup (AI)") {
            Picker("Provider", selection: $general.provider) {
                ForEach(LLMProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }

        keyRow(for: general.provider)

        DisclosureGroup(isExpanded: $showOtherKey) {
            keyRow(for: other(general.provider))
        } label: {
            Text("Also store \(other(general.provider).displayName) key")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func keyRow(for provider: LLMProvider) -> some View {
        switch provider {
        case .anthropic:
            APIKeyRow(
                title: "Anthropic",
                provider: .anthropic,
                key: $keys.anthropicKey,
                revealed: $anthropicRevealed,
                getKeyURL: URL(string: "https://console.anthropic.com/settings/keys")!,
                expectedPrefix: "sk-ant-",
                isPersisted: keys.isPersisted(.anthropic),
                testing: keys.testing,
                testResult: keys.testResult,
                lastError: keys.lastError,
                onCommit: { keys.commitAnthropic() },
                onTest: { Task { await keys.testConnection(.anthropic) } }
            )
        case .openai:
            APIKeyRow(
                title: "OpenAI",
                provider: .openai,
                key: $keys.openaiKey,
                revealed: $openaiRevealed,
                getKeyURL: URL(string: "https://platform.openai.com/api-keys")!,
                expectedPrefix: "sk-",
                isPersisted: keys.isPersisted(.openai),
                testing: keys.testing,
                testResult: keys.testResult,
                lastError: keys.lastError,
                onCommit: { keys.commitOpenAI() },
                onTest: { Task { await keys.testConnection(.openai) } }
            )
        }
    }

    private func other(_ p: LLMProvider) -> LLMProvider {
        p == .anthropic ? .openai : .anthropic
    }
}
```

- [ ] **Step 2: Add file to Xcode target, verify build, commit**

```bash
git add voxline/Settings/Components/CleanupSection.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): add CleanupSection fusing provider and key"
```

---

## Task 7: Rewrite `SettingsView` as a single page

Replace `TabView` with a `ScrollViewReader` + `Form` composition. Insert `SettingsStatusStrip` at the top, then one `Form` with sections in pipeline order. Manage the `MicLevelMonitor` lifecycle via `.onAppear` / `.onDisappear`. Surface Whisper download state inline in picker rows.

**Files:**
- Modify: `voxline/Settings/SettingsView.swift` (full rewrite)
- Delete: `voxline/Settings/GeneralSettingsView.swift`
- Delete: `voxline/Settings/APIKeysSettingsView.swift`

- [ ] **Step 1: Replace `SettingsView` contents**

```swift
// voxline/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {

    @Bindable var generalVM: GeneralSettingsViewModel
    @Bindable var apiKeysVM: APIKeysSettingsViewModel
    @State private var levelMonitor = MicLevelMonitor()
    @State private var status: SettingsStatusViewModel

    init(generalVM: GeneralSettingsViewModel, apiKeysVM: APIKeysSettingsViewModel) {
        self.generalVM = generalVM
        self.apiKeysVM = apiKeysVM
        _status = State(wrappedValue: SettingsStatusViewModel(general: generalVM, keys: apiKeysVM))
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SettingsStatusStrip(status: status) { anchor in
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                }

                Form {
                    Section("Hotkey") {
                        ChordRecorderView(chord: $generalVM.chord)
                    }
                    .id(SettingsAnchor.hotkey)

                    Section("Microphone") {
                        Picker("Input device", selection: $generalVM.audioInputDeviceUID) {
                            ForEach(generalVM.deviceRows) { row in
                                Text(row.label).tag(row.uid)
                            }
                        }
                        HStack(spacing: 8) {
                            Text("Live level").foregroundStyle(.secondary).font(.callout).frame(width: 80, alignment: .leading)
                            MicLevelMeter(monitor: levelMonitor)
                        }
                    }
                    .id(SettingsAnchor.microphone)

                    Section("Recognition") {
                        Picker("Whisper model", selection: $generalVM.whisperModel) {
                            ForEach(WhisperModel.allCases, id: \.self) { m in
                                let cached = TranscriptionService.isModelCached(m)
                                Text("\(m.displayName) — \(cached ? "✓ downloaded" : "to download · \(m.approxSizeMB) MB)")")
                                    .tag(m)
                            }
                        }
                        Text("Switching downloads the new model on demand.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .id(SettingsAnchor.recognition)

                    CleanupSection(general: generalVM, keys: apiKeysVM)
                        .id(SettingsAnchor.cleanup)

                    Section("Feedback") {
                        Toggle("Play sound on record start/stop", isOn: $generalVM.playHotkeySounds)
                    }
                    .id(SettingsAnchor.feedback)

                    HStack {
                        Spacer()
                        Button("Reset to Defaults") { generalVM.resetToDefaults() }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 560)
        }
        .onAppear {
            levelMonitor.preferredInputDeviceUID = generalVM.audioInputDeviceUID
            try? levelMonitor.start()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: generalVM.audioInputDeviceUID) { _, newValue in
            levelMonitor.stop()
            levelMonitor.preferredInputDeviceUID = newValue
            try? levelMonitor.start()
        }
    }
}
```

- [ ] **Step 2: Delete the now-redundant tab files**

```bash
git rm voxline/Settings/GeneralSettingsView.swift voxline/Settings/APIKeysSettingsView.swift
```

In Xcode, also remove their references from the `voxline` target if they linger (they should be removed by `git rm` plus a project sync, but verify ⌘B succeeds).

- [ ] **Step 3: Verify build and run the app**

```bash
xcodebuild build -project voxline.xcodeproj -scheme voxline -configuration Debug 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

Run the app from Xcode. Open Settings (⌘,). Verify:
- Status strip appears at top with the right "Ready / Setup needed" state.
- Speaking into the mic moves the level meter.
- Closing the Settings window stops the meter (system mic indicator should disappear).
- Switching provider keeps both keys; the disclosure label updates to the now-inactive provider.
- Switching Whisper model triggers a download as before.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/SettingsView.swift voxline.xcodeproj/project.pbxproj
git commit -m "feat(settings): single-page redesign with status strip and fused provider/key"
```

---

## Task 8: Update `voxlineApp.swift` (no-op check)

The existing call site (`voxlineApp.swift:27-31`) constructs `SettingsView(generalVM:apiKeysVM:)` — the signature is unchanged, so this should require no edits. Verify.

**Files:**
- Modify (only if needed): `voxline/voxlineApp.swift`

- [ ] **Step 1: Verify call site still compiles unchanged**

⌘B; if there's a compile error at `voxlineApp.swift:27-31`, fix the call site to match the new `SettingsView.init` signature. Otherwise no change.

- [ ] **Step 2: Commit (if changed)**

```bash
git add voxline/voxlineApp.swift
git commit -m "chore(settings): wire single-page SettingsView"
```

---

## Task 9: Manual smoke matrix

Add a short entry to `docs/insertion-smoke-matrix.md` covering the new Settings UI, then walk through it.

**Files:**
- Modify: `docs/insertion-smoke-matrix.md` (append a section)

- [ ] **Step 1: Append smoke matrix entry**

```markdown
## Settings (single-page redesign — 2026-05-10)

| State                           | Expected                                                                 |
|---------------------------------|--------------------------------------------------------------------------|
| Fully configured                | Strip = green ● Ready; mic / model / provider chips show ✓               |
| No active provider key          | Strip = orange ● Setup needed; provider chip has no ✓                    |
| Model not cached                | Strip = orange; recognition picker shows "to download · N MB"            |
| Switch provider with both keys  | Disclosure label updates to other provider; both keys retained           |
| Mic unplugged while open        | Meter goes flat; closing Settings stops engine (mic indicator clears)    |
| Window closed during recording  | Meter must already have stopped before recording started                 |
```

- [ ] **Step 2: Walk through each row by hand**

For any failures, file follow-up tasks rather than expanding this plan.

- [ ] **Step 3: Commit**

```bash
git add docs/insertion-smoke-matrix.md
git commit -m "docs: smoke matrix for Settings redesign"
```

---

## Self-Review

- **Spec coverage:**
  - Status strip — Tasks 2 + 3 ✓
  - Pipeline-ordered single page — Task 7 ✓
  - Provider+key fused with disclosure for inactive — Tasks 5 + 6 ✓
  - Live mic level meter — Tasks 1 + 4 + 7 ✓
  - Whisper download state inline in picker rows — Task 7 (uses existing `TranscriptionService.isModelCached`) ✓
  - Inline Test button next to key — Task 5 (now inside `APIKeyRow`) ✓
  - No persistence/keychain/LLM-behavior changes — preserved (existing VMs unchanged) ✓
  - Spec called for a `ModelInventoryService`; the plan instead reuses existing `TranscriptionService.isModelCached(_:)`. Equivalent behavior, less new code.
- **Placeholder scan:** No TBDs/TODOs. The one conditional clause (Task 2 Step 1's note about adapting the Keychain test double) points to specific existing test files for the engineer to mirror — that's a reference, not a placeholder, but flag for the reviewer.
- **Type consistency:** `SettingsStatusViewModel`, `SettingsAnchor`, `APIKeyRow`, `CleanupSection`, `MicLevelMonitor` — names match across all tasks. `keys` and `general` parameter names consistent across SettingsStatusViewModel and CleanupSection.
