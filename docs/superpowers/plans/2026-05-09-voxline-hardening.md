# voxline — Hardening Implementation Plan (Plan 5 of 5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the gaps that survive Plans 1–4 so voxline can ship to a real user. Surface every realistic failure as an actionable error rather than a silent freeze, give the wizard a way out when the model download fails, finish the API Keys settings parity, and run the manual smoke pass that turns "tests green" into "ship-ready."

**Architecture:** Six small fixes + one cleanup task + one final smoke document. No new subsystems. The biggest behavioral change is the wizard's model-download step gaining a Retry button and the recording pipeline learning to detect "samples but no audio level" as a microphone-permission failure rather than transcribing silence. Everything else is incremental polish on existing types.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSPanel`, `NSWorkspace`), `AVAudioEngine`, `WhisperKit`, Swift Testing. No new dependencies.

**Spec reference:** `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` (v0.2). This plan implements §10 phase 7 (Hardening: error states, mic-fail / no-key / network-fail messages, smoke pass) and addresses follow-ups flagged in Plan 4's final code review.

**Predecessors:** Plan 4 merged to `main` at `6ba4a27`. 139 tests pass on a fresh build. This plan starts from that point.

**Out of scope (future / v2):**
- AppCoordinator extraction into smaller coordinators (file size is acceptable; revisit if it crosses 500 lines).
- iCloud sync of modes/settings (spec §2 non-goal).
- Streaming transcription / live partial results (spec §2 non-goal).
- Voice-command parsing (spec §2 non-goal).
- Per-app overrides for clipboard restore timing (spec §11 risk; defer until a real user reports a regression).
- Non-US-keyboard virtual key code for synthetic Cmd+V (spec §11 known limitation).

---

## File Structure

Files this plan creates or modifies:

### New files

- **`voxline/Wizard/WizardModelDownloadView.swift`** — already exists; this plan adds a Retry button and an error path. (Modify, not create — listed here because the section gets significant new logic.)
- **`voxlineTests/CapturePipelineErrorTaxonomyTests.swift`** — new test suite asserting that each LLMError variant + transcribe failure + paste failure produces the expected `state.status = .error(...)` message and clears recording state cleanly.
- **`docs/superpowers/smoke/2026-05-XX-voxline-v1-smoke.md`** — manual smoke checklist (Task 9). Replace `XX` with the actual completion date.

### Modified files

