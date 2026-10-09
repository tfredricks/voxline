# Transcription Engine (0.5.0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the release-then-transcribe pipeline with streaming engine sessions (Apple Speech, WhisperKit, OpenAI Realtime). Pick the default engine by a measured bake-off. Show live text in a bottom-center pill, and make Esc cancel and Retry work at every stage.

**Architecture:** A `TranscriptionEngine` / `TranscriptionSession` protocol pair sits behind a `TranscriptionEngines` registry. `AudioCaptureService` delivers converted chunks synchronously into a `StreamingSampleRouter`, which buffers until the engine's session opens and then forwards. `CapturePipeline` opens the session at recording start and consumes its partials into `AppState.liveTranscript`. On release it calls `finish()`, then runs cleanup and insert as before, with a generation token so Esc can abandon in-flight work. An `EscapeKeyInterceptor` swallows Esc only while the pipeline is cancellable.

**Tech Stack:** Swift (language mode 5; `@MainActor` types, `Sendable` protocols, locks for audio-thread state), SwiftUI + AppKit, Speech framework (`SpeechAnalyzer` / `SpeechTranscriber`, macOS 26), WhisperKit 1.0 (`argmax-oss-swift`), `URLSessionWebSocketTask`, Swift Testing, Xcode 26.

**Spec:** `docs/superpowers/specs/2026-10-08-transcription-engine-design.md`. Read it before starting any task; this plan does not restate its rationale.

## Global Constraints

- Minimum macOS 26.0. Apple Silicon. `@available` checks for macOS 26 APIs are unnecessary.
- Tests use Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), never XCTest. Per-test `UserDefaults(suiteName: UUID().uuidString)!` and temp directories. Never touch `UserDefaults.standard`, the real keychain, or `NSPasteboard.general` from a test.
- Run one suite: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/<SuiteName> 2>&1 | tail -40`. Full suite: drop `-only-testing`. If you pipe through anything, `set -o pipefail` first.
- Engine integration tests (real Apple Speech / real WhisperKit) are gated by the env var `VOXLINE_ENGINE_TESTS=1`. Pass it to `xcodebuild` as `TEST_RUNNER_VOXLINE_ENGINE_TESTS=1 xcodebuild test …`. Use `.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_ENGINE_TESTS"] == "1")`.
- The project uses synchronized folders: new `.swift` files under `voxline/` or `voxlineTests/` are picked up automatically. Never edit `project.pbxproj`.
- Commits go directly on the current branch. Use Conventional Commits with DCO sign-off (`git commit -s`), and end the message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- No comments that narrate what code does. `///` doc comments only on behavior contracts, matching the surrounding code.
- Audio is never written to disk, except by the hidden bake-off capture flag added in Task 10.
- API keys are read only through `KeychainStorage` (`DataProtectionKeychain` in production). Never log a key or put one in a URL.
- Every task ends with the **full** test suite passing and the app building (`xcodebuild build -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'`).
- Copy strings in this plan are final user-facing text. Use them verbatim.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `voxline/Transcription/TranscriptionEngine.swift` (new) | `EngineID`, `EngineCapabilities`, `EngineReadiness`, `SessionConfig`, `TranscriptPartial`, `TranscriptionEngine`, `TranscriptionSession`, `TranscriptionEngineProviding` | 1 |
| `voxline/Pipeline/StreamingSampleRouter.swift` (new) | Capture → session buffering, count/peak tally, optional retention | 1 |
| `voxline/Storage/AppSettings.swift` | `transcriptionEngine` (T1), `skipShortUtterances` (T5), `saveBakeoffClips` (T10) | 1, 5, 10 |
| `voxlineTests/FakeTranscriptionEngine.swift` (new) | `FakeTranscriptionEngine`, `FakeTranscriptionSession`, `FakeEngineProvider` | 1 |
| `voxline/Audio/CaptureConverter.swift` (new) | Lock-guarded converter with end-of-stream flush | 2 |
| `voxline/Audio/AudioCaptureService.swift` | `onSamples` sink, flush on stop, config-change `onInterrupted` | 2, 5 |
| `voxline/Pipeline/PipelineProtocols.swift` | `AudioCapturing` gains sink and interruption; `Transcribing` deleted (T5) | 2, 5 |
| `voxline/LLM/*` | Budget, stop/finish reasons, preamble assembly, fast-path predicate | 3 |
| `voxline/Transcription/Engines/AppleSpeechEngine.swift` (new) | `SpeechTranscriber` engine + session + partial accumulator | 4 |
| `voxline/Info.plist` | `NSSpeechRecognitionUsageDescription` | 4 |
| `voxline/Transcription/Engines/WhisperKitEngine.swift` (new) | Rolling-window WhisperKit session; prompt tokens | 5a |
| `voxline/Transcription/TranscriptionService.swift` | Expose loaded kit + tokenizer to the engine | 5a, 6 |
| `voxline/Transcription/TranscriptionEngines.swift` (new) | Registry, selection | 5 |
| `voxline/Pipeline/CapturePipeline.swift` | Sessions, live transcript, metrics, cancel, retry, fallback | 5, 8, 9, 10 |
| `voxline/AppState.swift` | `liveTranscript`, `pipelinePhase`, `retryTranscript`, `isCancellable` | 5 |
| `voxline/Diagnostics/DictationMetrics.swift`, `voxline/UI/DiagnosticsView.swift` | `firstPartialMs`, `skippedCleanup`, medians by kind, `ContinuousClock` | 5 |
| `voxline/AppCoordinator.swift` | Engine wiring (T5), readiness-driven prepare (T6), Esc + retry wiring (T8) | 5, 6, 8 |
| `voxline/Settings/*`, `voxline/Wizard/*`, `voxline/Storage/AppPaths.swift` | Engine picker, wizard step, non-creating cache path | 6 |
| `voxline/UI/RecordingPillWindow.swift`, `RecordingPillView.swift`, `voxline/UI/PillLayout.swift` (new) | Anchoring, sizes, live text, phases, Retry | 7, 8 |
| `voxline/Hotkey/EscapeKeyInterceptor.swift` (new), `HotkeyMonitor.swift` | Esc tap; 5-minute cap | 8 |
| `voxline/MenuBar/MenuBarContent.swift` | Retry last dictation | 8 |
| `voxline/Transcription/Engines/OpenAIRealtimeEngine.swift` (new) | Cloud engine | 9 |
| `voxlineTests/Bakeoff/*` (new), `scripts/make-synthetic-bakeoff.sh` (new) | Scoring, decision rule, fixture loader, bake-off suite | 4c |
| `voxline/Diagnostics/BakeoffClipWriter.swift` (new) | Debug-flag clip capture | 10 |
| `README.md`, `AGENTS.md`, `CHANGELOG.md`, `docs/release/MANUAL_TESTS.md`, `docs/issues.md`, `docs/features.md` | Docs | 11 |

Execution waves (tasks in one wave touch disjoint files and may run in parallel worktrees):

1. Tasks 1, 2, 3
2. Tasks 4, 5a
3. Tasks 5, 4c
4. Tasks 6, 7
5. Task 8
6. Task 9
7. Task 10
8. Task 11

---

### Task 1: Engine protocol, sample router, engine setting

**Files:**
- Create: `voxline/Transcription/TranscriptionEngine.swift`
- Create: `voxline/Pipeline/StreamingSampleRouter.swift`
- Create: `voxlineTests/FakeTranscriptionEngine.swift`
- Modify: `voxline/Storage/AppSettings.swift`
- Test: `voxlineTests/StreamingSampleRouterTests.swift`, `voxlineTests/TranscriptionEngineTypesTests.swift`, `voxlineTests/AppSettingsTests.swift`

**Interfaces:**
- Produces everything below, used by every later task. Names and signatures are fixed.

- [ ] **Step 1: Write `TranscriptionEngine.swift` exactly as follows**

```swift
import Foundation

enum EngineID: String, Codable, CaseIterable, Sendable {
    case apple = "apple"
    case whisperKit = "whisperkit"
    case openAIRealtime = "openai-realtime"

    /// Engine used when the user has not picked one. Set by the bake-off
    /// decision rule (spec, "Decision rule"); never a cloud engine.
    static let `default`: EngineID = .whisperKit

    /// On-device engine the pipeline falls back to when a cloud session fails.
    static var onDeviceDefault: EngineID { EngineID.default.isOnDevice ? EngineID.default : .whisperKit }

    var isOnDevice: Bool { self != .openAIRealtime }

    var displayName: String {
        switch self {
        case .apple:          return "Apple Speech — on-device, fastest"
        case .whisperKit:     return "Whisper — on-device, learns your vocabulary"
        case .openAIRealtime: return "OpenAI — cloud, audio leaves your Mac"
        }
    }
}

struct EngineCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let streamingPartials   = EngineCapabilities(rawValue: 1 << 0)
    static let vocabularyHints     = EngineCapabilities(rawValue: 1 << 1)
    static let sendsAudioOffDevice = EngineCapabilities(rawValue: 1 << 2)
}

enum EngineReadiness: Equatable, Sendable {
    case ready
    /// `downloadMB` is nil when the size is unknown (OS-managed assets).
    case needsPreparation(downloadMB: Int?)
    /// User-facing reason the engine can't run right now.
    case unavailable(String)
}

struct SessionConfig: Equatable, Sendable {
    var vocabularyHints: [String]
    var locale: Locale

    init(vocabularyHints: [String] = [], locale: Locale = .current) {
        self.vocabularyHints = vocabularyHints
        self.locale = locale
    }
}

struct TranscriptPartial: Equatable, Sendable {
    /// Committed text; will not change for the rest of the session.
    var stable: String
    /// Current guess for the tail; may be revised or dropped.
    var volatile: String

    init(stable: String = "", volatile: String = "") {
        self.stable = stable
        self.volatile = volatile
    }

    var text: String { Self.join(stable, volatile) }
    var isEmpty: Bool { text.isEmpty }

    /// Concatenate two transcript fragments with exactly one space between
    /// them when neither side already provides whitespace at the seam.
    static func join(_ head: String, _ tail: String) -> String {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return t }
        if t.isEmpty { return h }
        return h + " " + t
    }
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    var id: EngineID { get }
    /// Stable identifier of engine + model for metrics, e.g. "apple:en_US".
    var metricsID: String { get }
    var capabilities: EngineCapabilities { get }
    func readiness() async -> EngineReadiness
    /// Download / install / warm. Idempotent; cheap when already ready.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession
}

/// One recording's worth of streaming recognition.
protocol TranscriptionSession: AnyObject, Sendable {
    /// 16 kHz mono Float32. Callable from any thread, including the audio
    /// render thread; must not block on I/O.
    func append(_ samples: [Float])
    /// Snapshots of the transcript as it evolves. Finishes after `finish()`
    /// returns or `cancel()` is called.
    var partials: AsyncStream<TranscriptPartial> { get }
    /// Flush and return the final text, trimmed.
    func finish() async throws -> String
    /// Idempotent. A pending or later `finish()` throws `CancellationError`.
    func cancel()
}

@MainActor
protocol TranscriptionEngineProviding: AnyObject {
    var current: any TranscriptionEngine { get }
    func engine(for id: EngineID) -> any TranscriptionEngine
}
```

