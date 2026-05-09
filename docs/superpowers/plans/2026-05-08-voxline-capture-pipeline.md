# voxline — Capture Pipeline Implementation Plan (Plan 2 of 4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the full hold-to-talk capture pipeline end-to-end. Hold **Left Ctrl + Left Option**, talk, release; raw audio is captured locally, resampled to Whisper's input format, transcribed via WhisperKit, and the transcript is shown in a debug window. No LLM cleanup or paste yet — those land in Plan 3.

**Architecture:** Three-stage pipeline (`HotkeyMonitor` → `AudioCaptureService` → `TranscriptionService`) coordinated by a `CapturePipeline` actor. The hotkey state machine is split out as a pure-logic component (`HotkeyStateMachine`) so it can be exhaustively unit-tested without `CGEventTap`. The recording pill is a click-through `NSPanel`-hosted SwiftUI view, driven by `AppState.audioLevel`. WhisperKit handles model download + Core ML inference.

**Tech Stack:** Swift 5, SwiftUI, AppKit (`NSPanel`, `NSWorkspace`), `CGEventTap` (CoreGraphics/Carbon), `AVAudioEngine` + `AVAudioConverter`, **WhisperKit** (`argmaxinc/WhisperKit` SPM package).

**Spec reference:** `docs/superpowers/specs/2026-05-08-voxline-dictation-design.md` (v0.2) — primarily §4.1 (Hotkey + Audio Capture), §4.2 (Local Transcription), §6.2 (Floating recording pill).

**Predecessors:** Plan 1 (Foundation) is complete at tag `foundation-complete`. This plan starts from a clean main with 11 tests passing.

---

## File Structure

Files this plan creates or modifies:

### New files

- **`voxline/Hotkey/HotkeyStateMachine.swift`** — pure state machine (`idle/armed/recording/finalizing`). Inputs are events; outputs are effect descriptions. No `CGEventTap`, no timers — fully unit-testable.
- **`voxline/Hotkey/HotkeyMonitor.swift`** — owns `CGEventTap`, feeds `flagsChanged` events into the state machine, runs the four fail-safes (max duration, tap re-enable, periodic `flagsState` reconciliation, app-deactivation guard). Exposes a delegate or async stream for "recording started/stopped" events.
- **`voxline/Audio/AudioFormat.swift`** — Whisper input format constants (16 kHz mono Float32) and conversion math (sample-count helpers, level-meter calculation from PCM).
- **`voxline/Audio/AudioCaptureService.swift`** — wraps `AVAudioEngine`. Installs an input tap in hardware format, runs `AVAudioConverter` to Whisper's format, accumulates samples in memory, exposes a `levels` callback for the waveform pill.
- **`voxline/Transcription/WhisperModel.swift`** — enum of supported model variants (`largeV3Turbo`, `smallEn`) with WhisperKit identifier strings + size estimates.
- **`voxline/Transcription/TranscriptionService.swift`** — wraps WhisperKit. Lazy-loads + downloads the active model on first call. Async `transcribe(samples: [Float]) async throws -> String`.
- **`voxline/UI/RecordingPillView.swift`** — SwiftUI floating pill (waveform → spinner) driven by `AppState`.
- **`voxline/UI/RecordingPillWindow.swift`** — `NSPanel` host that makes the pill click-through, non-activating, and screen-spanning-aware.
- **`voxline/UI/DebugTranscriptWindow.swift`** — Plan-2-only verification UI: a small window showing the last few transcripts. Marked with a `// PLAN 2 ONLY — REMOVED IN PLAN 3` banner so it gets deleted when paste lands.
- **`voxline/Pipeline/CapturePipeline.swift`** — actor coordinating the three stages. Owns `HotkeyMonitor`, `AudioCaptureService`, `TranscriptionService`, and a reference to `AppState`. Translates hotkey events → audio capture → transcription → state updates.
- **`voxline/MenuBar/MenuBarIcon.swift`** — extracted from current `MenuBarController.swift`. (Plan 1 P2 carry-forward.)
- **`voxline/MenuBar/MenuBarContent.swift`** — extracted from current `MenuBarController.swift`. (Plan 1 P2 carry-forward.)

### Modified files

- **`voxline/AppState.swift`** — extend with `audioLevel: Float`, `lastTranscript: String?`, `recordingStartedAt: Date?`. (Plan 1 P2 carry-forward — `AppState` was too thin for Plan 2.)
- **`voxline/voxlineApp.swift`** — instantiate `CapturePipeline` at launch; show `RecordingPillWindow` and `DebugTranscriptWindow` scenes.
- **`voxline.xcodeproj/project.pbxproj`** — add WhisperKit SPM dependency.

### Deleted

- **`voxline/MenuBar/MenuBarController.swift`** — split into `MenuBarIcon.swift` + `MenuBarContent.swift` per the carry-forward.

### New test files

- **`voxlineTests/HotkeyStateMachineTests.swift`** — exhaustive coverage of state transitions, fail-safes, partial chord, modifier rollover.
- **`voxlineTests/AudioFormatTests.swift`** — sample-count math, level calculation.
- **`voxlineTests/WhisperModelTests.swift`** — enum identifier mappings.
- **`voxlineTests/CapturePipelineTests.swift`** — pipeline coordinator with mocked services.

The hotkey logic is split (state machine vs. monitor) specifically so the difficult-to-test event-loop code is thin and the testable pure logic is fat. Same approach for audio: math/format helpers are isolated from the AVFoundation runtime.

---

## Task 1: Plan 1 carry-forwards (split MenuBar files, extend AppState)

**Why first:** These changes are cheap, decouple from Plan 1, and Plan 2's downstream tasks depend on `AppState` having the new fields. Doing them now means later tasks don't need to touch `AppState.swift` repeatedly.

**Files:**
- Create: `voxline/MenuBar/MenuBarIcon.swift`
- Create: `voxline/MenuBar/MenuBarContent.swift`
- Delete: `voxline/MenuBar/MenuBarController.swift`
- Modify: `voxline/AppState.swift`
- Modify: `voxlineTests/AppStateTests.swift`

- [ ] **Step 1: Create `voxline/MenuBar/MenuBarIcon.swift`**

```swift
import Foundation

/// Maps AppStatus → SF Symbol name for the menu bar icon.
enum MenuBarIcon {
    static func symbolName(for status: AppStatus) -> String {
        switch status {
        case .idle:        return "mic"
        case .recording:   return "mic.fill"
        case .thinking:    return "ellipsis.circle"
        case .error:       return "mic.slash"
        }
    }
}
```

- [ ] **Step 2: Create `voxline/MenuBar/MenuBarContent.swift`**