- **`voxline/Wizard/WizardModelDownloadView.swift`** — render an error state with a Retry button when `state.status == .error(...)`. Retry calls a closure injected from `WizardRootView`.
- **`voxline/Wizard/WizardRootView.swift`** — pass a `retryDownload` closure into `WizardModelDownloadView`. Closure re-triggers the coordinator's `prepareIfNeeded(state:transcriber:)` flow.
- **`voxline/voxlineApp.swift`** — expose a coordinator method that the wizard can call to retry the model download. Track the eager-download Task so a settings-driven model swap doesn't double-fire it. Store the `observeHotkeyEnabled` Timer reference and invalidate it in `deinit`.
- **`voxline/Pipeline/CapturePipeline.swift`** — after `capture.takeSamples()`, detect the silent-capture pattern (`!samples.isEmpty && state.debugLastPeakLevel == 0`) and surface an actionable error rather than transcribing silence into an empty string. Tighten the LLM error path to forward `LLMError`'s `errorDescription` directly (already mostly done, but verify).
- **`voxline/Permissions/PermissionsService.swift`** — no contract change; just confirm the Accessibility check is reliable.
- **`voxline/Settings/APIKeysSettingsView.swift`** — add a "Test connection" button parallel to the wizard's, with the same do-the-actual-LLM-call pattern. Persists the result inline.
- **`voxline/Settings/APIKeysSettingsViewModel.swift`** — add `testResult: TestResult` state for the live Settings tab. Add `testConnection() async` method.
- **`voxline/Hotkey/HotkeyChord.swift`** — delete the unused `matches(flags:)` method. Update the test in `voxlineTests/HotkeyChordTests.swift` to remove the corresponding test case (the `Modifier.deviceMaskBit` API stays — it's load-bearing for `HotkeyMonitor`).

---

## Build & Test Cadence

Each task ends with `xcodebuild test` and a commit. From the repo root:

```bash
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
```

(Note `CODE_SIGNING_ALLOWED=NO` — required on this machine due to a pre-existing test-bundle code-signing quirk.)

Expect every task's tests to pass before committing.

---

## Tasks

### Task 1: WizardModelDownloadView retry button

The wizard's `Continue` button on the modelDownload step is gated on `state.status == .idle`. If `prepareIfNeeded` throws (network drops mid-download, disk fills, WhisperKit decompile error), `state.status` becomes `.error(...)` and stays there. The wizard window is non-closable, so the user is stuck — can't advance, can't dismiss. This task adds an error path with a Retry button.

**Files:**
- Modify: `voxline/Wizard/WizardModelDownloadView.swift`
- Modify: `voxline/Wizard/WizardRootView.swift`

- [ ] **Step 1: Update WizardModelDownloadView to render an error path**

```swift
// voxline/Wizard/WizardModelDownloadView.swift
import SwiftUI

struct WizardModelDownloadView: View {
    @Bindable var state: AppState
    let model: WhisperModel
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download speech recognition model").font(.title.bold())
            Text("\(model.displayName) — about \(model.approxSizeMB) MB. Runs entirely on your Mac; audio never leaves the device.")
                .foregroundStyle(.secondary)

            if case .error(let message) = state.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button("Retry") { onRetry() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ModelDownloadView(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 2: Update WizardRootView to inject the retry closure**

In `voxline/Wizard/WizardRootView.swift`, the view currently constructs:

```swift
case .modelDownload: WizardModelDownloadView(state: state, model: model)
```

Add an `onRetry` parameter to `WizardRootView` and forward it:

```swift
struct WizardRootView: View {
    @Bindable var vm: WizardViewModel
    @Bindable var state: AppState
    let model: WhisperModel
    let chord: HotkeyChord
    let onRetryDownload: () -> Void

    // ... (rest unchanged) ...

    @ViewBuilder
    private var content: some View {
        switch vm.currentStep {
        case .welcome: WizardWelcomeView()
        case .permissions: WizardPermissionsView()
        case .apiKey: WizardAPIKeyView(vm: vm.apiKeyVM)
        case .modelDownload: WizardModelDownloadView(state: state, model: model, onRetry: onRetryDownload)
        case .done: WizardDoneView(chord: chord)
        }
    }
}
```

- [ ] **Step 3: Update FirstRunWindowController to forward retry**

In `voxline/Wizard/FirstRunWindowController.swift`, change `show(...)` to take an `onRetry` closure and pass it to `WizardRootView`:

```swift
func show(
    state: AppState,
    settings: AppSettings,
    model: WhisperModel,
    chord: HotkeyChord,
    onRetryDownload: @escaping () -> Void,
    onComplete: @escaping () -> Void
) {
    // ... (existing code) ...
    let root = WizardRootView(
        vm: vm,
        state: state,
        model: model,
        chord: chord,
        onRetryDownload: onRetryDownload
    )
    // ... (rest unchanged) ...
}
```

- [ ] **Step 4: Wire AppCoordinator to expose retry**

In `voxline/voxlineApp.swift`'s `AppCoordinator.startWizardThenApp`, before calling `wizard.show(...)`, capture `transcriber` so the retry closure can call `prepareIfNeeded(state:transcriber:)` again:

```swift
private func startWizardThenApp(state: AppState, settings: AppSettings) {
    buildServices(state: state, settings: settings)
    guard let transcriber = self.transcriber else { return }

    let wizard = FirstRunWindowController()
    self.firstRunWindow = wizard
    wizard.show(
        state: state,
        settings: settings,
        model: settings.whisperModel,
        chord: settings.hotkeyChord,
        onRetryDownload: { [weak self, weak state] in
            guard let self, let state else { return }
            // Reset the error before retrying so the download progress UI shows again.
            state.status = TranscriptionService.isModelCached(settings.whisperModel)
                ? .preparingModel
                : .downloadingModel(progress: 0)
            self.prepareIfNeeded(state: state, transcriber: transcriber)
        },
        onComplete: { [weak self] in
            guard let self else { return }
            self.firstRunWindow = nil
            self.installHotkey(state: state, settings: settings)
        }
    )

    prepareIfNeeded(state: state, transcriber: transcriber)
}
```

- [ ] **Step 5: Build + run tests**

```
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
```

Expected: PASS — no test changes; UI is exercised manually.

- [ ] **Step 6: Commit**

```bash
git add voxline/Wizard/WizardModelDownloadView.swift voxline/Wizard/WizardRootView.swift voxline/Wizard/FirstRunWindowController.swift voxline/voxlineApp.swift
git commit -m "Add retry path to wizard model-download step"
```

---

### Task 2: CapturePipeline error taxonomy + tests

Audit `CapturePipeline.finalizeRecording` so each catch produces a clear, actionable error message. The existing code surfaces `LLMError.errorDescription` (good) but the transcription/paste catches use raw `error.localizedDescription` (often unhelpful, e.g., generic "The operation couldn't be completed."). This task tightens those paths and adds tests so the messages can't silently regress.

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Create: `voxlineTests/CapturePipelineErrorTaxonomyTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/CapturePipelineErrorTaxonomyTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineErrorTaxonomyTests {

    private func pipeline(
        transcribe: @escaping ([Float]) async throws -> String = { _ in "hello" },
        cleanup: @escaping (String, Mode) async throws -> String = { t, _ in t },
        inject: @escaping (String) async throws -> Void = { _ in }
    ) -> (CapturePipeline, AppState, FakeCapture) {
        let state = AppState()
        let capture = FakeCapture()
        capture.canned = [Float](repeating: 0.5, count: 16_000)
        let p = CapturePipeline(
            state: state,
            capture: capture,
            transcriber: FakeTranscriber(handler: transcribe),
            llm: FakeLLM(handler: cleanup),
            modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "Default", prompt: "p", model: nil, temperature: nil)]),
            frontmost: FakeFrontmost(),
            injector: FakeInjector(handler: inject)
        )
        return (p, state, capture)
    }

    @Test func missing_api_key_surfaces_actionable_error() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.missingAPIKey })
        p.startRecording()
        await p.finalizeRecording()
        guard case .error(let msg) = state.status else {
            Issue.record("Expected .error status, got \(state.status)"); return
        }
        #expect(msg.contains("Settings → API Keys"))
    }

    @Test func invalid_api_key_says_so() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.invalidAPIKey })
        p.startRecording(); await p.finalizeRecording()
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("rejected"))
    }

    @Test func network_error_includes_network_word() async {
        struct NetErr: Error { var localizedDescription: String { "offline" } }
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.network(NetErr()) })
        p.startRecording(); await p.finalizeRecording()
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("network"))
    }

    @Test func transcription_failure_surfaces_actionable_message() async {
        struct TranscribeFail: Error {}
        let (p, state, _) = pipeline(transcribe: { _ in throw TranscribeFail() })
        p.startRecording(); await p.finalizeRecording()
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("transcription"))
    }

    @Test func paste_failure_surfaces_actionable_message() async {
        struct PasteFail: Error {}
        let (p, state, _) = pipeline(inject: { _ in throw PasteFail() })
        p.startRecording(); await p.finalizeRecording()
        guard case .error(let msg) = state.status else { Issue.record("expected error"); return }
        #expect(msg.lowercased().contains("paste"))
    }

    @Test func error_path_clears_recording_state() async {
        let (p, state, _) = pipeline(cleanup: { _, _ in throw LLMError.missingAPIKey })
        p.startRecording(); await p.finalizeRecording()
        #expect(state.recordingStartedAt == nil)
        #expect(state.audioLevel == 0)
    }
}