- [ ] **Step 2: Write the failing router tests** in `voxlineTests/StreamingSampleRouterTests.swift`. Use `FakeTranscriptionSession` from Step 4.

Tests (each a `@Test` in `@Suite struct StreamingSampleRouterTests`):
- `forwards_pending_chunks_in_order_on_attach`: append [1,2], [3]; attach a fake session; append [4]. The session's `appended` is `[[1,2],[3],[4]]`.
- `tallies_count_and_peak_synchronously`: append [0.1, -0.5], then [0.2]. `sampleCount == 3`, `peak == 0.5`.
- `peak_is_never_zero_when_nonzero_samples_were_counted`: after `append([0.3])`, `sampleCount > 0` implies `peak > 0`. This is the issue 4 regression check.
- `retains_audio_only_when_asked`: with `retainsAudio: true`, `retainedAudio == [1,2,3]` after two appends. With `false` it is `[]`.
- `close_drops_further_input`: attach, close, append. The session receives nothing after close, and `sampleCount` does not change.
- `audioDuration_is_count_over_16k`: append 8,000 zeros, so `audioDuration == 0.5`.
- `concurrent_appends_are_counted`: append from 8 threads × 1,000 chunks (`DispatchQueue.concurrentPerform`). The count matches the total.

- [ ] **Step 3: Implement `StreamingSampleRouter.swift`**

```swift
import Foundation

/// Bridges the capture tap to a transcription session that opens
/// asynchronously. Audio that arrives before the session attaches is held
/// and flushed in order, so opening an engine never clips the first word.
/// Count and peak update together under one lock, so a reader never sees
/// samples without their level.
final class StreamingSampleRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any TranscriptionSession)?
    private var pending: [[Float]] = []
    private var closed = false
    private var _sampleCount = 0
    private var _peak: Float = 0
    private var retained: [Float] = []
    let retainsAudio: Bool

    init(retainsAudio: Bool) {
        self.retainsAudio = retainsAudio
    }

    var sampleCount: Int { lock.withLock { _sampleCount } }
    var peak: Float { lock.withLock { _peak } }
    var retainedAudio: [Float] { lock.withLock { retained } }
    var audioDuration: TimeInterval { Double(sampleCount) / AudioFormat.whisperSampleRate }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let target: (any TranscriptionSession)? = lock.withLock {
            guard !closed else { return nil }
            _sampleCount += samples.count
            _peak = max(_peak, AudioFormat.peakLevel(samples: samples))
            if retainsAudio { retained.append(contentsOf: samples) }
            if let session { return session }
            pending.append(samples)
            return nil
        }
        target?.append(samples)
    }

    func attach(_ session: any TranscriptionSession) {
        lock.withLock {
            guard !closed else { return }
            for chunk in pending { session.append(chunk) }
            pending.removeAll()
            self.session = session
        }
    }

    func close() {
        lock.withLock {
            closed = true
            session = nil
            pending.removeAll()
        }
    }
}
```

`attach` forwards the pending chunks while holding the lock. That makes ordering airtight against a concurrent `append`. Sessions' `append` must therefore never call back into the router; document this on the type.

- [ ] **Step 4: Write `voxlineTests/FakeTranscriptionEngine.swift`**

```swift
import Foundation
@testable import voxline

final class FakeTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [[Float]] = []
    private var continuation: AsyncStream<TranscriptPartial>.Continuation?
    let partials: AsyncStream<TranscriptPartial>
    var finishResult: Result<String, Error> = .success("hello world")
    /// When true, finish() suspends until `releaseFinish()` or `cancel()`.
    var holdFinish = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private(set) var cancelCount = 0
    private(set) var finishCount = 0

    init() {
        var c: AsyncStream<TranscriptPartial>.Continuation!
        partials = AsyncStream { c = $0 }
        continuation = c
    }

    var appended: [[Float]] { lock.withLock { _appended } }
    var appendedSampleCount: Int { appended.reduce(0) { $0 + $1.count } }

    func append(_ samples: [Float]) { lock.withLock { _appended.append(samples) } }

    func emit(_ partial: TranscriptPartial) { continuation?.yield(partial) }

    func finish() async throws -> String {
        lock.withLock { finishCount += 1 }
        if holdFinish {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                lock.withLock { finishWaiter = k }
            }
        }
        if lock.withLock({ cancelCount }) > 0 { throw CancellationError() }
        continuation?.finish()
        return try finishResult.get()
    }

    func releaseFinish() {
        let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { finishWaiter = nil }
            return finishWaiter
        }
        k?.resume()
    }

    func cancel() {
        lock.withLock { cancelCount += 1 }
        continuation?.finish()
        releaseFinish()
    }
}

@MainActor
final class FakeTranscriptionEngine: TranscriptionEngine {
    let id: EngineID
    var metricsID: String
    var capabilities: EngineCapabilities
    var readinessValue: EngineReadiness = .ready
    var openError: Error?
    var prepareCount = 0
    var openedConfigs: [SessionConfig] = []
    /// Sessions handed out, in order. Pre-seed `nextSessions` to control them.
    var nextSessions: [FakeTranscriptionSession] = []
    private(set) var sessions: [FakeTranscriptionSession] = []

    init(id: EngineID = .whisperKit, metricsID: String = "fake:engine", capabilities: EngineCapabilities = [.streamingPartials]) {
        self.id = id
        self.metricsID = metricsID
        self.capabilities = capabilities
    }

    func readiness() async -> EngineReadiness { readinessValue }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { prepareCount += 1; progress(1) }

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        openedConfigs.append(config)
        if let openError { throw openError }
        let s = nextSessions.isEmpty ? FakeTranscriptionSession() : nextSessions.removeFirst()
        sessions.append(s)
        return s
    }
}

@MainActor
final class FakeEngineProvider: TranscriptionEngineProviding {
    var engines: [EngineID: FakeTranscriptionEngine]
    var currentID: EngineID

    init(_ engine: FakeTranscriptionEngine) {
        engines = [engine.id: engine]
        currentID = engine.id
    }

    var current: any TranscriptionEngine { engines[currentID]! }
    func engine(for id: EngineID) -> any TranscriptionEngine { engines[id] ?? engines[currentID]! }
}
```

- [ ] **Step 5: Type tests** in `voxlineTests/TranscriptionEngineTypesTests.swift`:
- `join` cases: ("", "a") → "a"; ("a", "") → "a"; ("a ", " b") → "a b"; ("Hello,", "world") → "Hello, world".
- `EngineID` raw values are exactly "apple", "whisperkit", "openai-realtime".
- `EngineID.default.isOnDevice` is true, and `onDeviceDefault.isOnDevice` is true.

- [ ] **Step 6: `AppSettings.transcriptionEngine`**

Add `static let transcriptionEngine = "voxline.transcription.engine"` to `AppSettings.Key`. Add the property:

```swift
    var transcriptionEngine: EngineID {
        get {
            guard
                let raw = defaults.string(forKey: Key.transcriptionEngine),
                let id = EngineID(rawValue: raw)
            else { return .default }
            return id
        }
        set { defaults.set(newValue.rawValue, forKey: Key.transcriptionEngine) }
    }
```

Tests in `AppSettingsTests`: the default is `EngineID.default` when unset; a set value round-trips; an unknown raw value falls back to the default.

- [ ] **Step 7:** Run the three suites, then the full suite. Commit: `feat(transcription): engine protocol, streaming sample router, engine setting`.

---

### Task 2: Streaming audio capture with tail flush and interruption

**Files:**
- Create: `voxline/Audio/CaptureConverter.swift`
- Modify: `voxline/Audio/AudioCaptureService.swift`, `voxline/Pipeline/PipelineProtocols.swift` (the `AudioCapturing` protocol only)
- Modify test fakes: `voxlineTests/CapturePipelineTests.swift` and `voxlineTests/CapturePipelineErrorTaxonomyTests.swift` (add the two new protocol properties to `FakeCapture`; nothing else)
- Test: `voxlineTests/CaptureConverterTests.swift`

**Interfaces:**
- Produces on `AudioCapturing` (and `AudioCaptureService`):
  - `var onSamples: (@Sendable ([Float]) -> Void)? { get set }` — read once inside `start()`; called synchronously on the tap thread with each converted 16 kHz chunk, and with the flushed remainder during `stop()`.
  - `var onInterrupted: (() -> Void)? { get set }` — called on the main actor when the engine configuration changes, or the engine stops, while capturing.
- Keep `takeSamples()` working for now. Accumulate into an internal lock-protected buffer from the same synchronous delivery path. Task 5 deletes it.