```swift
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        Button("Settings…") {
            openSettings()
            // openSettings doesn't activate the app on its own; ensure the
            // settings window comes to the front.
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 3: Delete the old combined file**

```bash
rm voxline/MenuBar/MenuBarController.swift
```

- [ ] **Step 4: Extend `voxline/AppState.swift`**

Replace the entire file contents with:

```swift
import Foundation
import Observation

enum AppStatus: Equatable {
    case idle
    case recording
    case thinking
    case error(String)
}

@Observable
final class AppState {
    var status: AppStatus = .idle

    /// Live mic input level while recording, in [0, 1]. Used by the
    /// recording-pill waveform. Updated from the audio thread.
    var audioLevel: Float = 0

    /// Most recently produced transcript. Plan 2 displays this in the
    /// debug window; Plan 3 will paste it instead.
    var lastTranscript: String?

    /// Wall-clock time the current recording began, or nil while idle.
    /// Used for the pill's elapsed-time display and for the max-duration fail-safe.
    var recordingStartedAt: Date?
}
```

- [ ] **Step 5: Add tests for the new fields**

Replace `voxlineTests/AppStateTests.swift` entirely with:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct AppStateTests {

    @Test func newStateStartsIdle() {
        let state = AppState()
        #expect(state.status == .idle)
    }

    @Test func canTransitionThroughStatusEnum() {
        let state = AppState()
        state.status = .recording
        #expect(state.status == .recording)
        state.status = .thinking
        #expect(state.status == .thinking)
        state.status = .error("mic unavailable")
        #expect(state.status == .error("mic unavailable"))
        state.status = .idle
        #expect(state.status == .idle)
    }

    @Test func newStateHasZeroAudioLevel() {
        #expect(AppState().audioLevel == 0)
    }

    @Test func newStateHasNoTranscript() {
        #expect(AppState().lastTranscript == nil)
    }

    @Test func newStateHasNoRecordingStartedAt() {
        #expect(AppState().recordingStartedAt == nil)
    }
}
```

- [ ] **Step 6: Build + test**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` with **14 tests** (3 AppPaths + 5 AppState + 2 PermissionsService + 4 MenuBarIcon).

- [ ] **Step 7: Commit**

```bash
git add voxline/MenuBar/ voxline/AppState.swift voxlineTests/AppStateTests.swift
git rm voxline/MenuBar/MenuBarController.swift 2>/dev/null || true
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Plan 1 carry-forwards: split MenuBar files, expand AppState