// Fakes — light wrappers around the existing pipeline protocols.
@MainActor private final class FakeCapture: AudioCapturing {
    var canned: [Float] = []
    var onLevel: ((Float) -> Void)?
    var onTapCallback: ((Int) -> Void)?
    func start() throws {}
    func stop() {}
    func takeSamples() -> [Float] { defer { canned = [] }; return canned }
}

private struct FakeTranscriber: Transcribing {
    let handler: ([Float]) async throws -> String
    func transcribe(samples: [Float]) async throws -> String { try await handler(samples) }
}

private struct FakeLLM: LLMServing {
    let handler: (String, Mode) async throws -> String
    func cleanup(transcript: String, mode: Mode) async throws -> String {
        try await handler(transcript, mode)
    }
}

private struct FakeFrontmost: FrontmostAppProviding {
    func frontmostBundleID() -> String? { "com.example.app" }
}

private struct FakeInjector: ClipboardInjecting {
    let handler: (String) async throws -> Void
    func inject(_ text: String) async throws { try await handler(text) }
}
```

NOTE: the test file references protocols that already exist (`AudioCapturing`, `Transcribing`, `LLMServing`, `ModeResolving`, `FrontmostAppProviding`, `ClipboardInjecting` — see `voxline/Pipeline/PipelineProtocols.swift`). If a fake's signature doesn't match, fix the fake — don't change the protocol.

- [ ] **Step 2: Run tests to verify they fail**

Run the targeted test suite. Expected: FAIL — assertions don't match the current loose error messages.

- [ ] **Step 3: Tighten the error messages in CapturePipeline.finalizeRecording**

Replace the existing transcribe/paste catch blocks with prefixed forms:

```swift
// Transcription (line ~89)
} catch {
    return setError("Transcription failed. Try again or pick a different model in Settings → General.")
}