Requirements:
- `CaptureConverter` is a `final class` and `@unchecked Sendable`. It wraps `AVAudioConverter(from: hwFormat, to: 16 kHz mono Float32)` behind an `NSLock` and has:
  - `func convert(_ buffer: AVAudioPCMBuffer) -> [Float]`: returns `[]` once closed. Uses the existing `.noDataNow` (never `.endOfStream`) input-block rule.
  - `func flushAndClose() -> [Float]`: under the lock, converts with an input block that returns `.endOfStream`, collects every output frame, then marks itself closed. Calling it again returns `[]`.
- The tap block calls `converter.convert(buffer)`. When the result is non-empty, it:
  1. calls the captured `onSamples` synchronously
  2. appends to the internal buffer under the lock
  3. hops to the main actor only for `onLevel` and `onTapCallback`. The level is computed from the chunk.
- `stop()`:
  1. `engine.inputNode.removeTap(onBus: 0)`
  2. `let tail = converter.flushAndClose()`; if non-empty, deliver it the same way
  3. stop the engine; set `isCapturing = false`.
  The epoch mechanism stays only to drop stale level/tap-callback hops. Sample delivery no longer depends on it.
- Interruption: in `init`, observe `.AVAudioEngineConfigurationChange` for `engine` through `NotificationCenter`. The handler hops to the main actor. If `isCapturing`, it logs `AppLog.audio.error("input configuration changed during capture")` and calls `onInterrupted?()`. Remove the observer in `deinit`.

Tests (`CaptureConverterTests`; build 48 kHz mono Float32 `AVAudioPCMBuffer`s of a 440 Hz sine):
- `converts_48k_to_16k_at_one_third_rate`: convert 10 buffers of 4,800 frames; the summed output count is within ±32 of 16,000 after `flushAndClose()`.
- `flush_returns_the_converter_tail`: after converting one 4,800-frame buffer, `flushAndClose()` returns a non-empty array or `convert` already returned ≥ 1,580 frames. Assert `convertedCount + flushedCount >= 1590`. This is the issue 23 regression check: no tail lost.
- `convert_after_close_returns_empty`.
- `flush_twice_returns_empty_second_time`.

Steps: write the failing tests → implement `CaptureConverter` → tests pass → refactor `AudioCaptureService` onto it → update the protocol and both `FakeCapture`s (`var onSamples: (@Sendable ([Float]) -> Void)?` and `var onInterrupted: (() -> Void)?`) → full suite → commit `fix(audio): deliver samples synchronously and flush the converter on stop`. The commit body names issues 23 and 8 (observer only; the pipeline reaction lands in Task 5).

---

### Task 3: LLM output budget, truncation and refusal, lean preamble, fast-path predicate

**Files:**
- Modify: `voxline/LLM/LLMProvider.swift` (`LLMRequest`, `LLMError`), `voxline/LLM/AnthropicClient.swift`, `voxline/LLM/OpenAIClient.swift`, `voxline/LLM/LLMService.swift`
- Create: `voxline/LLM/CleanupFastPath.swift`
- Test: `voxlineTests/AnthropicClientTests.swift`, `voxlineTests/OpenAIClientTests.swift`, `voxlineTests/LLMServiceTests.swift`, `voxlineTests/LLMTypesTests.swift`, `voxlineTests/CleanupFastPathTests.swift` (new)

**Interfaces:**
- Produces:
  - `static func LLMRequest.cleanupBudget(transcript: String, model: String) -> Int`
  - `LLMError.truncated`, `LLMError.refused`
  - `static func LLMService.systemPrompt(mode: Mode, context: CapturedContext) -> String`
  - `enum CleanupFastPath { static let maxWords = 6; static func shouldSkip(_ transcript: String) -> Bool }`

Requirements:
- `cleanupBudget`:
  - `base = Int((Double(transcript.utf8.count) / 4 * 1.5).rounded(.up)) + 256`, clamped to `256...4096`.
  - If the lowercased model id starts with `o1`, `o3`, `o4`, or `gpt-5`, add 4,096 after the clamp.
  - `LLMService.cleanup` sets `maxOutputTokens` from it. The transform path keeps 4,096.
- `LLMError` user text:
  - `.truncated` → "The model ran out of output tokens before finishing."
  - `.refused` → "The model declined to process this text."
- Anthropic: decode `stop_reason: String?`.
  - `"max_tokens"` → throw `.truncated`.
  - `"refusal"` → throw `.refused`.
  - Otherwise, existing behavior: empty text → `.badResponseShape(reason: "no text blocks in response")`.
  - Decode before checking for empty text, so a refusal with no blocks reports `.refused`.
- OpenAI: decode `finish_reason: String?` and `content: String?`.
  - `"length"` → `.truncated`.
  - `"content_filter"` → `.refused`.
  - nil or whitespace-only content → `.badResponseShape(reason: "empty message content")`.
- Preamble: split `transcriptionPreamble` into `static let` parts: `preambleCore` (role + never-answer + cleaning rules), `contextParagraph` (the "If a Context section follows…" paragraph), `vocabularyParagraph` (the custom-vocabulary paragraph and its examples), and `styleHeader` ("Style guidance for this dictation:"). Keep `transcriptionPreamble` as `preambleCore + "\n\n" + contextParagraph + "\n\n" + vocabularyParagraph + "\n\n" + styleHeader`, the full form existing tests use.
  - `systemPrompt(mode:context:)` = `preambleCore`, plus `"\n\n" + contextParagraph` when `ContextBlockFormatter.format(transcript: "", context: context)` contains a `Context` section, plus `"\n\n" + vocabularyParagraph` when `!context.customVocabulary.isEmpty`, plus `"\n\n" + styleHeader + "\n" + mode.prompt`.
  - Check `ContextBlockFormatter` for how it signals an empty context, and use that signal directly rather than string-matching if one exists.
  - `LLMService.cleanup` uses the new function. Keep `systemPrompt(mode:)` as `transcriptionPreamble + "\n" + mode.prompt` for the existing test.
  - The exact paragraph text is unchanged. This is a split, not a rewrite.
- `CleanupFastPath.shouldSkip`: true iff the transcript has 1…6 whitespace-separated words, and its lowercased form, with punctuation stripped from each token, contains no token in `["um", "uh", "er", "ah", "hmm"]` and no phrase in `["you know", "i mean"]`.

Tests:
- Budget: `""` → 256. A 400-char transcript → 406. A 20,000-char transcript → 4,096. `gpt-5-mini` with `""` → 4,352. `claude-haiku-4-5` gets no reasoning headroom.
- Anthropic: `{"content":[],"stop_reason":"refusal"}` → `.refused`. Text plus `"stop_reason":"max_tokens"` → `.truncated`. `"end_turn"` with text → the text.
- OpenAI: `finish_reason: "length"` with `content: ""` → `.truncated`. `content: null` with `"stop"` → `.badResponseShape`. `"content_filter"` → `.refused`.
- `systemPrompt(mode:context:)`:
  - with `.empty` context and no vocabulary: contains `preambleCore` and the mode prompt; omits `vocabularyParagraph` and `contextParagraph`.
  - with vocabulary `["LangGraph"]`: contains `vocabularyParagraph`.
  - with `textBeforeCursor: "Hi"`: contains `contextParagraph`.
- `LLMService.cleanup` sends `max_tokens` equal to the budget. Assert through `MockHTTPClient` on the Anthropic request body.
- Fast path: "Sounds good." → true. "um sounds good" → false. "you know what I think" → false. Seven words → false. "" → false.

Commit: `fix(llm): budget output tokens, surface truncation and refusals, trim the preamble`. The body names issues 14 and 18.

---

### Task 4: Apple Speech engine