- Split MenuBarController.swift into MenuBarIcon.swift + MenuBarContent.swift
  (Plan 1 P2 carry-forward — file name didn't match contents).
- Add audioLevel / lastTranscript / recordingStartedAt to AppState so Plan 2
  capture pipeline has the state fields it needs without round-trip refactors.
- Add 3 tests covering the new fields' default values."
```

---

## Task 2: Add WhisperKit Swift Package dependency

**Why now:** Several downstream tasks need WhisperKit imports. Adding the dependency early means we can validate it links cleanly before depending on it.

**Files:**
- Modify: `voxline.xcodeproj/project.pbxproj`
- Possibly create: `voxline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (Xcode generates this automatically on first resolve)

- [ ] **Step 1: Edit `voxline.xcodeproj/project.pbxproj` to add the SPM package**

Add four sections to the pbxproj. Use UUID prefix `D1` for these new objects to keep them visually distinct.

**(a)** Add a new `XCRemoteSwiftPackageReference` section near the end of the file, before the final `XCConfigurationList section` block:

```
/* Begin XCRemoteSwiftPackageReference section */
		D100000000000000000000A1 /* XCRemoteSwiftPackageReference "WhisperKit" */ = {
			isa = XCRemoteSwiftPackageReference;
			repositoryURL = "https://github.com/argmaxinc/WhisperKit";
			requirement = {
				kind = upToNextMajorVersion;
				minimumVersion = 0.10.0;
			};
		};
/* End XCRemoteSwiftPackageReference section */
```

**(b)** Add an `XCSwiftPackageProductDependency` section:

```
/* Begin XCSwiftPackageProductDependency section */
		D100000000000000000000A2 /* WhisperKit */ = {
			isa = XCSwiftPackageProductDependency;
			package = D100000000000000000000A1 /* XCRemoteSwiftPackageReference "WhisperKit" */;
			productName = WhisperKit;
		};
/* End XCSwiftPackageProductDependency section */
```

**(c)** Reference the package in the project's `PBXProject` block. Find:

```
		A100000000000000000000A1 /* Project object */ = {
			isa = PBXProject;
			...
			targets = (
				A100000000000000000000A5 /* voxline */,
				B100000000000000000000A2 /* voxlineTests */,
			);
		};
```

…and add a `packageReferences` line just before `targets = (...)`:

```
			packageReferences = (
				D100000000000000000000A1 /* XCRemoteSwiftPackageReference "WhisperKit" */,
			);
```

**(d)** Reference the product in the voxline app target's `packageProductDependencies`. The voxline target block currently has `packageProductDependencies = (\n\t\t\t);` (empty). Replace with:

```
			packageProductDependencies = (
				D100000000000000000000A2 /* WhisperKit */,
			);
```

**(e)** Add a `PBXBuildFile` so WhisperKit links into the Frameworks build phase. Find the `PBXBuildFile section` (or create one if absent — a project with no PBXBuildFiles yet won't have this section). Add:

```
/* Begin PBXBuildFile section */
		D100000000000000000000A3 /* WhisperKit in Frameworks */ = {isa = PBXBuildFile; productRef = D100000000000000000000A2 /* WhisperKit */; };
/* End PBXBuildFile section */
```

**(f)** Add the build file to the voxline app target's Frameworks build phase. Find:

```
		A100000000000000000000A8 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
```

…and replace the empty `files = ( );` with:

```
			files = (
				D100000000000000000000A3 /* WhisperKit in Frameworks */,
			);
```

- [ ] **Step 2: Resolve the package**

```bash
xcodebuild -project voxline.xcodeproj -resolvePackageDependencies 2>&1 | tail -5
```

Expected: package resolves, `Package.resolved` is generated under `voxline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`. If you see `error: missing package product 'WhisperKit'` or "Could not resolve" — pbxproj edits in Step 1 are wrong.

- [ ] **Step 3: Verify the build still works (without using WhisperKit yet)**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. WhisperKit downloads (first time can take ~30s for SPM checkout) and links. If the build fails complaining about deployment target compatibility, set `MACOSX_DEPLOYMENT_TARGET = 14.0` is already in our project — WhisperKit requires macOS 14+ minimum.

- [ ] **Step 4: Smoke-test the import**

Add a temporary file `voxline/WhisperKitImport.swift` to confirm the module is importable:

```swift
import WhisperKit
import Foundation

// Smoke test only — confirms WhisperKit links. Removed in Task 6.
@MainActor
private enum WhisperKitImportSmokeTest {
    static let supportedTaskTypes: [DecodingTask] = [.transcribe, .translate]
}
```

Build again:

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. If `DecodingTask` doesn't exist in the version of WhisperKit you got (API has shifted versions), simplify the smoke file to just `import WhisperKit` with an empty body. The goal is "the import resolves," nothing more.

- [ ] **Step 5: Run the test suite**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **` with 14 tests still passing.

- [ ] **Step 6: Commit**

```bash
git add voxline.xcodeproj/ voxline/WhisperKitImport.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add WhisperKit SPM dependency

Adds argmaxinc/WhisperKit (>=0.10.0, <2.0.0) as a Swift Package dependency
of the voxline app target. Includes a temporary import smoke-test file
that's removed in Task 6 when TranscriptionService lands."
```

---

## Task 3: HotkeyStateMachine (pure logic, TDD)

**Why pure logic first:** Hotkey state has many edge cases (partial chord, modifier rollover, missed releases). Testing this against `CGEventTap` is impractical; testing against an event-driven state machine is straightforward. The `HotkeyMonitor` in Task 4 just translates real OS events into events for this state machine.

**Files:**
- Create: `voxline/Hotkey/HotkeyStateMachine.swift`
- Create: `voxlineTests/HotkeyStateMachineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `voxlineTests/HotkeyStateMachineTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct HotkeyStateMachineTests {

    // MARK: - Helpers

    private func machine() -> HotkeyStateMachine {
        HotkeyStateMachine()
    }

    /// Convenience: fire flagsChanged with the named modifiers held.
    private func leftCtrl(_ down: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(leftCtrlDown: down, leftOptDown: false)
    }
    private func leftOpt(_ down: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(leftCtrlDown: false, leftOptDown: down)
    }
    private func chord(_ ctrl: Bool, _ opt: Bool) -> HotkeyStateMachine.Input {
        .flagsChanged(leftCtrlDown: ctrl, leftOptDown: opt)
    }

    // MARK: - Initial state

    @Test func startsIdle() {
        #expect(machine().state == .idle)
    }

    // MARK: - Single modifier transitions

    @Test func leftCtrlDownAlone_armsButDoesNotRecord() {
        let m = machine()
        let outputs = m.handle(leftCtrl(true))
        #expect(m.state == .armed)
        #expect(outputs.isEmpty, "no recording outputs while only one modifier is held")
    }

    @Test func leftCtrlReleasedFromArmed_returnsToIdle() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        let outputs = m.handle(leftCtrl(false))
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    // MARK: - Chord enters recording

    @Test func bothModifiersDown_startsRecording() {
        let m = machine()
        _ = m.handle(leftCtrl(true))
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .recording)
        #expect(outputs == [.startRecording])
    }

    @Test func releasingEitherModifier_finalizesRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(leftCtrl(true))  // Opt released
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    @Test func releasingOtherModifier_finalizesRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(leftOpt(true))  // Ctrl released
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    // MARK: - Fail-safes

    @Test func maxDurationElapsed_finalizesIfRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(.maxDurationElapsed)
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    @Test func maxDurationElapsed_isNoOpIfNotRecording() {
        let m = machine()
        let outputs = m.handle(.maxDurationElapsed)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    @Test func appDeactivated_finalizesIfRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(.appDeactivated)
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    @Test func tapDisabled_finalizesIfRecording() {
        let m = machine()
        _ = m.handle(chord(true, true))
        let outputs = m.handle(.tapDisabled)
        #expect(m.state == .finalizing)
        #expect(outputs == [.finalizeRecording])
    }

    // MARK: - Finalizing → idle

    @Test func recordingFinished_returnsToIdle() {
        let m = machine()
        _ = m.handle(chord(true, true))
        _ = m.handle(leftCtrl(true))  // -> finalizing
        let outputs = m.handle(.recordingFinished)
        #expect(m.state == .idle)
        #expect(outputs.isEmpty)
    }

    // MARK: - Edge cases

    @Test func chordPressedFromIdleWithoutInterimArmedState_isAccepted() {
        // If both modifiers go down in the same event (tight rollover),
        // skip the armed step and go straight to recording.
        let m = machine()
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .recording)
        #expect(outputs == [.startRecording])
    }

    @Test func newFlagsChangedDuringFinalizing_isIgnored() {
        // While we're waiting for transcription to finish, additional
        // modifier events should not start a new recording.
        let m = machine()
        _ = m.handle(chord(true, true))
        _ = m.handle(leftCtrl(true))  // -> finalizing
        let outputs = m.handle(chord(true, true))
        #expect(m.state == .finalizing)
        #expect(outputs.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests, expect compile failure**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -15
```

Expected: `Cannot find 'HotkeyStateMachine' in scope`.

- [ ] **Step 3: Implement the state machine**

Create `voxline/Hotkey/HotkeyStateMachine.swift`:

```swift
import Foundation

/// Pure state machine for the hold-to-talk chord.
/// All inputs are events; all outputs are effect descriptions.
/// No CGEventTap, no timers, no AVFoundation — fully unit-testable.
final class HotkeyStateMachine {

    enum State: Equatable {
        case idle
        case armed       // exactly one chord modifier down
        case recording   // both chord modifiers down, audio capture in progress
        case finalizing  // either modifier released or fail-safe fired; awaiting transcription
    }

    enum Input: Equatable {
        case flagsChanged(leftCtrlDown: Bool, leftOptDown: Bool)
        case maxDurationElapsed
        case tapDisabled
        case appDeactivated
        case recordingFinished
    }

    enum Output: Equatable {
        case startRecording
        case finalizeRecording
    }

    private(set) var state: State = .idle

    /// Process an input. Returns zero or more effect outputs the caller should perform.
    @discardableResult
    func handle(_ input: Input) -> [Output] {
        switch (state, input) {

        // From idle / armed, modifier flag changes drive entry into recording.
        case (.idle, .flagsChanged(let ctrl, let opt)),
             (.armed, .flagsChanged(let ctrl, let opt)):
            return reactToFlags(ctrl: ctrl, opt: opt)

        // While recording, ANY input that signals "stop" finalizes.
        case (.recording, .flagsChanged(let ctrl, let opt)) where !(ctrl && opt):
            state = .finalizing
            return [.finalizeRecording]

        case (.recording, .maxDurationElapsed),
             (.recording, .tapDisabled),
             (.recording, .appDeactivated):
            state = .finalizing
            return [.finalizeRecording]

        // Recording finished signal moves us back to idle.
        case (.finalizing, .recordingFinished):
            state = .idle
            return []

        // Any other input in any other state is a no-op.
        default:
            return []
        }
    }

    private func reactToFlags(ctrl: Bool, opt: Bool) -> [Output] {
        switch (ctrl, opt) {
        case (true, true):
            state = .recording
            return [.startRecording]
        case (true, false), (false, true):
            state = .armed
            return []
        case (false, false):
            state = .idle
            return []
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** TEST SUCCEEDED **` with **27 tests** (14 from prior + 13 new HotkeyStateMachine tests).

- [ ] **Step 5: Commit**

```bash
git add voxline/Hotkey/ voxlineTests/HotkeyStateMachineTests.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add HotkeyStateMachine pure-logic state machine

State machine over (idle, armed, recording, finalizing) covering chord entry,
chord release, max-duration / tap-disabled / app-deactivated fail-safes, and
edge cases like atomic chord rollover and modifier events arriving during
finalization. 13 unit tests cover all transitions; the CGEventTap wrapper
in Task 4 will translate OS events into machine inputs."
```

---

## Task 4: HotkeyMonitor (CGEventTap + fail-safes)

**Files:**
- Create: `voxline/Hotkey/HotkeyMonitor.swift`

This task is hard to unit-test (CGEventTap can't be mocked without significant scaffolding). Verification is manual: building successfully + a simple smoke harness that prints state transitions.

- [ ] **Step 1: Implement `voxline/Hotkey/HotkeyMonitor.swift`**

```swift
import AppKit
import CoreGraphics
import Foundation

/// Drives a HotkeyStateMachine from real OS events.
/// Owns a session-level CGEventTap, the fail-safe timers, and an NSWorkspace observer.
@MainActor
final class HotkeyMonitor {

    /// Observer notified when the state machine produces effects.
    /// Runs on the main actor.
    var onStartRecording: (() -> Void)?
    var onFinalizeRecording: (() -> Void)?

    /// Maximum recording duration (spec §4.1 fail-safe). Configurable.
    var maxRecordingDuration: TimeInterval = 60.0

    private let machine = HotkeyStateMachine()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var maxDurationTimer: Timer?
    private var reconciliationTimer: Timer?
    private var deactivationObserver: Any?

    // MARK: - Lifecycle

    /// Install the tap and observers. Throws if Accessibility is not granted.
    func start() throws {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: HotkeyMonitor.tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw HotkeyMonitorError.accessibilityNotGranted
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source

        // Periodic reconciliation: catches missed flagsChanged events.
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileFlagsState() }
        }

        // App deactivation guard.
        deactivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == Bundle.main.bundleIdentifier
            else { return }
            Task { @MainActor [weak self] in self?.feed(.appDeactivated) }
        }
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil
        runLoopSource = nil

        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil

        if let obs = deactivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            deactivationObserver = nil
        }
    }

    /// External signal that transcription has finished and we can return to idle.
    func recordingFinished() {
        feed(.recordingFinished)
    }

    // MARK: - Tap callback

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .flagsChanged:
            let flags = event.flags
            // CGEventFlags doesn't distinguish left vs right modifiers directly;
            // we use the maskNonCoalesced + virtual key check via NX_DEVICELCTLKEYMASK / NX_DEVICELALTKEYMASK.
            let leftCtrl = flags.contains(CGEventFlags(rawValue: NX_DEVICELCTLKEYMASK))
            let leftOpt  = flags.contains(CGEventFlags(rawValue: NX_DEVICELALTKEYMASK))
            Task { @MainActor in
                monitor.feed(.flagsChanged(leftCtrlDown: leftCtrl, leftOptDown: leftOpt))
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap and signal a defensive finalize.
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

    // MARK: - Reconciliation

    /// Poll the global modifier state. If we're still "recording" but the
    /// chord is no longer physically held (we missed the release event), finalize.
    private func reconcileFlagsState() {
        guard machine.state == .recording else { return }
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let leftCtrl = flags.contains(CGEventFlags(rawValue: NX_DEVICELCTLKEYMASK))
        let leftOpt  = flags.contains(CGEventFlags(rawValue: NX_DEVICELALTKEYMASK))
        if !(leftCtrl && leftOpt) {
            feed(.flagsChanged(leftCtrlDown: leftCtrl, leftOptDown: leftOpt))
        }
    }

    // MARK: - Routing inputs through the machine

    private func feed(_ input: HotkeyStateMachine.Input) {
        let outputs = machine.handle(input)
        for output in outputs {
            switch output {
            case .startRecording:
                scheduleMaxDurationTimer()
                onStartRecording?()
            case .finalizeRecording:
                cancelMaxDurationTimer()
                onFinalizeRecording?()
            }
        }
    }

    private func scheduleMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(withTimeInterval: maxRecordingDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.feed(.maxDurationElapsed) }
        }
    }

    private func cancelMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }
}

enum HotkeyMonitorError: Error {
    case accessibilityNotGranted
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If it fails complaining about `NX_DEVICELCTLKEYMASK` / `NX_DEVICELALTKEYMASK`, those are defined in `<IOKit/hidsystem/IOLLEvent.h>` — Swift bridges them via `import IOKit`. Add `import IOKit.hidsystem` at the top if needed.

- [ ] **Step 3: Run tests**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **` with 27 tests still passing.

- [ ] **Step 4: Commit**

```bash
git add voxline/Hotkey/HotkeyMonitor.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add HotkeyMonitor: CGEventTap wrapper driving HotkeyStateMachine

Implements all four spec §4.1 fail-safes:
  1. Max recording duration (60s default, configurable)
  2. CGEventTap re-enable on kCGEventTapDisabledByTimeout/UserInput
  3. Periodic flagsState reconciliation every 250 ms
  4. App-deactivation guard via NSWorkspace notification

Left-vs-right modifier detection uses NX_DEVICELCTLKEYMASK / NX_DEVICELALTKEYMASK
flag bits (the standard Carbon-era device-specific modifier flags). Manual
verification happens at the pipeline integration in Task 9."
```

---

## Task 5: AudioFormat constants and math (TDD)

**Files:**
- Create: `voxline/Audio/AudioFormat.swift`
- Create: `voxlineTests/AudioFormatTests.swift`

- [ ] **Step 1: Write the tests**

Create `voxlineTests/AudioFormatTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct AudioFormatTests {

    @Test func whisperInputFormatIs16kHzMonoFloat() {
        #expect(AudioFormat.whisperSampleRate == 16_000)
        #expect(AudioFormat.whisperChannelCount == 1)
    }

    @Test func sampleCountForOneSecondIs16k() {
        #expect(AudioFormat.sampleCount(forSeconds: 1.0) == 16_000)
    }

    @Test func sampleCountForHalfSecondIs8k() {
        #expect(AudioFormat.sampleCount(forSeconds: 0.5) == 8_000)
    }

    @Test func sampleCountClampsToZeroForNegativeDuration() {
        #expect(AudioFormat.sampleCount(forSeconds: -1.0) == 0)
    }

    @Test func levelOfSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: silence) == 0)
    }

    @Test func levelOfFullScaleIsOne() {
        let full = [Float](repeating: 1.0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: full) == 1.0)
    }

    @Test func levelOfNegativeFullScaleIsOne() {
        // Peak is absolute value.
        let negFull = [Float](repeating: -1.0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: negFull) == 1.0)
    }

    @Test func levelOfEmptyArrayIsZero() {
        #expect(AudioFormat.peakLevel(samples: []) == 0)
    }
}
```

- [ ] **Step 2: Run tests, expect failure**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `Cannot find 'AudioFormat' in scope`.

- [ ] **Step 3: Implement**

Create `voxline/Audio/AudioFormat.swift`:

```swift
import Foundation

enum AudioFormat {
    /// Whisper expects 16 kHz audio.
    static let whisperSampleRate: Double = 16_000

    /// Whisper expects mono.
    static let whisperChannelCount: UInt32 = 1

    /// Sample count for a duration at Whisper's sample rate. Negative durations clamp to 0.
    static func sampleCount(forSeconds seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(seconds * whisperSampleRate)
    }

    /// Peak absolute amplitude of a Float32 PCM buffer, clamped to [0, 1].
    /// Used as a proxy for the recording-pill waveform meter.
    static func peakLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        for s in samples {
            let m = abs(s)
            if m > peak { peak = m }
        }
        return min(peak, 1.0)
    }
}
```

- [ ] **Step 4: Run tests, expect pass**

Expected: `** TEST SUCCEEDED **` with **35 tests** (27 prior + 8 new).

- [ ] **Step 5: Commit**

```bash
git add voxline/Audio/AudioFormat.swift voxlineTests/AudioFormatTests.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add AudioFormat constants + peakLevel/sampleCount helpers

Whisper requires 16 kHz mono Float32. AudioCaptureService in Task 6 will
use AVAudioConverter to land in this format from whatever the hardware mic
delivers. peakLevel is the cheap proxy the recording-pill waveform reads."
```

---

## Task 6: AudioCaptureService

**Files:**
- Create: `voxline/Audio/AudioCaptureService.swift`
- Delete: `voxline/WhisperKitImport.swift` (Task 2 smoke-test file no longer needed)

- [ ] **Step 1: Implement `voxline/Audio/AudioCaptureService.swift`**

```swift
import AVFoundation
import Foundation

/// Captures audio from the system input device, resamples to Whisper's format
/// (16 kHz mono Float32), and accumulates the converted samples in memory.
///
/// Audio is *never* written to disk. Buffers are released when stop() is called
/// after the consumer has drained them via takeSamples().
@MainActor
final class AudioCaptureService {

    /// Called periodically (~60 Hz) with the current peak level [0, 1] of the
    /// most recently captured chunk. Used by the recording pill's waveform.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var convertedFormat: AVAudioFormat?
    private var samples: [Float] = []

    /// Begin capture. Throws if the input device is unavailable or sample-rate negotiation fails.
    func start() throws {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // Whisper input format.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.targetFormatUnavailable
        }
        convertedFormat = target

        guard let conv = AVAudioConverter(from: hardwareFormat, to: target) else {
            throw AudioCaptureError.cannotConvertFormat
        }
        converter = conv

        samples.removeAll(keepingCapacity: true)

        // Tap with hardware-native format (must match what the input node delivers).
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer: buffer)
        }

        try engine.start()
    }

    /// Stop capture. Returns immediately; samples remain available via takeSamples().
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Drain and return the converted samples buffered so far. Subsequent calls return [].
    func takeSamples() -> [Float] {
        defer { samples.removeAll(keepingCapacity: false) }
        return samples
    }

    // MARK: - Private

    private func handleInput(buffer: AVAudioPCMBuffer) {
        guard
            let converter,
            let target = convertedFormat
        else { return }

        // Allocate a scratch buffer big enough for any reasonable conversion result.
        // 16k * (hardware/target ratio) — pad generously.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: estimatedFrames
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = outBuffer.floatChannelData?[0] else {
            return
        }

        let count = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.samples.append(contentsOf: chunk)
            let level = AudioFormat.peakLevel(samples: chunk)
            self.onLevel?(level)
        }
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
    case targetFormatUnavailable
    case cannotConvertFormat
}
```

- [ ] **Step 2: Delete the temporary smoke-test file from Task 2**

```bash
rm voxline/WhisperKitImport.swift
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run tests**

Expected: `** TEST SUCCEEDED **` still 35 tests (no new tests for this service — it's runtime/AVFoundation-bound and verified manually in Task 9).

- [ ] **Step 5: Commit**

```bash
git add voxline/Audio/AudioCaptureService.swift
git rm voxline/WhisperKitImport.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add AudioCaptureService: AVAudioEngine + AVAudioConverter pipeline

Captures input in hardware format (typically 48 kHz float32), converts to
16 kHz mono float32 in real time, accumulates samples in memory. Emits
per-chunk peak levels for the recording-pill waveform. Audio never touches
disk. Verified end-to-end at Task 9 once HotkeyMonitor and pipeline are wired.

Removes the temporary WhisperKitImport.swift smoke-test file from Task 2."
```

---

## Task 7: WhisperModel + TranscriptionService

**Files:**
- Create: `voxline/Transcription/WhisperModel.swift`
- Create: `voxline/Transcription/TranscriptionService.swift`
- Create: `voxlineTests/WhisperModelTests.swift`

- [ ] **Step 1: Write the WhisperModel tests**

Create `voxlineTests/WhisperModelTests.swift`:

```swift
import Testing
@testable import voxline

@Suite struct WhisperModelTests {

    @Test func defaultIsLargeV3Turbo() {
        #expect(WhisperModel.default == .largeV3Turbo)
    }

    @Test func largeV3Turbo_identifierMatchesWhisperKitConvention() {
        #expect(WhisperModel.largeV3Turbo.whisperKitIdentifier == "openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func smallEn_identifierMatchesWhisperKitConvention() {
        #expect(WhisperModel.smallEn.whisperKitIdentifier == "openai_whisper-small.en")
    }

    @Test func displayNamesAreNonEmpty() {
        #expect(!WhisperModel.largeV3Turbo.displayName.isEmpty)
        #expect(!WhisperModel.smallEn.displayName.isEmpty)
    }
}
```

- [ ] **Step 2: Implement `voxline/Transcription/WhisperModel.swift`**

```swift
import Foundation

/// Speech-to-text models supported by voxline. Spec §4.2 calls out
/// `large-v3-turbo` as default, `small.en` as the lightweight fallback.
enum WhisperModel: String, CaseIterable {
    case largeV3Turbo
    case smallEn

    static let `default`: WhisperModel = .largeV3Turbo

    /// Identifier WhisperKit uses to look up the Core ML model bundle in its
    /// hosted model repository. These map to argmaxinc/whisperkit-coreml
    /// repository folder names.
    var whisperKitIdentifier: String {
        switch self {
        case .largeV3Turbo: return "openai_whisper-large-v3-v20240930_turbo"
        case .smallEn:      return "openai_whisper-small.en"
        }
    }

    var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper large-v3 turbo (recommended)"
        case .smallEn:      return "Whisper small.en (lightweight)"
        }
    }

    /// Approximate download size in megabytes; used by the first-run wizard.
    var approxSizeMB: Int {
        switch self {
        case .largeV3Turbo: return 1500
        case .smallEn:      return 466
        }
    }
}
```

- [ ] **Step 3: Implement `voxline/Transcription/TranscriptionService.swift`**

```swift
import Foundation
import WhisperKit

/// Wraps WhisperKit. Lazy-loads the active model on first call; subsequent
/// calls reuse the loaded pipeline.
@MainActor
final class TranscriptionService {

    /// Active model. Changing this invalidates any loaded pipeline.
    var model: WhisperModel {
        didSet { whisperKit = nil }
    }

    /// Called with download progress in [0, 1] while the model is being fetched
    /// on first use. Set this before calling transcribe().
    var onModelDownloadProgress: ((Double) -> Void)?

    private var whisperKit: WhisperKit?

    init(model: WhisperModel = .default) {
        self.model = model
    }

    /// Transcribe a Float32 PCM buffer at AudioFormat.whisperSampleRate.
    func transcribe(samples: [Float]) async throws -> String {
        let kit = try await loadIfNeeded()
        let results = try await kit.transcribe(audioArray: samples)
        // WhisperKit returns [TranscriptionResult]; concatenate text segments.
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private

    private func loadIfNeeded() async throws -> WhisperKit {
        if let kit = whisperKit { return kit }

        // Configure WhisperKit to download/load the active model.
        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier,
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )

        let kit = try await WhisperKit(config)
        whisperKit = kit
        return kit
    }
}
```

- [ ] **Step 4: Run tests + build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** TEST SUCCEEDED **` with **39 tests** (35 prior + 4 new WhisperModel tests). `** BUILD SUCCEEDED **`.

If WhisperKit's API has shifted such that `WhisperKitConfig` doesn't have these fields, or `transcribe(audioArray:)` is named differently, consult the package's README at `https://github.com/argmaxinc/WhisperKit` to find the current names. The shape of the file (init takes a config, expose a single async transcribe call, lazy-load) is what matters; field names are version-specific.

- [ ] **Step 5: Commit**

```bash
git add voxline/Transcription/ voxlineTests/WhisperModelTests.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add WhisperModel enum + TranscriptionService wrapping WhisperKit

WhisperModel.default is large-v3-turbo per spec §4.2, with smallEn as the
lightweight fallback selectable in Settings (Plan 4). TranscriptionService
lazy-loads the active model on first transcribe() call, downloading from
argmaxinc/whisperkit-coreml on Hugging Face if not already cached.

The first call after launch will block for the model download (~1.5 GB on
default), so first-run wizard (Plan 4) should pre-warm. Plan 2 verifies
the pipeline end-to-end with a smaller test if download is too slow."
```

---

## Task 8: RecordingPillView + RecordingPillWindow (floating click-through pill)

**Files:**
- Create: `voxline/UI/RecordingPillView.swift`
- Create: `voxline/UI/RecordingPillWindow.swift`

- [ ] **Step 1: Implement `voxline/UI/RecordingPillView.swift`**

```swift
import SwiftUI

/// Small floating pill showing recording state and an animated waveform.
struct RecordingPillView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch state.status {
            case .recording:
                WaveformBars(level: state.audioLevel)
                Text(elapsed)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .thinking:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(width: 140, height: 32)
    }

    private var elapsed: String {
        guard let startedAt = state.recordingStartedAt else { return "0.0s" }
        let s = Date().timeIntervalSince(startedAt)
        return String(format: "%.1fs", s)
    }
}

private struct WaveformBars: View {
    let level: Float
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { i in
                    Capsule()
                        .frame(width: 3, height: barHeight(forIndex: i, time: now))
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private func barHeight(forIndex i: Int, time: Double) -> CGFloat {
        let phaseOffset = Double(i) * 0.6
        let wave = (sin(time * 6 + phaseOffset) + 1) / 2  // 0...1
        let scaled = CGFloat(level) * (0.4 + 0.6 * CGFloat(wave))
        return max(4, min(16, 16 * scaled))
    }
}
```

- [ ] **Step 2: Implement `voxline/UI/RecordingPillWindow.swift`**

```swift
import AppKit
import SwiftUI

/// Hosts RecordingPillView in a click-through, non-activating NSPanel.
@MainActor
final class RecordingPillWindow {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingPillView>?

    func show(state: AppState) {
        if panel != nil {
            updateVisibility(state: state)
            return
        }

        let view = RecordingPillView(state: state)
        let host = NSHostingView(rootView: view)
        hostingView = host

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 32),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // click-through
        panel.contentView = host

        repositionNearMouse(panel: panel)

        self.panel = panel
        updateVisibility(state: state)
    }

    func updateVisibility(state: AppState) {
        guard let panel else { return }
        switch state.status {
        case .recording, .thinking:
            if !panel.isVisible {
                repositionNearMouse(panel: panel)
                panel.orderFrontRegardless()
            }
        default:
            panel.orderOut(nil)
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func repositionNearMouse(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let size = panel.frame.size
        // Place pill just below the cursor, horizontally centered.
        let origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 24)
        panel.setFrameOrigin(origin)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add voxline/UI/
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add RecordingPillView + RecordingPillWindow (floating click-through)

NSPanel-hosted SwiftUI view that shows an animated waveform while recording
and a spinner during transcription. Positioned just below the cursor at
recording start; click-through and non-activating so the user's focused
text field never loses focus. Visibility driven by AppState.status."
```

---

## Task 9: DebugTranscriptWindow (Plan 2 verification UI)

**Files:**
- Create: `voxline/UI/DebugTranscriptWindow.swift`

This file is intentionally Plan-2-only. Plan 3 (LLM + paste) replaces it with the real paste flow. The file is annotated with a removal banner so it's easy to find later.

- [ ] **Step 1: Create the debug window**

```swift
import SwiftUI

// PLAN 2 ONLY — REMOVED IN PLAN 3 ONCE PASTE LANDS.
// This window shows recent transcripts so we can verify the capture pipeline
// without the LLM cleanup or paste yet wired up.
struct DebugTranscriptWindow: View {
    @Bindable var state: AppState
    @State private var history: [TranscriptEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("voxline — transcripts (Plan 2 debug)")
                .font(.headline)
            Divider()

            if history.isEmpty {
                Text("No transcripts yet. Hold Left Ctrl + Left Option, speak, release.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(history) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 480, minHeight: 320)
        .onChange(of: state.lastTranscript) { _, newValue in
            guard let text = newValue, !text.isEmpty else { return }
            history.insert(TranscriptEntry(text: text, timestamp: Date()), at: 0)
            // Keep at most 20 entries.
            if history.count > 20 { history.removeLast(history.count - 20) }
        }
    }
}

private struct TranscriptEntry: Identifiable {
    let id = UUID()
    let text: String
    let timestamp: Date
}
```

- [ ] **Step 2: Build**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add voxline/UI/DebugTranscriptWindow.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Add DebugTranscriptWindow (Plan 2 verification UI)

Shows the most recent 20 transcripts produced by the capture pipeline,
keyed off AppState.lastTranscript. File is marked with a removal banner —
Plan 3 deletes it once the LLM cleanup + paste flow is wired."
```

---

## Task 10: CapturePipeline + integration into voxlineApp + manual verification

**Files:**
- Create: `voxline/Pipeline/CapturePipeline.swift`
- Create: `voxlineTests/CapturePipelineTests.swift`
- Modify: `voxline/voxlineApp.swift`

This is the integration task. Pipeline wires hotkey → audio → transcription → state. Tests cover wiring with fakes; manual verification proves the real pipeline works end-to-end.

- [ ] **Step 1: Define service protocols (testability seam)**

Add to a new file `voxline/Pipeline/PipelineProtocols.swift`:

```swift
import Foundation

/// Testability seam for AudioCaptureService.
@MainActor
protocol AudioCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    func start() throws
    func stop()
    func takeSamples() -> [Float]
}