// Paste (line ~123)
} catch {
    return setError("Paste failed. The pasteboard may be locked by another app.")
}
```

The LLM error path (line 111) already forwards `LLMError.errorDescription`, which produces messages like "No API key configured. Open Settings → API Keys to set one." — verify; do NOT regress that.

- [ ] **Step 4: Run tests, expect PASS**

Expected: all 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineErrorTaxonomyTests.swift
git commit -m "Lock down CapturePipeline error message taxonomy"
```

---

### Task 3: Detect silent-mic captures (samples but zero peak level)

If the user has revoked microphone permission (or selected a muted USB device), `AVAudioEngine.start()` succeeds and the tap fires, but the buffers contain only zeros. The current pipeline transcribes silence and returns `""`, then quietly idles. The user sees nothing happen and assumes voxline is broken. This task surfaces the silent-capture case as an actionable error.

**Files:**
- Modify: `voxline/Pipeline/CapturePipeline.swift`
- Modify: `voxlineTests/CapturePipelineErrorTaxonomyTests.swift` (add a test)

- [ ] **Step 1: Add the failing test**

Append to the test file:

```swift
@Test func samples_with_zero_peak_surface_microphone_error() async {
    let state = AppState()
    let capture = FakeCapture()
    capture.canned = [Float](repeating: 0.0, count: 16_000) // 1 second of pure silence
    let p = CapturePipeline(
        state: state,
        capture: capture,
        transcriber: FakeTranscriber(handler: { _ in "" }),
        llm: FakeLLM(handler: { t, _ in t }),
        modes: ModeRouter(modes: [Mode(bundleID: "*", displayName: "D", prompt: "p", model: nil, temperature: nil)]),
        frontmost: FakeFrontmost(),
        injector: FakeInjector(handler: { _ in })
    )
    // Simulate the recording session: peak stays at 0 throughout.
    p.startRecording()
    state.debugLastPeakLevel = 0
    await p.finalizeRecording()
    guard case .error(let msg) = state.status else {
        Issue.record("Expected .error, got \(state.status)"); return
    }
    #expect(msg.lowercased().contains("microphone"))
}
```

- [ ] **Step 2: Run, expect FAIL**

Expected: FAIL — current code silently idles when transcript is empty.

- [ ] **Step 3: Add the silent-capture detector**

In `voxline/Pipeline/CapturePipeline.swift`, after `state.debugLastSampleCount = samples.count` (around line 75) and before the existing `samples.isEmpty` early-return, insert:

```swift
// Silent-capture detector: tap fired (samples non-empty) but no audio
// signal reached the converter (peak stayed at 0). Almost always means
// Microphone permission is denied or a muted device was selected.
if !samples.isEmpty && state.debugLastPeakLevel == 0 {
    return setError("No audio captured. Check that Microphone permission is granted and the input device isn't muted.")
}
```

The existing `samples.isEmpty` check stays (covers the case where the engine never started or the user released the chord before any tap callback fired).

- [ ] **Step 4: Run, expect PASS**

All 7 tests in the suite pass. Run the full suite to confirm no regressions:

```
xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet
```

- [ ] **Step 5: Commit**

```bash
git add voxline/Pipeline/CapturePipeline.swift voxlineTests/CapturePipelineErrorTaxonomyTests.swift
git commit -m "Detect silent mic captures and surface a microphone error"
```

---

### Task 4: Accessibility revocation watchdog

Currently, if the user grants Accessibility at startup but later revokes it from System Settings, the `CGEventTap` goes silent (the OS no longer delivers events to it) but voxline doesn't notice. The hold-to-talk chord stops working with no feedback. The Plan 4 `startInputMonitoringWatchdog` already polls every 2 seconds; this task extends it to flag revocation as an actionable error.

**Files:**
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Extend the watchdog**

In `voxline/voxlineApp.swift`, find `startInputMonitoringWatchdog(state:)`. The existing method polls Mic/AX/Input-Monitoring statuses and writes them to debug fields. Add error surfacing:

```swift
private func startInputMonitoringWatchdog(state: AppState) {
    inputMonitoringWatchdog?.invalidate()
    inputMonitoringWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak state, weak self] _ in
        Task { @MainActor in
            guard let state else { return }
            let perms = PermissionsService()
            let ax = perms.accessibilityStatus
            let im = perms.inputMonitoringStatus
            let mic = perms.microphoneStatus
            state.debugAccessibilityStatus = String(describing: ax)
            state.debugInputMonitoringStatus = String(describing: im)
            state.debugMicrophoneStatus = String(describing: mic)

            // Revocation detection: if the tap was installed but a required
            // permission has been revoked, the chord no longer works. Surface
            // an actionable error and tear down the tap so a future re-grant
            // can re-install it via startAccessibilityRetry.
            if let installed = self?.hotkeyMonitor?.isTapInstalled, installed {
                if ax != .granted || im != .granted {
                    state.status = .error("Accessibility or Input Monitoring permission was revoked. Re-grant it in System Settings → Privacy & Security; voxline will recover automatically.")
                    self?.hotkeyMonitor?.stop()
                    if let monitor = self?.hotkeyMonitor {
                        self?.startAccessibilityRetry(state: state, monitor: monitor)
                    }
                }
            }
        }
    }
}
```

The trick: when revocation is detected, this calls the existing `startAccessibilityRetry` loop which silently re-installs the tap when permissions return.

- [ ] **Step 2: Build + run all tests**

Expected: PASS — no test changes; behavior is exercised in manual smoke (Task 9).

- [ ] **Step 3: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "Detect mid-session permission revocation and recover"
```

---

### Task 5: Test connection in API Keys settings tab

The wizard has a "Test connection" button that issues a no-op LLM request to verify the key. The live Settings tab does not. A user who later rotates their key has no way to verify the new one short of attempting a real dictation. This task adds the test button to the Settings tab using the same client-direct pattern from `WizardAPIKeyView`.

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsViewModel.swift`
- Modify: `voxline/Settings/APIKeysSettingsView.swift`

- [ ] **Step 1: Add testResult + testConnection to APIKeysSettingsViewModel**

```swift
// In APIKeysSettingsViewModel.swift, add at top:
enum APIKeyTestResult: Equatable { case untested, success, failed(String) }

@Observable
@MainActor
final class APIKeysSettingsViewModel {
    // ... existing properties ...
    var testResult: APIKeyTestResult = .untested
    var testing: Bool = false

    // ... existing methods ...

    /// Issue a tiny no-op LLM call to verify the saved key.
    /// Persists the key first via save(), then dispatches the call.
    func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            try save()  // persist first so the keychain has the active value
            let key = (try? keychain.string(forKey: provider == .anthropic ? Keychain.Account.anthropic : Keychain.Account.openai)) ?? ""
            guard !key.isEmpty else {
                testResult = .failed("No API key set.")
                return
            }
            let client: LLMClient = provider == .anthropic
                ? AnthropicClient(apiKey: key)
                : OpenAIClient(apiKey: key)
            let request = LLMRequest(
                model: provider.defaultModel,
                systemPrompt: "Return the word 'ok' and nothing else.",
                userPrompt: "ping",
                temperature: 0
            )
            _ = try await client.cleanup(request)
            testResult = .success
        } catch let err as LLMError {
            testResult = .failed(err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }
}
```