**Files:**
- Create: `voxline/Transcription/Engines/AppleSpeechEngine.swift`
- Modify: `voxline/Info.plist` (add `NSSpeechRecognitionUsageDescription` = "Voxline transcribes your speech on this Mac when Apple Speech is the selected engine.")
- Test: `voxlineTests/AppleSpeechEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `@MainActor final class AppleSpeechEngine: TranscriptionEngine`, `init(locale: Locale = .current)`. `id == .apple`. `metricsID == "apple:" + resolvedLocale.identifier` ("apple:unresolved" before resolution). `capabilities == [.streamingPartials]`.
- Produces: `struct ApplePartialAccumulator` with `mutating func apply(text: String, isFinal: Bool) -> TranscriptPartial` and `var finalText: String`.

Requirements, from the spike that worked (see spec "Baseline"):
- Locale: `await SpeechTranscriber.supportedLocale(equivalentTo: locale)`, then `Locale(identifier: "en-US")` if that is supported, else nil. Cache the resolved locale.
- `readiness()`:
  - no locale → `.unavailable("Apple Speech doesn't support this Mac's language.")`
  - otherwise map `await AssetInventory.status(forModules: [module])`: `.installed` → `.ready`; `.supported` or `.downloading` → `.needsPreparation(downloadMB: nil)`; `.unsupported` → `.unavailable("Apple Speech isn't available on this Mac.")`
  - Build the module as `SpeechTranscriber(locale:, preset: .progressiveTranscription)`.
- `prepare(progress:)`:
  - If not installed: `try await AssetInventory.assetInstallationRequest(supporting:)`; poll `request.progress.fractionCompleted` every 200 ms in a child task while `downloadAndInstall()` runs; report 1.0 at the end.
  - Then `try? await AssetInventory.reserve(locale:)`.
  - Idempotent.
- `openSession`:
  - New `SpeechTranscriber` for the resolved locale.
  - `SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))`.
  - If hints are non-empty: an `AnalysisContext` with `contextualStrings = [.general: hints]` and `try await analyzer.setContext(…)`.
  - `let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])`, falling back to 16 kHz mono Int16.
  - `try await analyzer.prepareToAnalyze(in: format)`.
  - Create `AsyncStream<AnalyzerInput>.makeStream()`.
  - `try await analyzer.start(inputSequence: stream)`.
  - Start a results task that iterates `transcriber.results`, feeds each result's `String(result.text.characters)` and `result.isFinal` to the accumulator, and yields the partial.
  - Return an `AppleSpeechSession` (`final class`, `@unchecked Sendable`, lock-guarded).
- `AppleSpeechSession.append`: convert Float32 16 kHz mono to the analyzer format with one `AVAudioConverter` per session (input block `.noDataNow` rule), wrap the result in `AnalyzerInput(buffer:)`, and yield it. Drop input after `finish()` or `cancel()` began.
- `finish()`:
  - wrapped in `withTaskCancellationHandler { … } onCancel: { self.cancel() }`
  - `inputContinuation.finish()`, then `try await analyzer.finalizeAndFinishThroughEndOfInput()`, then `try await resultsTask.value`
  - finish the partials stream; return the accumulator's final text, trimmed
  - if `cancel()` ran, throw `CancellationError()`
- `cancel()`: idempotent; finishes both streams; `Task { await analyzer.cancelAndFinishNow() }`; cancels the results task.
- `ApplePartialAccumulator.apply`:
  - final → append to stable via `TranscriptPartial.join`, and reset volatile to "".
  - non-final → volatile = text.
  - Returns the current partial.

Tests:
- Accumulator: volatile "I", then "I push", then final "I pushed the" → stable "I pushed the", volatile "". Then volatile "change" → text "I pushed the change". Then final "change to" → stable "I pushed the change to".
- Integration, gated by `VOXLINE_ENGINE_TESTS`:
  - Write `/usr/bin/say -o <tmp>.wav --data-format=LEF32@16000 "The quick brown fox jumps over the lazy dog near the river bank"` via `Process`.
  - Read it with `AVAudioFile` into `[Float]`.
  - Open a session; append in 1,600-sample chunks; `finish()`.
  - Assert the lowercased result contains "quick brown fox" and "lazy dog".
  - Also assert at least one partial was observed before `finish` returned (collect from `partials` in a task).
- Integration: `cancel()` during a session makes `finish()` throw `CancellationError`.

Commit: `feat(transcription): Apple SpeechTranscriber engine`.

---

### Task 5a: WhisperKit streaming engine

**Files:**
- Create: `voxline/Transcription/Engines/WhisperKitEngine.swift`
- Modify: `voxline/Transcription/TranscriptionService.swift`. Add `func loadedKit() async throws -> WhisperKit { try await loadIfNeeded() }`. No other change.
- Test: `voxlineTests/WhisperKitEngineTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `TranscriptionService`.
- Produces: `@MainActor final class WhisperKitEngine: TranscriptionEngine`, `init(service: TranscriptionService)`, and `let service: TranscriptionService`.
  - `id == .whisperKit`; `metricsID == "whisperkit:" + service.model.whisperKitIdentifier`; `capabilities == [.streamingPartials, .vocabularyHints]`.
  - `readiness()`: `TranscriptionService.isModelCached(service.model) ? .ready : .needsPreparation(downloadMB: service.model.approxSizeMB)`.
  - `prepare(progress:)`: `try await service.prepareModel(progressHandler: progress)`, then `try await service.prewarm()`.
- Produces pure helpers:
  - `enum SegmentConfirmation { static func split(_ segments: [TimedText], keepUnconfirmed: Int, after confirmedEnd: Float) -> (confirmed: [TimedText], unconfirmed: [TimedText], newConfirmedEnd: Float) }`, where `struct TimedText: Equatable, Sendable { let text: String; let start: Float; let end: Float }`.
  - `enum WhisperPrompt { static func tokens(hints: [String], encode: (String) -> [Int], specialTokenBegin: Int, cap: Int = 128) -> [Int] }`.

Requirements:
- `openSession`:
  1. `let kit = try await service.loadedKit()`.
  2. Build `DecodingOptions()` with `promptTokens` from `WhisperPrompt.tokens(hints:encode: { kit.tokenizer?.encode(text: $0) ?? [] }, specialTokenBegin: kit.tokenizer?.specialTokens.specialTokenBegin ?? Int.max)` and `usePrefillPrompt = true`, when the hints are non-empty. Check the WhisperKit 1.0 source in DerivedData for the exact tokenizer API names: `find ~/Library/Developer/Xcode/DerivedData -path '*argmax-oss-swift/Sources/WhisperKit*' -name '*.swift' | xargs grep -n "specialTokenBegin\|func encode"`. Adapt the names, not the behavior.
  3. Return `WhisperKitStreamingSession(kit:options:)`.
- The session is `final class`, `@unchecked Sendable`, with a lock-guarded `[Float]` buffer, `confirmed: [TimedText]`, `confirmedEnd: Float`, and a loop `Task.detached(priority: .userInitiated)`:
  - Every 100 ms, if `buffer.count - lastPassSampleCount >= 16_000` and the session is not finishing, run a pass:
    - `kit.transcribe(audioArray: snapshot, decodeOptions: options with clipTimestamps = [confirmedEnd])`.
    - Map result segments to `TimedText`, with the text trimmed of WhisperKit special tokens. Use `TextUtilities` or a regex for `<|...|>` if the segment text contains them.
    - `SegmentConfirmation.split(keepUnconfirmed: 2, after: confirmedEnd)`.
    - Append the confirmed segments and yield `TranscriptPartial(stable: confirmed.joined, volatile: unconfirmed.joined)`.
- `finish()`:
  1. Mark finishing, cancel the loop task, and await its completion; an in-flight pass completes first.
  2. Run one final pass over the full buffer from `confirmedEnd`.
  3. Result = `TranscriptPartial.join(confirmedText, finalPassText)`, trimmed.
  4. Finish the partials stream and return.
  5. An empty buffer returns `""` without calling WhisperKit.
  6. Wrap in `withTaskCancellationHandler`.
- `cancel()`: set cancelled, cancel the loop, finish the partials stream. `finish()` checks the flag after each await and throws `CancellationError`.
- `SegmentConfirmation.split`: segments whose `end <= confirmedEnd` are dropped as already confirmed. Of the rest, all but the last `keepUnconfirmed` are confirmed; `newConfirmedEnd` = the last confirmed segment's `end`, or the old value.
- `WhisperPrompt.tokens`:
  - empty hints → `[]`
  - otherwise `encode(" " + hints.joined(separator: ", "))`, filtered to tokens `< specialTokenBegin`, keeping the **last** `cap` tokens.

Tests:
- `split` with 5 segments, `keepUnconfirmed: 2` → 3 confirmed, and `newConfirmedEnd` = the third segment's end.
- `split` with 2 segments → 0 confirmed, and the end is unchanged.
- `split` drops segments that end before `confirmedEnd`.
- `tokens`: empty hints → empty. Fake encode `{ $0.unicodeScalars.map { Int($0.value) } }` with `specialTokenBegin: 1000` drops nothing for ASCII; with `cap: 3` it keeps the last 3. A fake encode returning `[5, 2000, 6]` filters out 2000.
- Integration (gated; skipped unless `TranscriptionService.isModelCached(.largeV3Turbo)`): the same `say` clip as Task 4; the result contains "quick brown fox". A 12-second clip (repeat the sentence) yields at least one partial before `finish()` returns.

Commit: `feat(transcription): streaming WhisperKit engine with vocabulary prompt tokens`.

---

### Task 5: Pipeline on streaming sessions

**Files:**
- Create: `voxline/Transcription/TranscriptionEngines.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`, `voxline/Pipeline/PipelineProtocols.swift` (delete `Transcribing`, its extension, and `TranscriptionService: Transcribing`; delete `takeSamples()` from `AudioCapturing`), `voxline/Audio/AudioCaptureService.swift` (delete the internal sample buffer and `takeSamples`), `voxline/AppState.swift`, `voxline/Diagnostics/DictationMetrics.swift`, `voxline/UI/DiagnosticsView.swift`, `voxline/AppCoordinator.swift`, `voxline/voxlineApp.swift` (About env), `voxline/Storage/AppSettings.swift` (`skipShortUtterances`)
- Test: `voxlineTests/CapturePipelineTests.swift`, `voxlineTests/CapturePipelineErrorTaxonomyTests.swift` (migrate to `FakeTranscriptionEngine`), `voxlineTests/DictationMetricsStoreTests.swift`, `voxlineTests/CapturePipelineStreamingTests.swift` (new)

**Interfaces:**
- Consumes: Tasks 1–3, 4, 5a.
- Produces:
  - `@MainActor final class TranscriptionEngines: TranscriptionEngineProviding`, `init(settings: AppSettings, apple: AppleSpeechEngine, whisperKit: WhisperKitEngine)`. `current` returns `engine(for: settings.transcriptionEngine)`. `engine(for:)` maps `.apple` → apple, `.whisperKit` → whisperKit, and `.openAIRealtime` → `engine(for: .onDeviceDefault)` until Task 9 adds the cloud engine. `var whisperKit: WhisperKitEngine { get }` is used by the coordinator's model-swap path.
  - `AppState` additions:
    - `var liveTranscript: TranscriptPartial?`
    - `var pipelinePhase: PipelinePhase?` with `enum PipelinePhase: Equatable { case transcribing, cleaning, inserting }`
    - `var retryTranscript: String?`
    - `var isCancellable: Bool = false`
  - `CapturePipeline.init(state:capture:engines:llm:modes:frontmost:fieldInspector:injector:historyStore:contextCapture:selectionSnapshot:metrics:llmModelID:vocabulary:skipShortUtterances:now:)`. `engines: TranscriptionEngineProviding` replaces `transcriber`. `vocabulary: @escaping @Sendable () -> [String] = { CustomVocabularyStore().load() }` and `skipShortUtterances: @escaping @Sendable () -> Bool = { AppSettings().skipShortUtterances }` are new.
  - `CapturePipeline.handleCaptureInterrupted()`, called by the coordinator from `capture.onInterrupted`.
  - `DictationMetrics` gains `firstPartialMs: Int?` and `skippedCleanup: Bool`. `DictationMetricsStore.median(_ keyPath:, kind: DictationMetrics.Kind = .dictation, excludingZero: Bool = false) -> Int?`.
  - `AppSettings.skipShortUtterances: Bool` (key `voxline.llm.skipShortUtterances`, default false).