/// Testability seam for TranscriptionService.
@MainActor
protocol Transcribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
}

extension AudioCaptureService: AudioCapturing {}
extension TranscriptionService: Transcribing {}
```

- [ ] **Step 2: Write CapturePipeline tests with fakes**

Create `voxlineTests/CapturePipelineTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineTests {

    final class FakeCapture: AudioCapturing {
        var onLevel: ((Float) -> Void)?
        var startCallCount = 0
        var stopCallCount = 0
        var pendingSamples: [Float] = [0.1, 0.2, 0.3]
        func start() throws { startCallCount += 1 }
        func stop() { stopCallCount += 1 }
        func takeSamples() -> [Float] { defer { pendingSamples = [] }; return pendingSamples }
    }

    final class FakeTranscriber: Transcribing {
        var nextResult: Result<String, Error> = .success("hello world")
        var transcribeCallCount = 0
        func transcribe(samples: [Float]) async throws -> String {
            transcribeCallCount += 1
            return try nextResult.get()
        }
    }

    @Test func startRecording_setsStateAndStartsCapture() async throws {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()

        #expect(state.status == .recording)
        #expect(state.recordingStartedAt != nil)
        #expect(capture.startCallCount == 1)
    }

    @Test func finalizeRecording_transcribesAndUpdatesState() async throws {
        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        transcriber.nextResult = .success("captured text")
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()
        await pipeline.finalizeRecording()

        #expect(capture.stopCallCount == 1)
        #expect(transcriber.transcribeCallCount == 1)
        #expect(state.lastTranscript == "captured text")
        #expect(state.status == .idle)
        #expect(state.recordingStartedAt == nil)
    }

    @Test func transcriptionFailure_setsErrorState() async throws {
        struct StubError: Error {}

        let state = AppState()
        let capture = FakeCapture()
        let transcriber = FakeTranscriber()
        transcriber.nextResult = .failure(StubError())
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)

        pipeline.startRecording()
        await pipeline.finalizeRecording()

        if case .error = state.status {
            // ok
        } else {
            Issue.record("expected .error state, got \(state.status)")
        }
    }
}
```

- [ ] **Step 3: Implement `voxline/Pipeline/CapturePipeline.swift`**

```swift
import Foundation