(The `keychain` field is currently `private`. If your access requires it to be readable for the test method, that's fine — `testConnection` is a method on the same class so it has access.)

- [ ] **Step 2: Add the button + result label to APIKeysSettingsView**

In `voxline/Settings/APIKeysSettingsView.swift`, after the existing Save button HStack, add:

```swift
HStack {
    Button("Test connection") { Task { await vm.testConnection() } }
        .disabled(vm.testing || activeKey.isEmpty)
    if vm.testing { ProgressView().controlSize(.small) }
    Spacer()
    testResultLabel
}

// And add as a private computed property:
@ViewBuilder
private var testResultLabel: some View {
    switch vm.testResult {
    case .untested: EmptyView()
    case .success: Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
    case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
    }
}

// And helper to read the active key:
private var activeKey: String {
    vm.provider == .anthropic ? vm.anthropicKey : vm.openaiKey
}
```

- [ ] **Step 3: Build**

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/APIKeysSettingsViewModel.swift voxline/Settings/APIKeysSettingsView.swift
git commit -m "Add Test connection button to API Keys settings tab"
```

---

### Task 6: Concurrent prepareModel guard

When the user opens Settings via `Cmd+,` mid-wizard and changes the Whisper model, `GeneralSettingsApplier.apply` fires a `Task` that calls `prepareModel`. If the wizard's eager `prepareIfNeeded` is still mid-download for the OLD model, both tasks race against `WhisperKit.download` for different variants. This task adds a single-flight guard via a stored Task on AppCoordinator.

**Files:**
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Add a stored Task<Void, Never>? on AppCoordinator**

Near the other private properties:

```swift
private var modelPrepTask: Task<Void, Never>?
```

- [ ] **Step 2: Centralize model-prep into a single helper**

Replace the existing `GeneralSettingsApplier.apply`'s model-swap block AND `prepareIfNeeded`'s background Task with calls to a new shared method:

```swift
private func prepareModelIfNeeded(state: AppState, transcriber: TranscriptionService) {
    modelPrepTask?.cancel()
    modelPrepTask = Task { @MainActor [weak self, weak state, weak transcriber] in
        guard let state, let transcriber else { return }
        do {
            if !TranscriptionService.isModelCached(transcriber.model) {
                try await transcriber.prepareModel { progress in
                    Task { @MainActor in
                        if case .downloadingModel = state.status {
                            state.status = .downloadingModel(progress: progress)
                        }
                    }
                }
                if case .downloadingModel = state.status {
                    state.status = .preparingModel
                }
            }
            try await transcriber.prewarm()
            if case .preparingModel = state.status {
                state.status = .idle
            }
            self?.firstRunWindow?.close()  // safe no-op if not first run
        } catch {
            state.status = .error("Model setup failed: \(error.localizedDescription). Try Retry or relaunch voxline.")
        }
        self?.modelPrepTask = nil
    }
}
```

Then replace the two existing call sites:
1. `prepareIfNeeded(state:transcriber:)` becomes a thin wrapper that sets the initial status (downloading/preparing) and calls `prepareModelIfNeeded`.
2. `GeneralSettingsApplier.apply`'s model-swap branch calls `prepareModelIfNeeded` instead of spawning its own Task.

The `modelPrepTask?.cancel()` ensures only one prep is ever in flight; cancelling a download mid-flight is safe (WhisperKit handles the partial state).

- [ ] **Step 3: Build + test**

Expected: PASS — no test changes; behavior is exercised in manual smoke.

- [ ] **Step 4: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "Single-flight Whisper model preparation"
```

---

### Task 7: observeHotkeyEnabled timer cleanup + AppCoordinator deinit

The `observeHotkeyEnabled` timer is created with no stored reference and never invalidated. AppCoordinator is owned by AppDelegate and lives for the app's lifetime, so the leaked timer is harmless in production — but it's a hygiene issue and would matter if AppCoordinator ever became transient (e.g., for a second-window architecture).

**Files:**
- Modify: `voxline/voxlineApp.swift`

- [ ] **Step 1: Store the timer and invalidate in deinit**

Add a stored property:

```swift
private var hotkeyEnabledObserver: Timer?
```

Update `observeHotkeyEnabled(state:)` to assign to it (and invalidate first to be idempotent):

```swift
private func observeHotkeyEnabled(state: AppState) {
    hotkeyEnabledObserver?.invalidate()
    hotkeyEnabledObserver = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self, weak state] _ in
        // ... existing body unchanged ...
    }
}
```

Add a deinit:

```swift
deinit {
    hotkeyEnabledObserver?.invalidate()
    inputMonitoringWatchdog?.invalidate()
    accessibilityRetryTimer?.invalidate()
    modelPrepTask?.cancel()
}
```

(Note: deinit can't be `@MainActor`, so it must touch only stored properties — Timer.invalidate() and Task.cancel() are both safe to call from any thread.)

- [ ] **Step 2: Build + test**

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "Track and clean up AppCoordinator timers in deinit"
```

---

### Task 8: Remove unused HotkeyChord.matches(flags:)

The `matches(flags: CGEventFlags) -> Bool` method on `HotkeyChord` is unused outside its own test. The hot path (`HotkeyMonitor.tapCallback`) extracts the two booleans separately because the state machine needs them independently to distinguish `armed` vs `recording`. Keeping a public unused API is dead code; deleting it is cheaper than retaining it for hypothetical future callers.

**Files:**
- Modify: `voxline/Hotkey/HotkeyChord.swift`
- Modify: `voxlineTests/HotkeyChordTests.swift`

- [ ] **Step 1: Remove the method + its test**

In `HotkeyChord.swift`, delete the `matches(flags:)` method (and its docstring). Keep `Modifier.deviceMaskBit` — that's load-bearing.

In `HotkeyChordTests.swift`, delete the `chord_matches_when_both_modifiers_down` test.

- [ ] **Step 2: Run tests**

The remaining 3 tests (default, displayName, codable) should pass.

- [ ] **Step 3: Commit**

```bash
git add voxline/Hotkey/HotkeyChord.swift voxlineTests/HotkeyChordTests.swift
git commit -m "Remove unused HotkeyChord.matches(flags:)"
```

---

### Task 9: Manual smoke pass + acceptance document

The final step before declaring v1 ready. Walk the smoke checklist on a real Mac with real apps, document the outcome, and tag the result.

**Files:**
- Create: `docs/superpowers/smoke/2026-05-XX-voxline-v1-smoke.md` (replace `XX` with today's date)

- [ ] **Step 1: Write the smoke document**

```markdown
# voxline v1 Smoke Pass

**Date:** 2026-05-XX
**Builder:** [your name]
**Build:** main @ <SHA>
**Hardware:** [model + chip]
**macOS version:** [e.g. 26.4]

## Setup smoke (fresh install)

- [ ] Delete `~/Library/Containers/com.voxline.voxline/`. Build + Run from Xcode.
- [ ] Wizard appears centered, non-closable.
- [ ] Welcome step → Continue.
- [ ] Permissions step: grant Microphone (TCC dialog), Accessibility (open System Settings + toggle), Input Monitoring (TCC dialog). Each row's badge flips green within ~2s of granting. Continue button enables.
- [ ] API Key step: paste a real key → Test connection → ✓ Connected appears.
- [ ] Model Download step: progress bar advances. Continue button disabled until status = idle.
- [ ] Done step shows the configured chord (default: Left Ctrl + Left Option). Click "Get started".
- [ ] Wizard closes; menu icon goes to mic.
- [ ] Quit. Relaunch. Wizard does not appear.

## Hotkey + dictation smoke

In each target app:
- [ ] **TextEdit** (new untitled doc): hold Left Ctrl + Left Option, say "Hello uh world", release. "Hello world." (or close) pastes. No leading/trailing modifier chatter.
- [ ] **Slack** (DM compose): same chord, dictate. Pastes cleanly. Conversation isn't accidentally Cmd-Sent.
- [ ] **Apple Mail** (compose): dictate. Output is professionally formatted (Mail mode prompt fires).
- [ ] **Cursor** (any file): dictate "let x equal 42". Output preserves code-adjacent style (Cursor mode prompt: minimal cleanup).
- [ ] **Safari** (search bar): dictate. Pastes; no UA-input weirdness.
- [ ] **Chrome** (textarea on any site): dictate. Pastes.
- [ ] **Notes**: dictate. Pastes.
- [ ] **Terminal** (or iTerm): dictate. Pastes (no shell interpretation).

## Settings smoke

- [ ] **General → Hotkey:** Record chord = Right Cmd + Right Shift. Save. Hold new chord in TextEdit, dictate. Cleaned text pastes. Restore default chord.
- [ ] **General → Microphone:** plug in a USB mic. Settings → General. Picker lists it. Pick it. Save. Dictate. Confirm via System Settings → Sound that voxline used the picked mic (or confirm by speaking into only the external mic).
- [ ] **General → Speech recognition model:** Switch to small.en. Save. First dictation pays a download (progress visible in menu bar). Subsequent dictations are fast. Restore large-v3-turbo.
- [ ] **API Keys:** Click Test connection with the active key → ✓. Replace key with garbage → Test → ✗ "API key was rejected by the provider." (or similar). Restore key.
- [ ] **Modes:** Click "Add from running apps" → pick TextEdit. Edit prompt to "ALL CAPS THE TRANSCRIPT." Save. Dictate in TextEdit; output is uppercase. Delete the TextEdit mode. Save. Dictate again; falls back to `*` mode (lowercase).

## Pause/Resume smoke

- [ ] Menu bar → Pause voxline. Hold the chord; nothing happens (no pill, no status change).
- [ ] Menu bar → Resume voxline. Chord works again on the next press.

## Error-state smoke

- [ ] **No-key:** Settings → API Keys → clear both keys → Save. Dictate. Menu icon goes red; clicking shows the "Open Settings → API Keys" message. Restore a key. Next dictation succeeds.
- [ ] **No-network:** Disable Wi-Fi. Dictate. Menu shows a network error within 5–30s. Re-enable Wi-Fi. Next dictation succeeds.
- [ ] **Mic-denied:** System Settings → Privacy & Security → Microphone → revoke voxline. Dictate. Menu shows "No audio captured. Check Microphone permission..." Restore mic permission. Next dictation succeeds.
- [ ] **Accessibility-revoked:** System Settings → revoke Accessibility for voxline. Within 2s the menu shows the revocation error. Restore. Within 2s the chord works again (no relaunch needed).
- [ ] **Wizard download retry:** with a fresh install, disable Wi-Fi at the Permissions step. Continue to Model Download. Error message appears with Retry button. Re-enable Wi-Fi. Click Retry. Download resumes. Continue to Done.

## Clipboard preservation

- [ ] Copy "MARKER1" in TextEdit. Dictate "hello". After paste completes, ⌘V → "MARKER1" returns.
- [ ] Copy a small image (Preview → Edit → Copy). Dictate. After paste, ⌘V into another app → image returns.
- [ ] Copy a file from Finder (which uses promised types). Dictate. Expect: voxline refuses to clobber and surfaces an error rather than silently destroying the clipboard.

## Outcome

- Pass / Fail / Pass-with-issues: ___
- Issues found (file, severity, repro): ___
- Tag created: `voxline-v1-shipped` at <SHA>
```

- [ ] **Step 2: Walk the checklist**

Run through every item on a real Mac. Record outcomes and any issues found. If issues are minor, file follow-up tasks; if major, do NOT tag and instead add fix tasks to a Plan 6.

- [ ] **Step 3: Commit the document**

```bash
git add docs/superpowers/smoke/2026-05-XX-voxline-v1-smoke.md
git commit -m "Add v1 smoke pass results"
```

- [ ] **Step 4: Tag**

After all items pass:

```bash
git tag voxline-v1-shipped
```

---

## Manual Verification (Plan 5 acceptance)

Plan 5 is "done" when:

1. All 8 implementation tasks (1–8) have shipped to `main` with green tests.
2. The smoke document (Task 9) is filled in with all checkboxes ticked.
3. Tag `voxline-v1-shipped` exists at the smoke-pass SHA.

If any smoke item fails, the relevant fix lands either in this plan (re-do affected task) or a Plan 6.

---

## Self-Review

**Spec coverage:**

- §10 phase 7 (Hardening: error states, mic-fail / no-key / network-fail messages, smoke pass) — Tasks 2, 3, 4, 9 ✓
- Plan 4 final-review carry-forwards:
  - Wizard download deadlock — Task 1 ✓
  - Concurrent prepareModel race — Task 6 ✓
  - observeHotkeyEnabled timer cleanup — Task 7 ✓
  - HotkeyChord.matches dead code — Task 8 ✓
  - API Keys "Test connection" parity — Task 5 ✓

**Placeholder scan:**

- "Replace `XX` with today's date" in Task 9's filename is a real instruction the implementer must execute, not a TBD.
- No "TBD" / "implement later" / "similar to" anywhere in the body.

**Type consistency:**

- `APIKeyTestResult` (Task 5) parallels the existing `WizardAPIKeyView.TestResult` enum (different scope, same shape — wizard's is private to the view).
- `prepareModelIfNeeded` (Task 6) supersedes the existing two callers but does not change their public surface.
- `onRetryDownload: () -> Void` threading through `WizardRootView` and `FirstRunWindowController` (Task 1) is a clean additive parameter.

**Risks for the implementer:**

- **Task 6 is the riskiest** — the refactor of `prepareIfNeeded` + `GeneralSettingsApplier.apply` into a single shared method touches the most-trafficked code path on launch. Run the full test suite after the refactor and manually verify a fresh install still sees the wizard model-download step animate.
- **Task 4's revocation watchdog** depends on `PermissionsService.accessibilityStatus` being honest. `AXIsProcessTrusted()` returns true based on the app's TCC entry, which can lag a few seconds after the user toggles in System Settings. The 2s polling should be slow enough to avoid flapping; if you see flapping in smoke, increase to 3s.
- **Task 1's retry closure** captures `transcriber` as a strong reference into the wizard's lifetime. That's fine — `transcriber` is owned by AppCoordinator which lives forever — but if Plan 6 ever extracts AppCoordinator into a smaller object that can deallocate, this capture needs `[weak transcriber]`.

---

## Plan complete and saved to `docs/superpowers/plans/2026-05-09-voxline-hardening.md`.