Requirements:
- **startRecording(command:)**:
  - Same status gate and prewarm handling as today.
  - Create `router = StreamingSampleRouter(retainsAudio: engine.capabilities.contains(.sendsAudioOffDevice))`. Capture `let engine = engines.current` at start; the whole dictation uses it.
  - Set `capture.onSamples = { [router] in router.append($0) }` before `capture.start()`.
  - Reset `liveTranscript = nil`, `retryTranscript = nil`, and `isCancellable = true`, alongside the existing scrubs.
  - Introduce `private var generation: UInt64 = 0`, bumped at the top of every accepted `startRecording`. Task 8 extends its use to cancel.
  - `sessionTask = Task { try await engine.openSession(SessionConfig(vocabularyHints: vocabulary())) }`.
  - A main-actor follow-up attaches the session to the router and starts `partialsTask`, which iterates `session.partials`. On each partial, if this recording's generation is still current, set `state.liveTranscript = partial`; on the first non-empty partial, record `firstPartialAt = ContinuousClock.now`.
  - The context task becomes a detached task returning `StartSnapshot { context: CapturedContext; bundleID: String?; field: FocusedField? }`. It calls `frontmost.frontmostBundleID()` and `fieldInspector.inspect()` alongside `captor.capture()`.
- **finalizeRecording()**:
  - Guard `.recording`. `let release = ContinuousClock.now`.
  - `capture.stop()`, then `captureTailMs` = elapsed since `release`.
  - `status = .thinking`, `pipelinePhase = .transcribing`, `lastRecordingDuration = router.audioDuration`.
  - If `router.sampleCount == 0` or `router.audioDuration < 0.3`: cancel the session (await `sessionTask` with `try?`, then `cancel()`), close the router, cancel the context tasks, `resetIdle()`, return.
  - If `router.peak == 0`: today's silent-capture error.
  - Await the session. On error: `setError("Couldn't start \(engineName): \(error.localizedDescription)")`, where `engineName` = "Apple Speech", "Whisper", or "OpenAI". Task 9 inserts the cloud fallback here.
  - `let finishStart = ContinuousClock.now; transcript = try await session.finish()`; `transcribeMs` = elapsed. On error: `"Transcription failed. Try again or pick a different engine in Settings → General."`.
  - `router.close()`. `state.lastTranscript = transcript`. If the recording is a dictation: `state.retryTranscript = transcript`. Empty transcript → idle quietly, as today.
  - Mode: `modes.mode(for: snapshot.bundleID, field: snapshot.field)` from the start snapshot.
  - Command path: unchanged except that the field comes from the snapshot.
  - Dictation path:
    - `pipelinePhase = .cleaning`.
    - If `skipShortUtterances()` and `CleanupFastPath.shouldSkip(transcript)`: `cleaned = transcript`, `skippedCleanup = true`, `cleanupMs = 0`.
    - Else: cleanup as today, including `transcriptFallback` on error.
    - Then `isCancellable = false`, `pipelinePhase = .inserting`, insert, and metrics.
  - `resetIdle()` and `setError` also clear `liveTranscript`, `pipelinePhase`, and `isCancellable`. They keep `retryTranscript`.
- **handleCaptureInterrupted()**: if `.recording`, show the toast "Microphone disconnected — stopped recording" and `Task { await finalizeRecording() }`. The coordinator's later `onFinalizeRecording` → `finalizeRecording()` returns immediately (status gate), and `recordingFinished()` still resets the hotkey machine.
- **Metrics**: replace every `Date()` timing in the pipeline with `ContinuousClock` (`let start = ContinuousClock.now; … start.duration(to: .now)`, converted to milliseconds). `engineID:` in metrics = the session engine's `metricsID`. `firstPartialMs` = recording start → first partial, or nil. The log line in `DictationMetricsStore.record` appends ` firstPartial=<ms or ->ms skipCleanup=<bool>`.
- **Diagnostics**: medians use `kind: .dictation`; insert uses `excludingZero: true`. Add a line `First words: <median firstPartial>` when any dictation has a `firstPartialMs`. The header becomes `Median of N dictations:`.
- **Coordinator (`buildServices`)**:
  - Build `AppleSpeechEngine()` and `WhisperKitEngine(service: transcriber)`, then `TranscriptionEngines(settings:apple:whisperKit:)`. Store it as `self.engines`; keep `self.transcriber` for the existing model prep path.
  - Pass it to the pipeline.
  - Wire `capture.onInterrupted = { [weak pipeline] in pipeline?.handleCaptureInterrupted() }`.
  - Task 6 replaces the prep path; until then the app still prewarms WhisperKit as today. That keeps the app behaving like 0.4.0 with `EngineID.default == .whisperKit`.
- `SupportEnvironment.current(whisperModel:)` callers pass `coordinator.engines?.current.metricsID ?? "(unknown)"`.
- Delete `takeSamples` and the internal accumulation from `AudioCaptureService`, and `Transcribing` everywhere.

Tests (new `CapturePipelineStreamingTests`, plus migration of the existing suites):
- Migrate both existing pipeline suites:
  - Replace `FakeTranscriber` with `FakeTranscriptionEngine` + `FakeEngineProvider`.
  - `FakeCapture` gains a way to deliver samples: in `start()`, if `pendingSamples` is non-empty, call `onSamples?(pendingSamples)` synchronously; keep the default `[0.1, 0.2, 0.3]` but make it 8,000 samples of 0.1 so the 0.3 s minimum is met.
  - Tests that set the transcriber result now set `engine.nextSessions = [session]` with `session.finishResult`.
  - Every existing behavior assertion must still pass unchanged in meaning.
- `streams_partials_into_liveTranscript`: start; `session.emit(.init(stable: "hello", volatile: "wor"))`; await a yield. `state.liveTranscript?.text == "hello wor"`.
- `first_partial_metric_recorded`: emit a partial before finalize; after finalize, `metrics.items.first?.firstPartialMs != nil`.
- `short_recording_is_a_quiet_noop`: 1,600 samples → status `.idle`, no LLM call, no error, the session cancelled.
- `session_open_failure_reports_engine`: `engine.openError = X` → status `.error` whose message starts with "Couldn't start".
- `early_audio_reaches_session_after_open`: `FakeCapture` delivers samples in `start()`, before the session opens; after finalize, `session.appendedSampleCount == 8000`.
- `mode_uses_start_snapshot`: change `frontmost.bundleID` after `startRecording`; the resolved mode matches the start bundle.
- `fast_path_skips_cleanup_when_enabled`: `skipShortUtterances: { true }`, transcript "Sounds good." → no LLM call; injected text "Sounds good."; metrics `skippedCleanup == true`.
- `retryTranscript_set_after_dictation_and_cleared_on_next_start`.
- `isCancellable_true_while_recording_false_after_insert`.
- `capture_interruption_finalizes_with_toast`: call `handleCaptureInterrupted()` while recording; await; the LLM was called once, and `state.toastMessage == "Microphone disconnected — stopped recording"` was observed (check right after the call, before the 2 s clear).
- Metrics store: `median(kind:)` filters; `excludingZero` drops zeros.

Commit: `feat(pipeline): stream audio into engine sessions with live partials`. The body names issue 4.

---

### Task 4c: Transcript scoring, decision rule, bake-off harness

**Files:**
- Create: `voxlineTests/Bakeoff/TranscriptScoring.swift`, `voxlineTests/Bakeoff/BakeoffDecision.swift`, `voxlineTests/Bakeoff/BakeoffFixtures.swift`, `voxlineTests/Bakeoff/EngineBakeoffTests.swift`, `voxlineTests/Bakeoff/TranscriptScoringTests.swift`, `voxlineTests/Bakeoff/BakeoffDecisionTests.swift`
- Create: `scripts/make-synthetic-bakeoff.sh` (executable)

**Interfaces:**
- Consumes: Task 1 types, `AppleSpeechEngine` (Task 4), `WhisperKitEngine` (Task 5a).
- Produces:
  - `enum TranscriptScoring`:
    - `static func normalizedWords(_ s: String) -> [String]`
    - `static func wordErrorRate(reference: String, hypothesis: String) -> Double`
    - `static func compact(_ s: String) -> String`
    - `static func termHits(term: String, reference: String, hypothesis: String) -> (inReference: Int, hits: Int)`
  - `struct EngineScore { let engine: EngineID; let wer: Double; let termMissRate: Double?; let finishMedianMs: Int; let finishP90Ms: Int; let firstPartialMedianMs: Int? }`
  - `enum BakeoffDecision { static func winner(_ scores: [EngineScore]) -> (winner: EngineID?, reason: String) }`

Requirements:
- `normalizedWords`: lowercase; replace every character that is not a letter, digit, apostrophe, or whitespace with a space; split on whitespace.
- `wordErrorRate`: word-level Levenshtein distance / reference word count (0 when both are empty, 1 when the reference is empty and the hypothesis is not).
- `compact`: lowercase, keep only letters and digits.
- `termHits`: count non-overlapping occurrences of `compact(term)` in `compact(reference)` and in `compact(hypothesis)`; `hits = min(refCount, hypCount)`.
- `BakeoffDecision.winner` implements the spec's rule exactly:
  1. Only engines with `engine.isOnDevice` are eligible.
  2. Drop any engine whose WER is more than 0.05 above the best eligible WER.
  3. If no eligible engine has a `termMissRate`, the lowest median finish latency wins.
  4. Otherwise, sort by miss rate. If the top two are within 0.02, the lower median finish wins.
  5. Otherwise, the top engine wins, unless its finish median is more than 300 ms above the runner-up's; then the runner-up wins.
  6. One eligible engine → it wins. None → nil.
  7. `reason` is one sentence naming the deciding clause.