/// Coordinates the hotkey → audio capture → transcription pipeline.
/// Updates AppState along the way.
@MainActor
final class CapturePipeline {

    private let state: AppState
    private let capture: AudioCapturing
    private let transcriber: Transcribing

    init(state: AppState, capture: AudioCapturing, transcriber: Transcribing) {
        self.state = state
        self.capture = capture
        self.transcriber = transcriber

        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.audioLevel = level }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    func startRecording() {
        do {
            try capture.start()
        } catch {
            state.status = .error("Audio capture failed: \(error.localizedDescription)")
            return
        }
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.status = .recording
    }

    /// Stop capture, transcribe what was captured, write transcript to state.
    func finalizeRecording() async {
        capture.stop()
        let samples = capture.takeSamples()
        state.status = .thinking

        if samples.isEmpty {
            // Nothing captured — quietly return to idle.
            resetIdle()
            return
        }

        do {
            let text = try await transcriber.transcribe(samples: samples)
            state.lastTranscript = text
        } catch {
            state.status = .error("Transcription failed: \(error.localizedDescription)")
            state.recordingStartedAt = nil
            state.audioLevel = 0
            return
        }

        resetIdle()
    }

    private func resetIdle() {
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.status = .idle
    }
}
```

- [ ] **Step 4a: Update `voxline/MenuBar/MenuBarContent.swift` to include a debug-window opener**

Replace `MenuBarContent.swift` (created in Task 1 Step 2) with this version that adds a "Show Transcripts (debug)…" item. The new item is marked with a removal banner — Plan 3 deletes it when the debug window goes away.

```swift
import SwiftUI

struct MenuBarContent: View {
    @Bindable var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if case .error(let message) = state.status {
            Text(message)
                .foregroundStyle(.red)
            Divider()
        }

        // PLAN 2 ONLY — REMOVED IN PLAN 3 ALONG WITH DebugTranscriptWindow.
        Button("Show Transcripts (debug)…") {
            openWindow(id: "debug-transcripts")
            NSApp.activate()
        }

        Divider()

        Button("Settings…") {
            openSettings()
            // openSettings doesn't activate the app on its own; ensure the
            // settings window comes to the front.
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Divider()

        Button("Quit voxline") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
```

- [ ] **Step 4b: Wire the pipeline into `voxline/voxlineApp.swift`**

Replace the entire file with:

```swift
import SwiftUI

@main
struct voxlineApp: App {

    @State private var appState = AppState()
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(state: appState)
        } label: {
            Image(systemName: MenuBarIcon.symbolName(for: appState.status))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
        }

        // PLAN 2 ONLY — Window scene removed in Plan 3 once paste replaces
        // the debug verification UI.
        Window("voxline — Transcripts (debug)", id: "debug-transcripts") {
            DebugTranscriptWindow(state: appState)
                .onAppear {
                    coordinator.startIfNeeded(state: appState)
                }
        }
        .defaultSize(width: 520, height: 360)
    }
}