- `BakeoffFixtures`:
  - `static var directory: URL`: `ProcessInfo.processInfo.environment["VOXLINE_BAKEOFF_DIR"]`, else `~/Library/Application Support/voxline/bakeoff`.
  - `static var isPresent: Bool`: the directory contains at least one `.wav` with a sibling `.txt`.
  - `static func load() throws -> (clips: [Clip], terms: [String])`, with `struct Clip { let name: String; let samples: [Float]; let reference: String }`. Read any format with `AVAudioFile` and convert to 16 kHz mono Float32 with `AVAudioConverter`. Terms come from `terms.txt`, one per line, trimmed, blanks skipped.
- `EngineBakeoffTests`: `@Suite(.serialized, .enabled(if: BakeoffFixtures.isPresent)) @MainActor struct EngineBakeoffTests`, with one `@Test func run_bakeoff() async throws`.
  - Build engines: `AppleSpeechEngine()` always; `WhisperKitEngine(service: TranscriptionService(model: .largeV3Turbo))` only if the model is cached.
  - For each engine: `try await engine.prepare { _ in }`. For each clip:
    - open a session with `SessionConfig(vocabularyHints: terms)` and collect partials in a task, recording the time to the first non-empty partial
    - append 1,600-sample chunks with `Task.sleep(for: .milliseconds(Int(100 / speed)))` between them, where `speed = Double(env["VOXLINE_BAKEOFF_SPEED"] ?? "1") ?? 1`
    - time `finish()`
    - compute WER and term hits
  - Produce an `EngineScore` per engine, then the decision.
  - Print a markdown report: a per-engine table (WER %, term miss %, finish median/p90 ms, first-partial median ms), per-clip hypotheses, and the verdict line `**Winner:** <engine> — <reason>`. Write it to `BakeoffFixtures.directory/bakeoff-report.md`.
  - `#expect` only that every engine produced a non-empty transcript for at least half the clips. The bake-off is a measurement, not a pass/fail gate.