/// Owns the long-lived runtime objects (HotkeyMonitor, AudioCapture,
/// TranscriptionService, CapturePipeline, RecordingPillWindow) and starts
/// them on first window appearance.
@MainActor
final class AppCoordinator {
    private var hotkeyMonitor: HotkeyMonitor?
    private var pillWindow: RecordingPillWindow?
    private var pipeline: CapturePipeline?
    private var didStart = false
    private var levelObservation: AnyObject?

    func startIfNeeded(state: AppState) {
        guard !didStart else { return }
        didStart = true

        let capture = AudioCaptureService()
        let transcriber = TranscriptionService()
        let pipeline = CapturePipeline(state: state, capture: capture, transcriber: transcriber)
        self.pipeline = pipeline

        let pill = RecordingPillWindow()
        pillWindow = pill
        pill.show(state: state)

        let monitor = HotkeyMonitor()
        monitor.onStartRecording = { [weak self, weak state] in
            self?.pipeline?.startRecording()
            if let state { self?.pillWindow?.updateVisibility(state: state) }
        }
        monitor.onFinalizeRecording = { [weak self, weak state] in
            Task { @MainActor in
                await self?.pipeline?.finalizeRecording()
                if let state { self?.pillWindow?.updateVisibility(state: state) }
            }
        }
        do {
            try monitor.start()
            hotkeyMonitor = monitor
        } catch {
            state.status = .error("Hotkey monitoring requires Accessibility permission. Grant it in System Settings → Privacy & Security → Accessibility, then restart voxline.")
        }
    }
}
```

- [ ] **Step 5: Build + tests**

```bash
xcodebuild -project voxline.xcodeproj -scheme voxline -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5
xcodebuild -project voxline.xcodeproj -scheme voxlineTests -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` with **42 tests** (39 prior + 3 new CapturePipeline).

- [ ] **Step 6: Manual end-to-end verification**

This step requires a human to grant Accessibility, run the app, and exercise the pipeline. Subagent: produce the artifacts and stop here. Controller: hand off to the user.

User instructions:
1. Open the project in Xcode and ⌘R.
2. The first launch downloads WhisperKit's `large-v3-turbo` model (~1.5 GB). Watch Xcode's console for download logs. This can take 1–10 minutes depending on network.
3. macOS will prompt for **Microphone** permission — grant it.
4. macOS will NOT auto-prompt for Accessibility on this run. Open **System Settings → Privacy & Security → Accessibility**, find voxline, toggle ON. Quit and re-launch the app from Xcode.
5. Click the menu bar mic icon → **Show Transcripts (debug)…**. The debug window appears. (`AppCoordinator.startIfNeeded` runs on the window's first `onAppear`, so the hotkey listener and audio engine boot up at that point.)

6. With the debug window open, hold **Left Ctrl + Left Option**. The recording pill should appear near the cursor with a moving waveform; the menu-bar icon should change to `mic.fill`.
7. Speak: "this is a test of the voxline capture pipeline."
8. Release either modifier. The pill switches to a spinner; the menu icon changes to `ellipsis.circle`. After 1–5 seconds the transcript appears in the debug window.
9. Repeat a few times to confirm consistency. If the menu icon goes to `mic.slash` with an inline error, read the message — it's likely "Transcription failed" or "Audio capture failed" with a specific cause.

Document the result in the commit message of Step 7.

- [ ] **Step 7: Commit + tag milestone**

```bash
git add voxline/Pipeline/ voxline/voxlineApp.swift voxline/MenuBar/MenuBarContent.swift voxlineTests/CapturePipelineTests.swift
git -c user.email=todd124@gmail.com -c user.name=Todd commit -m "Wire capture pipeline: hotkey → audio → transcription → debug window