- `scripts/make-synthetic-bakeoff.sh <lines.txt> <outdir>`: `set -euo pipefail`. For each non-empty line N, rotate voices through `Samantha Daniel Karen Moira Tessa` (skip a voice if `say -v '?'` doesn't list it). Write `clip-NN.wav` via `say -v "$voice" -o "$out/clip-NN.wav" --data-format=LEF32@16000 "$line"` and `clip-NN.txt` with the line. Print the count. `--help` prints usage.

Tests (CI, no fixtures needed):
- WER: identical → 0; one substitution in 4 words → 0.25; one deletion → 0.25; punctuation and case differences → 0.
- `termHits`: term "LangGraph", reference "I use LangGraph daily", hypothesis "I use lang graph daily" → (1, 1); hypothesis "I use land graph daily" → (1, 0).
- Decision:
  - Two engines with misses 0.10 vs 0.30 and finish 400 vs 150 ms → the first (within the 300 ms margin).
  - 0.10 vs 0.30 with 600 vs 150 → the second.
  - 0.10 vs 0.11 → lower latency.
  - The cloud engine is never the winner even at 0 misses.
  - WER 0.20 vs 0.10 → the first is dropped.

Commit: `test(bakeoff): transcript scoring, decision rule, and fixture-driven engine bake-off`.

---

### Task 6: Engine selection, readiness-driven prepare, Settings picker, wizard

**Files:**
- Modify: `voxline/AppCoordinator.swift`, `voxline/Settings/GeneralSettingsViewModel.swift`, `voxline/Settings/SettingsView.swift`, `voxline/Wizard/WizardViewModel.swift`, `voxline/Wizard/WizardRootView.swift`, `voxline/Wizard/WizardModelDownloadView.swift`, `voxline/Wizard/FirstRunWindowController.swift`, `voxline/Storage/AppPaths.swift`, `voxline/Transcription/TranscriptionService.swift`, `voxline/UI/ModelDownloadWindow.swift` (copy only)
- Create: `voxline/Transcription/EnginePrep.swift`
- Test: `voxlineTests/EnginePrepTests.swift`, `voxlineTests/GeneralSettingsViewModelTests.swift`, `voxlineTests/WizardViewModelTests.swift`, `voxlineTests/WizardStepTests.swift`, `voxlineTests/AppPathsTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngines`, `EngineReadiness`.
- Produces:
  - `enum EnginePrep { enum Plan: Equatable { case warm, download, fail(String) }; static func plan(for readiness: EngineReadiness) -> Plan }` (`.ready` → `.warm`, `.needsPreparation` → `.download`, `.unavailable(r)` → `.fail(r)`).
  - `GeneralSettingsSnapshot.engine: EngineID`.
  - `AppPaths.modelCacheDirectoryIfPresent() -> URL?`, which never creates directories.

Requirements:
- **Coordinator prepare**: `prepareIfNeeded` and `runModelPrepTask` take `engine: any TranscriptionEngine` instead of `transcriber`:
  - `let plan = EnginePrep.plan(for: await engine.readiness())`.
  - `.download` → `.downloadingModel(progress:)` with the download window, as today, then `.preparingModel`.
  - `.warm` → `.preparingModel`; for WhisperKit this covers the compile.
  - Both call `try await engine.prepare(progress:)`, then go idle.
  - `.fail(reason)` → `.error(reason)` and close the window.
  - The readiness call is async, so the window shows only after the plan is known; show it only for `.download`.
  - Keep the single-flight token logic.
- **apply(snapshot)**:
  - If `snapshot.engine != settings-applied engine` (track `appliedEngine`), call `runModelPrepTask(state: inheritsLaunchUI ? appState : nil, engine: engines.engine(for: snapshot.engine), …)`.
  - The WhisperKit model swap stays, but only re-preps when the selected engine is WhisperKit.
  - `engines.current` reads settings, so the next dictation uses the new engine with no extra wiring.
- `TranscriptionService.isModelCached` uses `AppPaths.modelCacheDirectoryIfPresent()`. `cachedModelFolder` returns nil when the base doesn't exist.
- **Settings → Recognition**:
  - `Picker("Engine", selection: $generalVM.engine)` over `EngineID.allCases`, using `displayName`.
  - Below it, when `.whisperKit`: the existing Whisper model picker.
  - When `.openAIRealtime`: `Text("Audio is sent to OpenAI and transcribed with your OpenAI API key.")` in the caption style; if the OpenAI key is empty, also `Text("Add an OpenAI API key in API Keys to use this engine.").foregroundStyle(.orange)`. The VM gets an injected `hasOpenAIKey: () -> Bool` that reads `KeychainAccount.openai` non-empty; tests inject it.
- `GeneralSettingsViewModel`: an `engine` property backed by `AppSettings.transcriptionEngine`, wired into commit, refresh, and Reset (to `EngineID.default`).
- **Wizard**:
  - `WizardViewModel` gets `init(…, skipEngineStep: Bool)`. When true, `.modelDownload` is removed from the step sequence.
  - `FirstRunWindowController.show` computes it from `await engine.readiness() == .ready` before building the VM; restructure to show after an async readiness check.
  - Rename the step's user-facing title to "Speech engine" and the copy to "Preparing <engine display name>…".
  - On that step, the footer gains `Button("Quit Voxline") { NSApp.terminate(nil) }` on the left whenever status is `.error`.

Tests:
- `EnginePrep.plan` mapping (3 cases).
- `AppPaths.modelCacheDirectoryIfPresent()` returns nil for a missing directory and does not create it. Use an injectable base: add `static func modelCacheDirectoryIfPresent(base: URL)`; the public one calls it with the Application Support path without creating anything.
- `GeneralSettingsViewModel`: engine round-trips through settings; `resetToDefaults` sets `EngineID.default`; the snapshot carries the engine.
- Wizard: `skipEngineStep: true` → the steps exclude `.modelDownload`, and advancing from `.apiKey` lands on `.done`.

Commit: `feat(settings): choose the transcription engine; prepare it by readiness`. The body names issue 21.

---

### Task 7: Pill — bottom-center anchoring, live transcript, phases

**Files:**
- Create: `voxline/UI/PillLayout.swift`
- Modify: `voxline/UI/RecordingPillWindow.swift`, `voxline/UI/RecordingPillView.swift`, `voxline/AppCoordinator.swift` (observe `liveTranscript` / `pipelinePhase` changes to call `updateVisibility`, mirroring `observeToastChanges`)
- Test: `voxlineTests/PillLayoutTests.swift`

**Interfaces:**
- Consumes: `AppState.liveTranscript`, `pipelinePhase`, `toastMessage`, `status`, `recordingIsCommand`, `recordingStartedAt`.
- Produces:
  - `enum PillLayout`:
    - `static let wideWidth: CGFloat = 440`
    - `static let compactHeight: CGFloat = 32`
    - `static let textHeight: CGFloat = 64`
    - `static let bottomMargin: CGFloat = 24`
    - `static func size(showsText: Bool, toastWidth: CGFloat?) -> CGSize`
    - `static func origin(for size: CGSize, in visibleFrame: CGRect) -> CGPoint`
    - `static func elapsedLabel(_ seconds: TimeInterval) -> String`
  - Task 8 relies on these `RecordingPillView` hooks: an `onRetry: (() -> Void)?` closure parameter (default nil) and a `retryVisible: Bool` computed by the window.

Requirements:
- `size`: text → (440, 64). Toast → (min(max(toastWidth + 24, 120), 440), 32). Otherwise → (160, 32).
- `origin`: x = `visibleFrame.midX - size.width / 2`, clamped to `[visibleFrame.minX + 8, visibleFrame.maxX - size.width - 8]`; y = `visibleFrame.minY + bottomMargin`.
- `elapsedLabel`: under 60 s → `"%.1fs"`; else `"m:ss"` (e.g. 75 → "1:15").
- Window:
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`.
  - On `updateVisibility`, compute `showsText`: (recording or thinking) and `liveTranscript?.isEmpty == false`.
  - The toast width is measured with `NSAttributedString(string: toast, attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).size().width`.
  - Pick the screen: `NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main`.
  - Re-anchor whenever the frame size changes, or when the pill first becomes visible.
- View:
  - **Recording:** `VStack(alignment: .leading, spacing: 4)` with an `HStack` (waveform, optional "Command", `Spacer()`, elapsed via `PillLayout.elapsedLabel`). If there is a live transcript, below it `transcriptText`: `Text` built from stable (primary) + volatile (`.secondary`) using `TranscriptPartial.join` semantics for the space, `.lineLimit(2)`, `.truncationMode(.head)`, font 12 regular rounded.
  - **Thinking:** `HStack` with `ProgressView().controlSize(.small)` and `Text(phaseLabel)`, where phaseLabel = "Transcribing…" for `.transcribing` or nil, "Cleaning up…" for `.cleaning`, and "Inserting…" for `.inserting`. Below it, the transcript in `.secondary`, if any.
  - **Toast:** unchanged.
  - Background capsule for the compact size; `RoundedRectangle(cornerRadius: 14)` for the text size.

Tests: `size` for the three cases; `origin` centers in (0, 0, 1000, 800) → x = 280 for width 440, y = 24; clamping near a narrow frame; `elapsedLabel` at 5.25 → "5.2s" (format rounding: assert "5.2s" or "5.3s" per `String(format:)` behavior, so compute the expected value with the same format), 75 → "1:15", 600 → "10:00".

Commit: `feat(ui): bottom-center pill with live transcript`. The body names issue 7.

---

### Task 8: Esc cancel, Retry, 5-minute cap

**Files:**
- Create: `voxline/Hotkey/EscapeKeyInterceptor.swift`
- Modify: `voxline/Pipeline/CapturePipeline.swift`, `voxline/Hotkey/HotkeyMonitor.swift`, `voxline/AppCoordinator.swift`, `voxline/UI/RecordingPillWindow.swift`, `voxline/UI/RecordingPillView.swift`, `voxline/MenuBar/MenuBarContent.swift`, `voxline/voxlineApp.swift` (menu closure)
- Test: `voxlineTests/EscapeKeyInterceptorTests.swift`, `voxlineTests/CapturePipelineCancelTests.swift` (new), `voxlineTests/HotkeyMonitorTests.swift`

**Interfaces:**
- Consumes: `AppState.isCancellable`, `retryTranscript`; the pill hooks from Task 7.
- Produces:
  - `CapturePipeline.cancel()`
  - `CapturePipeline.retryLastDictation() async`
  - `var CapturePipeline.wasCancelled: Bool` (true from cancel until the next `startRecording`), used by the coordinator to skip the stop blip
  - `final class EscapeKeyInterceptor: @unchecked Sendable` with:
    - `init(onEscape: @escaping @MainActor () -> Void)`
    - `func install() -> Bool`
    - `func uninstall()`
    - `var isArmed: Bool { get set }`
    - `var isInstalled: Bool`
    - `static func shouldSwallow(type: CGEventType, keyCode: Int64, flags: CGEventFlags, armed: Bool, swallowingKeyUp: Bool) -> (swallow: Bool, escapeFired: Bool, swallowingKeyUp: Bool)`

Requirements:
- **Generation token.** `private var generation: UInt64`, bumped in `startRecording` and in `cancel()`. Every continuation after an `await` in finalize, command, retry, or the partials consumer checks `guard generation == myGeneration else { return }` before touching `state`, history, metrics, the injector, or the clipboard fallback.
- **finalizeRecording returns promptly on cancel.**
  - Split into `finalizeRecording()`, which creates `finalizeWork = Task { await runFinalize(generation: g) }` and then `await withCheckedContinuation { finalizeDone = $0 }`, and `runFinalize`.
  - `runFinalize` resumes `finalizeDone` when it ends (only if not already resumed); `cancel()` resumes it immediately.
  - Use a small helper class `OneShotSignal` (main actor) holding an optional continuation with `fire()`.
- **cancel()**:
  - `.recording` → `capture.stop()`; `sessionTask?.cancel()` plus `session?.cancel()` for an already-open session; `router.close()`; cancel context, selection, and partials tasks; `resetIdle()`; `wasCancelled = true`; `showToast("Cancelled")`.
  - `.thinking` with `isCancellable` → bump generation; `finalizeWork?.cancel()`; `session?.cancel()`. If `state.lastTranscript` is non-empty and this is a dictation: `historyStore.record(cleanedText: t, rawTranscript: t, mode: mode, context: context)` if a mode was resolved (else skip history) and keep `retryTranscript`. Then `resetIdle()`, `showToast("Cancelled")`, fire `finalizeDone`.
  - Otherwise: no-op.
- **retryLastDictation()**:
  - Requires `retryTranscript != nil` and status `.idle` or `.error`.
  - Set `.thinking` with phase `.cleaning`, and `isCancellable = true`.
  - Fresh `contextCapture.capture()`, with `frontmost` + `fieldInspector` read now.
  - Resolve the mode; cleanup (honoring the fast path); `isCancellable = false`; insert (same no-field copy rule); record history; no metrics.
  - Errors use the same messages as finalize. `retryTranscript` is kept.
- **Error + Retry in the pill.** When status becomes `.error(msg)` and `retryTranscript != nil`, the window shows the pill for 8 s with the message's first sentence (up to the first ". ") and a `Button("Retry")`. Set `panel.ignoresMouseEvents = false` only while that Retry state shows, and `true` otherwise. The button calls the coordinator's `retryLastDictation`; any status change hides it. The window needs `state` access and a timer; implement in `RecordingPillWindow` with a `retryUntil: Date?`.
- **Menu.** `MenuBarContent` gets `retryLastDictation: () -> Void` and shows `Button("Retry last dictation") { retryLastDictation() }.disabled(state.retryTranscript == nil || state.status == .recording || state.status == .thinking)` above "Show history…".
- **EscapeKeyInterceptor**:
  - `install()` spawns a `Thread` that creates `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyDown|keyUp, callback:, userInfo:)`, adds its source to that thread's run loop, signals readiness through a semaphore, and runs `CFRunLoopRun()`. Return false if the tap is nil.
  - `uninstall()` disables the tap, removes the source, and stops that run loop.
  - The callback uses `shouldSwallow`:
    - keyDown, keyCode 53, armed, flags contain none of `.maskCommand`, `.maskAlternate`, `.maskControl`, `.maskShift` → swallow; `escapeFired = true`; `swallowingKeyUp = true`.
    - keyUp, keyCode 53, `swallowingKeyUp` → swallow and reset the flag.
    - Otherwise pass.
  - On `tapDisabledByTimeout` / `tapDisabledByUserInput`, re-enable.
  - `isArmed` and `swallowingKeyUp` are lock-protected.
  - `escapeFired` dispatches `onEscape` with `DispatchQueue.main.async { MainActor.assumeIsolated { onEscape() } }`.
- **Coordinator**:
  - Create the interceptor in `installHotkey`; `onEscape` → `pipeline?.cancel()`, then `pillWindow?.updateVisibility`.
  - Install and uninstall it in `reconcileTapWithPermissionsAndEnabled` alongside the hotkey tap.
  - Observe `state.isCancellable` (the `withObservationTracking` re-arm pattern) and mirror it into `interceptor.isArmed`.
  - `onFinalizeRecording` skips `soundPlayer?.playStop()` when `pipeline?.wasCancelled == true`.
- **Cap.** `HotkeyMonitor.maxRecordingDuration = 300`. Add `onMaxDurationReached: (() -> Void)?`, fired just before `.maxDurationElapsed` is fed. The coordinator sets `pipeline.capHit = true`, and the pipeline shows the toast "Stopped at 5 minutes" after its insert (or on the error path) when `capHit`, then resets the flag.

Tests:
- `shouldSwallow` table:
  - armed Esc keyDown → swallow and fire
  - disarmed → pass
  - Esc with ⌘ → pass
  - keyUp after a swallowed down → swallow
  - keyUp with no swallowed down → pass
  - other key → pass
- Pipeline cancel (`FakeTranscriptionSession`, `holdFinish = true`):
  - `cancel_while_recording_discards`: start, cancel → status `.idle`, the session cancelled, the LLM not called, toast "Cancelled", `wasCancelled`.
  - `cancel_while_transcribing_returns_promptly`: start, then `Task { await pipeline.finalizeRecording() }`, yield until `.thinking`, `cancel()`. The finalize task completes within 200 ms (await it with a timeout helper). Status `.idle`; the LLM is never called even after `session.releaseFinish()`.
  - `cancel_while_cleaning_keeps_transcript_in_history_and_retry`: the LLM fake suspends (add an optional `holdCleanup` gate to `FakeLLM`, the same pattern as `holdFinish`); cancel → a history item whose cleaned and raw text both equal the transcript; `retryTranscript` is set; the injector is never called after the LLM is released.
  - `cancel_during_insert_is_ignored`: hold the injector (gate) → cancel → after release, the text is injected and status is idle.
  - `retry_reinserts_last_transcript`: after a successful dictation, `retryLastDictation()` → the LLM is called again with the same transcript, and the injector receives the cleaned text again.
  - `retry_unavailable_without_transcript` → no-op.
- `HotkeyMonitorTests`: the default `maxRecordingDuration == 300`.

Commit: `feat(pipeline): Esc cancels at every stage; Retry last dictation; 5-minute cap`.

---

### Task 9: OpenAI Realtime cloud engine with on-device fallback

**Files:**
- Create: `voxline/Transcription/Engines/OpenAIRealtimeEngine.swift`
- Modify: `voxline/Transcription/TranscriptionEngines.swift`, `voxline/AppCoordinator.swift`, `voxline/Pipeline/CapturePipeline.swift` (fallback), `voxlineTests/Bakeoff/EngineBakeoffTests.swift` (env-gated cloud entry)
- Test: `voxlineTests/OpenAIRealtimeEngineTests.swift`, `voxlineTests/CapturePipelineStreamingTests.swift`

**Interfaces:**
- Consumes: `KeychainStorage`, `KeychainAccount.openai`, Task 1 types.
- Produces:
  - `@MainActor final class OpenAIRealtimeEngine: TranscriptionEngine`, `init(keychain: any KeychainStorage, transport: RealtimeTransportFactory = URLSessionRealtimeTransport.factory)`.
  - `id == .openAIRealtime`; `metricsID == "openai:gpt-4o-transcribe"`; capabilities = all three.
  - `protocol RealtimeTransport: AnyObject, Sendable { func send(_ text: String) async throws; func receive() async throws -> String; func close() }` and `typealias RealtimeTransportFactory = @Sendable (URLRequest) -> any RealtimeTransport`, so tests drive the protocol without a network.
  - `enum PCM16Resampler { static func base64PCM16At24k(from samples16k: [Float]) -> String }`: linear interpolation 16 → 24 kHz, clamp, little-endian Int16.

Requirements:
- **Before writing code**, read OpenAI's current Realtime transcription docs. Use the Context7 MCP tools (`resolve-library-id` "openai", then `query-docs` "realtime transcription session websocket input_audio_buffer gpt-4o-transcribe"); if that fails, WebFetch `https://platform.openai.com/docs/guides/realtime-transcription`. Record the exact items in a doc comment on the engine type:
  - the URL
  - the headers
  - the session-configuration event
  - the append, commit, delta, completed, and error event names
  - the audio format field for 24 kHz PCM16
  - how the prompt and model are set