Plan 2 milestone. Hold Left Ctrl + Left Option, speak, release; the captured
audio is converted to 16 kHz mono Float32, transcribed via WhisperKit, and
the result lands in the debug window via AppState.lastTranscript.

Components landed:
- HotkeyStateMachine + HotkeyMonitor with all four spec §4.1 fail-safes
- AudioCaptureService (AVAudioEngine + AVAudioConverter)
- TranscriptionService (WhisperKit-backed, lazy model load)
- RecordingPill (NSPanel-hosted, click-through)
- DebugTranscriptWindow (removed in Plan 3)
- CapturePipeline coordinator
- AppCoordinator wiring everything at app launch

42 tests passing (3 new CapturePipeline tests with mocks for AudioCapturing
and Transcribing).

Manual verification: <fill in once executed — confirmed transcript flow
works for Slack-style sentence, latency under N seconds, no crashes>."

git tag -a capture-pipeline-complete -m "Plan 2 complete — full hotkey → transcript flow"
```

---

## Out of Scope (deferred to Plan 3)

- LLM clients (Anthropic + OpenAI)
- Keychain-backed API key storage
- Per-app `Mode` data model + JSON loader
- Mode routing by frontmost bundle ID
- Clipboard-paste output with chord-release gate and multi-item preservation
- Removal of `DebugTranscriptWindow` (lands once paste replaces it)

## Out of Scope (deferred to Plan 4)

- Settings tab real controls (hotkey picker, mic device picker, model picker, API key fields, mode editor)
- First-run wizard
- Smoke pass against §9.3 manual targets

---

## Self-review checklist (controller)

After all tasks, run a final pass:

1. **Spec coverage:**
   - §4.1 (Hotkey + Audio Capture) — covered by Tasks 3, 4, 5, 6
   - §4.2 (Local Transcription) — covered by Task 7
   - §6.2 (Floating recording pill) — covered by Task 8
   - §11 fail-safes (max duration, tap re-enable, flagsState reconciliation, app-deactivation) — Task 4

2. **Type consistency:** verify cross-task identifiers
   - `HotkeyStateMachine.Input` and `.Output` cases used in Task 3 match what Task 4 emits
   - `AudioCapturing` and `Transcribing` protocol methods in Task 10 step 1 match `AudioCaptureService` and `TranscriptionService` actual signatures from Tasks 6 + 7
   - `AppState` field names from Task 1 step 4 match references in Task 8 (`audioLevel`, `recordingStartedAt`) and Task 10 (`status`, `lastTranscript`)

3. **Test count progression:** 11 → 14 (Task 1) → 14 → 27 (Task 3) → 35 (Task 5) → 39 (Task 7) → 42 (Task 10). Verify the running totals make sense as you proceed.

4. **No placeholders, every code step has full code, all commands are runnable.**