- Build every message with `JSONSerialization` from dictionaries; parse incoming messages by `type`.
- `readiness()`: key missing or empty → `.unavailable("Add an OpenAI API key in Settings → API Keys to use OpenAI transcription.")`, else `.ready`. `prepare` is a no-op.
- **Session**:
  - Opens the transport and sends session configuration: model `gpt-4o-transcribe`; language from the locale's language code; prompt `"Vocabulary: " + hints.joined(separator: ", ")` when hints are non-empty; server VAD on.
  - `append` resamples and sends append events through a serial internal `AsyncStream` pump, so sends stay ordered off the audio thread.
  - A receive loop accumulates `completed` transcripts by item id in arrival order (stable) and `delta` text for the in-progress item (volatile), and yields partials.
  - `finish()`: wait for the pump to drain; send commit (if the server rejects an empty buffer, treat that error event as benign); wait until every item that received a speech-started/committed event has a completed event, or 10 s; close; return the joined stable text. On timeout, throw `URLError(.timedOut)`.
  - A server `error` event before finish fails `finish()` with an `NSError` carrying the server message; never log the key.
- **Registry**: `TranscriptionEngines.init` gains `openAI: OpenAIRealtimeEngine`, and `.openAIRealtime` maps to it.
- **Pipeline fallback** (in finalize): when `engine.capabilities.contains(.sendsAudioOffDevice)` and the session open or `finish()` throws anything other than `CancellationError`:
  - `let local = engines.engine(for: .onDeviceDefault)`.
  - `local.openSession(same config)`; append `router.retainedAudio` in 16,000-sample chunks; `finish()`.
  - On success, continue with that transcript and `showToast("Cloud transcription failed — used on-device")`; metrics `engineID` = `local.metricsID`.
  - If the fallback also fails, use the existing error.
  - `AppLog.pipeline.error("cloud transcription failed, fell back: …")`.
- **Bake-off**: add `OpenAIRealtimeEngine(keychain: DataProtectionKeychain())` to the engine list only when `env["VOXLINE_BAKEOFF_CLOUD"] == "1"`.

Tests:
- Resampler: 16 samples of 0.5 → 24 Int16 values of round(0.5 × 32767) little-endian, base64-decoded; clamping of 1.5 → 32767.
- Engine with a fake transport that records sent JSON and replays scripted server events:
  - the session config is sent first, with model and prompt
  - appends are base64 audio
  - scripted `delta`/`completed` events yield partials and `finish()` returns the joined completed text
  - an `error` event makes `finish()` throw
  - no key → `.unavailable`
- Pipeline fallback: `FakeEngineProvider` with a cloud fake (capabilities include `.sendsAudioOffDevice`, `finishResult = .failure(URLError(.notConnectedToInternet))`) and a local fake (`finishResult = .success("local text")`) → the LLM receives "local text", the toast was set, and the local session received the retained audio. `FakeEngineProvider` gains `func add(_ engine:)`.

Commit: `feat(transcription): OpenAI Realtime cloud engine with on-device fallback`.

---

### Task 10: Bake-off clip capture flag; synthetic bake-off run; default engine

**Files:**
- Create: `voxline/Diagnostics/BakeoffClipWriter.swift`, `voxlineTests/BakeoffClipWriterTests.swift`
- Modify: `voxline/Storage/AppSettings.swift` (`saveBakeoffClips`, key `voxline.debug.saveBakeoffClips`), `voxline/Pipeline/CapturePipeline.swift` (retain audio when the flag is on; write after a successful dictation), `voxline/Transcription/TranscriptionEngine.swift` (`EngineID.default` per the verdict), `docs/superpowers/specs/2026-10-08-transcription-engine-design.md` (append a "Synthetic bake-off result" section with the report table and verdict)

**Interfaces:**
- Produces: `enum BakeoffClipWriter { static func write(samples: [Float], reference: String, to directory: URL, now: Date) throws -> URL }`. It writes `<yyyyMMdd-HHmmss>.wav` (16 kHz mono Float32 via `AVAudioFile` with `.wav` settings) and `.txt`, and returns the wav URL. It creates the directory.

Requirements:
- The pipeline takes `saveBakeoffClips: @Sendable () -> Bool = { AppSettings().saveBakeoffClips }`. When true at start, the router retains audio. After a successful dictation insert, `try? BakeoffClipWriter.write(samples: router.retainedAudio, reference: cleaned, to: BakeoffFixtures-equivalent directory, now: .now)`. The default directory is `~/Library/Application Support/voxline/bakeoff`; add `AppPaths.bakeoffDirectory()`. Log the path at `.info`.
- Synthetic run (performed by the implementer, results committed in the spec only):
  1. Write 20 lines to `$SCRATCH/lines.txt` (any scratch directory outside the repo): realistic dictation sentences, 8–40 words, each with one or more of the terms in `terms.txt`. Terms: `LangGraph, Argmax, WhisperKit, Voxline, Sparkle, Anthropic, Fredricks, Kubernetes, PostgreSQL, Xcode, SwiftUI, Parakeet, OAuth, Figma, Datadog`.
  2. `scripts/make-synthetic-bakeoff.sh $SCRATCH/lines.txt $SCRATCH/fixtures`; copy `terms.txt` in.
  3. `TEST_RUNNER_VOXLINE_BAKEOFF_DIR=$SCRATCH/fixtures TEST_RUNNER_VOXLINE_BAKEOFF_SPEED=2 xcodebuild test … -only-testing:voxlineTests/EngineBakeoffTests`.
  4. Read `bakeoff-report.md`. Set `EngineID.default` to the verdict's winner. If it changed, run the full suite; tests asserting the old default must use `EngineID.default`, not a literal.
  5. Append the report and verdict to the spec under "## Synthetic bake-off result (provisional)", with one paragraph on caveats (TTS audio, no room noise, Todd's real clips decide).

Tests: `BakeoffClipWriter` writes a readable wav with the right frame count and a matching `.txt`, in a temp dir.

Commits:
- `feat(diagnostics): hidden flag to capture bake-off clips`
- `feat(transcription): default engine from the synthetic bake-off` (include the verdict line in the body)

---

### Task 11: Docs and release notes

**Files:** `CHANGELOG.md` (`[Unreleased]`), `README.md`, `AGENTS.md`, `docs/release/MANUAL_TESTS.md`, `docs/issues.md`, `docs/features.md`, `docs/bakeoff.md` (new, short)

Requirements:
- **CHANGELOG `[Unreleased]`**:
  - Added: engine choice, live transcript, Esc cancel, Retry, cloud engine, bake-off tooling.
  - Changed: pill position, 5-minute cap, metrics.
  - Fixed: issues 4, 7, 8, 14, 18, 21, 23, each in one user-facing line.
  - Do not bump `MARKETING_VERSION`.
- **README**: requirements and feature list mention the engines. Privacy section:
  - audio stays on the Mac with Apple Speech and Whisper
  - with OpenAI it is streamed to OpenAI using the user's key
  - the hidden `voxline.debug.saveBakeoffClips` flag is the only thing that writes audio to disk, and it is off by default
- **AGENTS.md**: the directory map mentions `Transcription/Engines/` and the bake-off (`voxlineTests/Bakeoff`, `docs/bakeoff.md`).
- **MANUAL_TESTS.md**: a "0.5.0 transcription engine" section with every manual item from the spec's Testing section, as checkboxes with concrete steps, plus "record 20 dictations on the default engine and compare medians to the targets table in the spec".
- **docs/bakeoff.md**: how to capture real clips (flag on, dictate, correct the `.txt` files, write `terms.txt`), run the bake-off (exact command), and read the verdict.
- **docs/issues.md**: mark 4, 7, 8, 14, 18, 21, 23 as fixed in 0.5.0, in the existing style for resolved items.
- **docs/features.md**: update the rows for live transcript, cancel, engine choice, and cloud STT.

Commit: `docs: 0.5.0 engine, pill, cancel, and bake-off documentation`.
