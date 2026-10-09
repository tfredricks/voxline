# Live Meeting Transcript Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a meeting records, the timer chip can expand to show the last lines said, labeled Me and Them, transcribed on-device by Apple Speech and discarded at Stop.

**Architecture:** `MeetingRecorder` tees each track's 16 kHz batches to an optional `MeetingSampleObserver` after the PCM writer has them. `LiveMeetingTranscript` is that observer: it opens one Apple Speech `TranscriptionSession` per track, folds their partials through the pure `LiveTranscriptAssembler` into a capped list of labeled lines, and publishes them. `MeetingTimerPanel` hosts a new `MeetingLivePanelView` whose chevron expands the chip into a 360 by 150 point body of those lines. The post-stop pipeline is untouched.

**Tech Stack:** Swift 6, SwiftUI + AppKit, Observation, Swift Testing, Apple `SpeechAnalyzer` through the existing `AppleSpeechEngine`. Xcode 26, macOS 26.

**Spec:** `docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md`

## Global Constraints

- macOS 26 floor, Apple Silicon; `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS'` must stay green in CI (`CODE_SIGNING_ALLOWED=NO`).
- The Xcode project uses file-system-synchronized groups: a new `.swift` file under `voxline/` or `voxlineTests/` joins its target with no `project.pbxproj` edit.
- Live text is never written to disk and never logged. `AppLog.meetings` lines carry session counts and failure reasons only.
- Engine for the live sessions is always Apple Speech (`engines.engine(for: .apple)`), with an empty `SessionConfig()` (no vocabulary hints).
- The live transcript keeps at most 50 lines; labels are `"Me"` (mic) and `"Them"` (system); no labels in mic-only mode.
- Settings keys: `voxline.meetings.liveTranscript` (absent reads as on) and `voxline.meetings.livePanelExpanded` (absent reads as off). Live sessions run only when `showMeetingTimer && meetingLiveTranscript`.
- Expanded body: 360 pt wide, 150 pt tall, grows downward from the chip's top-left corner, clamped to the visible frame.
- Conventional Commits with DCO: every commit is `git commit -s`. No comments that narrate what code does.
- Opt-in tests read env vars with the `TEST_RUNNER_` prefix on the `xcodebuild` command line (`TEST_RUNNER_VOXLINE_LIVE_SPIKE=1` reaches the runner as `VOXLINE_LIVE_SPIKE=1`).
- Runs of a single suite: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/<SuiteName> 2>&1 | tail -40`. "Expected: PASS" below means the `** TEST SUCCEEDED **` line appears and no `error:` line names the suite.

---

## File structure

| File | Responsibility |
|---|---|
| `voxline/Meetings/LiveTranscriptAssembler.swift` (new) | `LiveLine`, `LiveTranscript`, and the pure `LiveTranscriptAssembler` that turns per-track `TranscriptPartial`s into capped labeled lines. |
| `voxline/Meetings/LiveMeetingTranscript.swift` (new) | `LiveAvailability`, `LiveMeetingTranscribing` protocol, `LiveMeetingTranscript` (sessions, consumption tasks, the lock-protected session table). |
| `voxline/Meetings/MeetingLivePanelView.swift` (new) | The chip header with chevron and the expanded body of lines. |
| `voxline/Meetings/MeetingAudioSource.swift` | Gains the `MeetingSampleObserver` protocol. |
| `voxline/Meetings/MeetingRecorder.swift` | `Track.liveLabel`; `observer` init parameter; the tee in `startSource`. |
| `voxline/Meetings/MeetingController.swift` | `makeLiveTranscript` factory, `makeRecorder` takes the observer, `liveTranscript` property, start/stop/lost wiring. |
| `voxline/Meetings/MeetingTimerLayout.swift` | `resized(_:to:visibleFrame:)`. |
| `voxline/Meetings/MeetingTimerPanel.swift` | Hosts `MeetingLivePanelView`, owns the expanded state, resizes the panel. |
| `voxline/Storage/AppSettings.swift` | Two keys and `liveTranscriptEnabled`. |
| `voxline/Settings/MeetingSettingsViewModel.swift`, `voxline/Settings/Pages/MeetingsSettingsPage.swift` | The toggle. |
| `voxline/AppCoordinator.swift` | Builds the factories; passes the live transcript to the panel. |
| `voxlineTests/LiveTranscriptSpikeTests.swift` (new, opt-in) | The two measurement gates. |
| `voxlineTests/LiveTranscriptAssemblerTests.swift`, `voxlineTests/LiveMeetingTranscriptTests.swift` (new) | Unit tests. |
| `voxlineTests/MeetingRecorderTests.swift`, `MeetingControllerTests.swift`, `MeetingTimerLayoutTests.swift`, `MeetingSettingsTests.swift`, `MeetingSettingsViewModelTests.swift` | Extended. |
| `CHANGELOG.md`, `README.md`, `AGENTS.md`, `docs/release/MANUAL_TESTS.md`, the spec | Docs. |

---

### Task 1: Measurement spike (the gate)

**Files:**
- Create: `voxlineTests/LiveTranscriptSpikeTests.swift`
- Modify: `docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md` (append "Spike results")

**Interfaces:**
- Consumes: `AppleSpeechEngine`, `TranscriptionSession`, `SpeechClipFixture.synthesize(_:voice:)`, `MeetingRecorder`, `FakeMeetingSource` (in `MeetingRecorderTests.swift`), `PCMTrackReader.sampleCount(at:)`, `Tag.integration`.
- Produces: numbers appended to the spec; a decision on whether Task 5 needs the 10-minute session restart.

- [ ] **Step 1: Write the opt-in spike suite**

```swift
// voxlineTests/LiveTranscriptSpikeTests.swift
import Darwin
import Foundation
import Testing
@testable import voxline

/// Measurement gates from the live-transcript spec. Opt-in; results are
/// appended to the spec by hand.
@MainActor
@Suite(
    .tags(.integration),
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["VOXLINE_LIVE_SPIKE"] == "1",
        "Set TEST_RUNNER_VOXLINE_LIVE_SPIKE=1 to run the live transcript spike."
    )
)
struct LiveTranscriptSpikeTests {

    private static let sentences = [
        ("Samantha", "Let's review the quarterly numbers before the pricing call with Acme."),
        ("Daniel", "The onboarding funnel improved after we shipped the new checkout flow."),
        ("Samantha", "I think Priya should own the follow-up with the Argmax team."),
        ("Daniel", "We decided to postpone the migration until the second week of November."),
    ]
    private static let chunk = 1_600 // 100 ms at 16 kHz

    private static func clip() throws -> [Float] {
        try sentences.flatMap { voice, text in
            try SpeechClipFixture.synthesize(text + " [[slnc 800]]", voice: voice)
        }
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : .nan
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Gate 1: an hour of audio through one session at 4x real time. Finals
    /// must keep arriving in the last five minutes and memory must stay flat.
    @Test(.timeLimit(.minutes(30)))
    func hour_long_session_keeps_finalizing() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let clip = try Self.clip()
        let clipSeconds = Double(clip.count) / 16_000
        let repeats = Int((3_600 / clipSeconds).rounded(.up))

        let session = try await engine.openSession(SessionConfig())
        let stableLengthByMinute = LockedBox<[Int: Int]>([:])
        let fedSamples = LockedBox<Int>(0)
        let collector = Task {
            for await partial in session.partials {
                let minute = fedSamples.read() / (16_000 * 60)
                stableLengthByMinute.mutate { $0[minute] = partial.stable.count }
            }
        }

        let memoryAtStart = Self.residentMB()
        let wallStart = Date()
        for _ in 0..<repeats {
            var offset = 0
            while offset < clip.count {
                let end = min(offset + Self.chunk, clip.count)
                session.append(Array(clip[offset..<end]))
                fedSamples.mutate { $0 += end - offset }
                offset = end
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let feedSeconds = Date().timeIntervalSince(wallStart)
        try await Task.sleep(for: .seconds(5))
        let memoryAtEnd = Self.residentMB()
        let cancelStart = Date()
        session.cancel()
        await collector.value
        let cancelMs = Date().timeIntervalSince(cancelStart) * 1_000

        let byMinute = stableLengthByMinute.read()
        let lastFiveMinutes = (55...60).compactMap { byMinute[$0] }
        let before = byMinute.filter { $0.key < 55 }.values.max() ?? 0
        print("[spike] fed \(feedSeconds.rounded()) s wall for 3600 s audio; memory \(memoryAtStart.rounded()) → \(memoryAtEnd.rounded()) MB; cancel \(cancelMs.rounded()) ms")
        print("[spike] stable length by minute: \(byMinute.sorted { $0.key < $1.key })")
        #expect((lastFiveMinutes.max() ?? 0) > before, "no new final text in the last five minutes")
        #expect(memoryAtEnd - memoryAtStart < 100, "resident memory grew \(memoryAtEnd - memoryAtStart) MB")
        #expect(cancelMs < 2_000)
    }

    /// Gate 2: two sessions at real time for five minutes beside a recorder
    /// writing the same audio. CPU under a quarter of one core; no samples lost.
    @Test(.timeLimit(.minutes(10)))
    func two_sessions_real_time_cost() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let clip = try Self.clip()
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let mic = FakeMeetingSource()
        let system = FakeMeetingSource()
        let recorder = MeetingRecorder(mic: mic, system: system, directory: MeetingDirectory(url: url))
        try recorder.start()
        let micSession = try await engine.openSession(SessionConfig())
        let systemSession = try await engine.openSession(SessionConfig())
        let drains = [micSession, systemSession].map { session in Task { for await _ in session.partials {} } }

        let cpuStart = Self.cpuSeconds()
        let wallStart = Date()
        var fed = 0
        var offset = 0
        while Date().timeIntervalSince(wallStart) < 300 {
            let end = min(offset + Self.chunk, clip.count)
            let batch = Array(clip[offset..<end])
            mic.emit(batch)
            system.emit(batch)
            micSession.append(batch)
            systemSession.append(batch)
            fed += batch.count
            offset = end == clip.count ? 0 : end
            try await Task.sleep(for: .milliseconds(100))
        }
        let cpuFraction = (Self.cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart)
        recorder.stop()
        micSession.cancel()
        systemSession.cancel()
        for drain in drains { await drain.value }

        print("[spike] two sessions + recorder: CPU \(Int(cpuFraction * 100)) % of one core over 5 min")
        #expect(cpuFraction < 0.25)
        #expect(PCMTrackReader.sampleCount(at: MeetingDirectory(url: url).micPCM) == fed)
        #expect(PCMTrackReader.sampleCount(at: MeetingDirectory(url: url).systemPCM) == fed)
    }
}
```

- [ ] **Step 2: Build the test target to confirm it compiles while skipped**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveTranscriptSpikeTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` with the suite reported as skipped (the `.enabled` trait).

- [ ] **Step 3: Run the spike**

Run: `TEST_RUNNER_VOXLINE_LIVE_SPIKE=1 xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveTranscriptSpikeTests 2>&1 | grep -E '\[spike\]|passed|failed|error:' | tail -30`
Expected: both tests pass and four `[spike]` lines print the numbers. If gate 1's memory assertion fails but the per-minute table shows finals arriving throughout, rerun with the feed sleep at `.milliseconds(50)` (2x real time) once: an input backlog, not the analyzer, was the growth. If finals stop before minute 55, the 10-minute restart fallback in Task 5 is required; note it in the results.

- [ ] **Step 4: Append the results to the spec**

Append to `docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md`, after "Out of scope":

```markdown
## Spike results (2026-10-09)

Machine: <model>, <RAM>. Audio: four `say` sentences in two voices, tiled to 60 min.

| Gate | Result | Pass |
|---|---|---|
| Hour-long session: finals in minutes 55–60 | <yes/no>; stable length <n> → <n> chars | <✓/✗> |
| Hour-long session: resident memory | <start> → <end> MB | <✓/✗> |
| Hour-long session: `cancel()` | <n> ms | <✓/✗> |
| Two sessions + recorder, 5 min real time | <n> % of one core; no samples lost | <✓/✗> |

Decision: <sessions run uninterrupted for the hour / sessions restart every 10 minutes (Task 5 fallback)>; <live transcript defaults on / off (gate 2 fallback)>.
```

Fill every `<…>` from the printed lines. No placeholders may remain.

- [ ] **Step 5: Commit**

```bash
git add voxlineTests/LiveTranscriptSpikeTests.swift docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md
git commit -s -m "test(meetings): live transcript spike and its results"
```

---

### Task 2: LiveTranscriptAssembler

**Files:**
- Create: `voxline/Meetings/LiveTranscriptAssembler.swift`
- Create: `voxlineTests/LiveTranscriptAssemblerTests.swift`
- Modify: `voxline/Meetings/MeetingRecorder.swift:45` (the `Track` enum)

**Interfaces:**
- Consumes: `TranscriptPartial` (`stable`, `volatile`, `TranscriptPartial.join(_:_:)`), `MeetingRecorder.Track`.
- Produces:
  - `extension MeetingRecorder.Track { var liveLabel: String }` → `"Me"` / `"Them"`.
  - `struct LiveLine: Equatable, Identifiable, Sendable { let id: Int; var track: MeetingRecorder.Track; var text: String }`
  - `struct LiveTranscript: Equatable, Sendable { var lines: [LiveLine]; var volatile: [MeetingRecorder.Track: String] }`
  - `struct LiveTranscriptAssembler { static let defaultMaxLines = 50; init(maxLines: Int = 50); private(set) var transcript: LiveTranscript; mutating func apply(_ partial: TranscriptPartial, track: MeetingRecorder.Track) -> LiveTranscript }`

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/LiveTranscriptAssemblerTests.swift
import Testing
@testable import voxline

@Suite struct LiveTranscriptAssemblerTests {

    private typealias Track = MeetingRecorder.Track

    @Test func growing_stable_text_becomes_one_line() {
        var assembler = LiveTranscriptAssembler()
        let transcript = assembler.apply(TranscriptPartial(stable: " Hello there."), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello there.")])
        #expect(transcript.volatile.isEmpty)
    }

    @Test func same_track_growth_joins_the_newest_line() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello there."), track: .mic)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello there. How are you?"), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello there. How are you?")])
    }

    @Test func other_track_growth_starts_a_new_line() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello."), track: .mic)
        _ = assembler.apply(TranscriptPartial(stable: "Hi."), track: .system)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello. Ready?"), track: .mic)
        #expect(transcript.lines == [
            LiveLine(id: 0, track: .mic, text: "Hello."),
            LiveLine(id: 1, track: .system, text: "Hi."),
            LiveLine(id: 2, track: .mic, text: "Ready?"),
        ])
    }

    @Test func volatile_is_kept_per_track_and_cleared_when_it_settles() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "", volatile: "I thi"), track: .mic)
        let both = assembler.apply(TranscriptPartial(stable: "", volatile: "So "), track: .system)
        #expect(both.volatile == [.mic: "I thi", .system: "So"])
        #expect(both.lines.isEmpty)
        let settled = assembler.apply(TranscriptPartial(stable: "I think so.", volatile: ""), track: .mic)
        #expect(settled.volatile == [.system: "So"])
        #expect(settled.lines == [LiveLine(id: 0, track: .mic, text: "I think so.")])
    }

    @Test func non_extending_stable_text_is_a_fresh_segment() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "First session."), track: .mic)
        _ = assembler.apply(TranscriptPartial(stable: "Reply."), track: .system)
        let transcript = assembler.apply(TranscriptPartial(stable: "New session."), track: .mic)
        #expect(transcript.lines.map(\.text) == ["First session.", "Reply.", "New session."])
    }

    @Test func blank_growth_is_ignored() {
        var assembler = LiveTranscriptAssembler()
        _ = assembler.apply(TranscriptPartial(stable: "Hello."), track: .mic)
        let transcript = assembler.apply(TranscriptPartial(stable: "Hello.  \n"), track: .mic)
        #expect(transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello.")])
        let empty = LiveTranscriptAssembler().transcript
        #expect(empty == LiveTranscript())
    }

    @Test func oldest_line_is_dropped_past_the_cap_and_ids_stay_monotonic() {
        var assembler = LiveTranscriptAssembler(maxLines: 3)
        var stable: [Track: String] = [.mic: "", .system: ""]
        for i in 0..<4 {
            let track: Track = i % 2 == 0 ? .mic : .system
            stable[track]! += " line \(i)."
            _ = assembler.apply(TranscriptPartial(stable: stable[track]!), track: track)
        }
        let transcript = assembler.transcript
        #expect(transcript.lines.map(\.id) == [1, 2, 3])
        #expect(transcript.lines.map(\.text) == ["line 1.", "line 2.", "line 3."])
    }

    @Test func default_cap_is_fifty() {
        #expect(LiveTranscriptAssembler.defaultMaxLines == 50)
        #expect(LiveTranscriptAssembler().maxLines == 50)
    }

    @Test func track_labels() {
        #expect(Track.mic.liveLabel == "Me")
        #expect(Track.system.liveLabel == "Them")
    }
}
```

Note on `oldest_line_is_dropped…`: the four growths alternate tracks, so each is a new line (ids 0–3), and the cap of 3 drops id 0.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveTranscriptAssemblerTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile errors `cannot find 'LiveTranscriptAssembler' in scope`, `LiveLine`, `liveLabel`.

- [ ] **Step 3: Write the implementation**

Add to `MeetingRecorder.swift`, directly after `enum Track { case mic, system }`:

```swift
    enum Track { case mic, system }
```
stays as is; append at the bottom of the file:

```swift
extension MeetingRecorder.Track {
    /// The live transcript's speaker label for this track.
    var liveLabel: String { self == .mic ? "Me" : "Them" }
}
```

Create `voxline/Meetings/LiveTranscriptAssembler.swift`:

```swift
import Foundation

struct LiveLine: Equatable, Identifiable, Sendable {
    let id: Int
    var track: MeetingRecorder.Track
    var text: String
}

struct LiveTranscript: Equatable, Sendable {
    var lines: [LiveLine] = []
    var volatile: [MeetingRecorder.Track: String] = [:]
}

/// Turns each track's running `TranscriptPartial` into labeled lines for the
/// live panel. A finished segment joins the newest line when that line is
/// from the same track; a `stable` that does not extend the previous one
/// (a restarted session) is taken whole as a new segment.
struct LiveTranscriptAssembler {

    static let defaultMaxLines = 50

    let maxLines: Int
    private(set) var transcript = LiveTranscript()
    private var stable: [MeetingRecorder.Track: String] = [:]
    private var nextID = 0

    init(maxLines: Int = LiveTranscriptAssembler.defaultMaxLines) {
        self.maxLines = maxLines
    }

    mutating func apply(_ partial: TranscriptPartial, track: MeetingRecorder.Track) -> LiveTranscript {
        let previous = stable[track] ?? ""
        let segment = partial.stable.hasPrefix(previous)
            ? String(partial.stable.dropFirst(previous.count))
            : partial.stable
        stable[track] = partial.stable
        let text = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { append(text, track: track) }
        let tail = partial.volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.volatile[track] = tail.isEmpty ? nil : tail
        return transcript
    }

    private mutating func append(_ text: String, track: MeetingRecorder.Track) {
        if let last = transcript.lines.indices.last, transcript.lines[last].track == track {
            transcript.lines[last].text = TranscriptPartial.join(transcript.lines[last].text, text)
            return
        }
        transcript.lines.append(LiveLine(id: nextID, track: track, text: text))
        nextID += 1
        if transcript.lines.count > maxLines {
            transcript.lines.removeFirst(transcript.lines.count - maxLines)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveTranscriptAssemblerTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Meetings/LiveTranscriptAssembler.swift voxline/Meetings/MeetingRecorder.swift voxlineTests/LiveTranscriptAssemblerTests.swift
git commit -s -m "feat(meetings): assemble live transcript lines from per-track partials"
```

---

### Task 3: Settings keys and the toggle

**Files:**
- Modify: `voxline/Storage/AppSettings.swift:8-33` (keys) and `:283-289` (after `showMeetingTimer`)
- Modify: `voxline/Settings/MeetingSettingsViewModel.swift:16,40`
- Modify: `voxline/Settings/Pages/MeetingsSettingsPage.swift:18`
- Modify: `voxlineTests/MeetingSettingsTests.swift`, `voxlineTests/MeetingSettingsViewModelTests.swift:50-65`
- Modify: `docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md` (Settings section)

**Interfaces:**
- Produces: `AppSettings.meetingLiveTranscript: Bool` (absent → true), `AppSettings.meetingLivePanelExpanded: Bool` (absent → false), `AppSettings.liveTranscriptEnabled: Bool` (`showMeetingTimer && meetingLiveTranscript`), `MeetingSettingsViewModel.liveTranscript: Bool`.

- [ ] **Step 1: Write the failing tests**

Append to `voxlineTests/MeetingSettingsTests.swift` inside the suite:

```swift
    @Test func live_transcript_defaults_on_and_round_trips() {
        var settings = makeSettings()
        #expect(settings.meetingLiveTranscript)
        #expect(settings.liveTranscriptEnabled)
        settings.meetingLiveTranscript = false
        #expect(!settings.meetingLiveTranscript)
        #expect(!settings.liveTranscriptEnabled)
    }

    @Test func live_transcript_needs_the_timer() {
        var settings = makeSettings()
        settings.showMeetingTimer = false
        #expect(settings.meetingLiveTranscript)
        #expect(!settings.liveTranscriptEnabled)
    }

    @Test func live_panel_expanded_defaults_off_and_round_trips() {
        var settings = makeSettings()
        #expect(!settings.meetingLivePanelExpanded)
        settings.meetingLivePanelExpanded = true
        #expect(settings.meetingLivePanelExpanded)
    }
```

Append to `voxlineTests/MeetingSettingsViewModelTests.swift` inside the suite:

```swift
    @Test func live_transcript_toggle_writes_through_and_reports() {
        let changes = LockedBox(0)
        let vm = model(changes: changes)
        #expect(vm.liveTranscript)
        vm.liveTranscript = false
        #expect(!AppSettings(defaults: defaults).meetingLiveTranscript)
        #expect(changes.read() == 1)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingSettingsTests -only-testing:voxlineTests/MeetingSettingsViewModelTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile errors: `value of type 'AppSettings' has no member 'meetingLiveTranscript'`, `… 'liveTranscript'`.

- [ ] **Step 3: Implement the settings**

In `AppSettings.Key`, after `static let meetingShowTimer = "voxline.meetings.showTimer"`:

```swift
        static let meetingLiveTranscript = "voxline.meetings.liveTranscript"
        static let meetingLivePanelExpanded = "voxline.meetings.livePanelExpanded"
```

After the `showMeetingTimer` property:

```swift
    /// Settings → Meetings → Live transcript. Absent reads as on.
    var meetingLiveTranscript: Bool {
        get {
            guard defaults.object(forKey: Key.meetingLiveTranscript) != nil else { return true }
            return defaults.bool(forKey: Key.meetingLiveTranscript)
        }
        set { defaults.set(newValue, forKey: Key.meetingLiveTranscript) }
    }

    /// Live sessions run only when there is a timer chip to show them in.
    var liveTranscriptEnabled: Bool { showMeetingTimer && meetingLiveTranscript }

    /// Whether the timer chip was last left expanded to the live transcript.
    var meetingLivePanelExpanded: Bool {
        get { defaults.bool(forKey: Key.meetingLivePanelExpanded) }
        set { defaults.set(newValue, forKey: Key.meetingLivePanelExpanded) }
    }
```

In `MeetingSettingsViewModel`, after the `showTimer` line:

```swift
    var liveTranscript: Bool { didSet { settings.meetingLiveTranscript = liveTranscript; onChange() } }
```

and in `init`, after `showTimer = settings.showMeetingTimer`:

```swift
        liveTranscript = settings.meetingLiveTranscript
```

In `MeetingsSettingsPage`, after `Toggle("Show recording timer", isOn: $model.showTimer)`:

```swift
                Toggle("Live transcript", isOn: $model.liveTranscript)
                    .disabled(!model.showTimer)
                Text("Shows the last few things said in the recording timer. Transcribed on this Mac with Apple Speech; nothing is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingSettingsTests -only-testing:voxlineTests/MeetingSettingsViewModelTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Correct the spec's Reset to Defaults sentence**

In the spec's "Settings" section, replace:

```
Reset to Defaults restores the toggle to on and does not touch the remembered
expanded state. A change mid-meeting applies at the next meeting; the caption
does not need to say so.
```

with:

```
Reset to Defaults does not touch meeting settings, as today. A change
mid-meeting applies at the next meeting; the caption does not need to say so.
```

- [ ] **Step 6: Commit**

```bash
git add voxline/Storage/AppSettings.swift voxline/Settings/MeetingSettingsViewModel.swift voxline/Settings/Pages/MeetingsSettingsPage.swift voxlineTests/MeetingSettingsTests.swift voxlineTests/MeetingSettingsViewModelTests.swift docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md
git commit -s -m "feat(settings): Live transcript toggle and remembered panel state"
```

---

### Task 4: Sample observer on the recorder

**Files:**
- Modify: `voxline/Meetings/MeetingAudioSource.swift` (append the protocol)
- Modify: `voxline/Meetings/MeetingRecorder.swift:53-82` (init) and `:148-162` (`startSource`)
- Modify: `voxlineTests/MeetingRecorderTests.swift`

**Interfaces:**
- Produces:
  - `protocol MeetingSampleObserver: AnyObject, Sendable { func samples(_ samples: [Float], track: MeetingRecorder.Track) }`
  - `MeetingRecorder.init(mic:system:directory:cap:sleep:clock:observer:)` with `observer: MeetingSampleObserver? = nil` as the last parameter.

- [ ] **Step 1: Write the failing tests**

Add after `FakeMeetingSource` in `voxlineTests/MeetingRecorderTests.swift`:

```swift
final class FakeSampleObserver: MeetingSampleObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(MeetingRecorder.Track, [Float])] = []

    func samples(_ samples: [Float], track: MeetingRecorder.Track) {
        lock.withLock { received.append((track, samples)) }
    }

    func batches(_ track: MeetingRecorder.Track) -> [[Float]] {
        lock.withLock { received.filter { $0.0 == track }.map(\.1) }
    }
}
```

Change the suite's `makeRecorder` helper to accept an observer:

```swift
    private func makeRecorder(
        cap: Duration = MeetingRecorder.defaultCap,
        system: FakeMeetingSource? = nil,
        observer: MeetingSampleObserver? = nil
    ) -> MeetingRecorder {
        let clock = clock
        return MeetingRecorder(
            mic: mic, system: system ?? self.system, directory: directory, cap: cap,
            sleep: { @MainActor in try await clock.sleep($0) },
            clock: { clock.now },
            observer: observer
        )
    }
```

Add these tests inside the suite:

```swift
    @Test func observer_receives_each_batch_per_track_after_the_writer() async throws {
        let observer = FakeSampleObserver()
        let recorder = makeRecorder(observer: observer)
        try recorder.start()
        mic.emit([0.5, 0.5])
        system.emit([0.25])
        mic.emit([0.1])
        recorder.stop()
        #expect(observer.batches(.mic) == [[0.5, 0.5], [0.1]])
        #expect(observer.batches(.system) == [[0.25]])
        #expect(PCMTrackReader.sampleCount(at: directory.micPCM) == 3)
    }

    @Test func observer_does_not_receive_silence_padding() async throws {
        let observer = FakeSampleObserver()
        let recorder = makeRecorder(observer: observer)
        try recorder.start()
        await settle()
        await clock.advance(by: .seconds(3))
        system.emit([Float](repeating: 0.1, count: 1_600))
        recorder.stop()
        #expect(PCMTrackReader.sampleCount(at: directory.systemPCM) == 48_000)
        #expect(observer.batches(.system).map(\.count) == [1_600])
    }

    @Test func restart_keeps_feeding_the_same_observer() async throws {
        let observer = FakeSampleObserver()
        let recorder = makeRecorder(observer: observer)
        try recorder.start()
        await settle()
        mic.emit([0.2])
        mic.fail()
        await settle()
        await clock.advance(by: .milliseconds(500))
        #expect(mic.startCount == 2)
        mic.emit([0.3])
        recorder.stop()
        #expect(observer.batches(.mic) == [[0.2], [0.3]])
    }

    @Test func nothing_reaches_the_observer_after_stop() async throws {
        let observer = FakeSampleObserver()
        let recorder = makeRecorder(observer: observer)
        try recorder.start()
        recorder.stop()
        mic.emit([0.9])
        #expect(observer.batches(.mic).isEmpty)
    }

    @Test func tracks_are_identical_with_and_without_an_observer() async throws {
        let other = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherDirectory = MeetingDirectory(url: other)
        let plainMic = FakeMeetingSource(), plainSystem = FakeMeetingSource()
        let clock = clock
        let plain = MeetingRecorder(
            mic: plainMic, system: plainSystem, directory: otherDirectory,
            sleep: { @MainActor in try await clock.sleep($0) }, clock: { clock.now }
        )
        let observed = makeRecorder(observer: FakeSampleObserver())
        try plain.start()
        try observed.start()
        for batch in [[0.1, 0.2], [0.3], [0.4, 0.5, 0.6]] as [[Float]] {
            plainMic.emit(batch); mic.emit(batch)
            plainSystem.emit(batch); system.emit(batch)
        }
        plain.stop()
        observed.stop()
        #expect(try Data(contentsOf: otherDirectory.micPCM) == Data(contentsOf: directory.micPCM))
        #expect(try Data(contentsOf: otherDirectory.systemPCM) == Data(contentsOf: directory.systemPCM))
    }
```

Note on `nothing_reaches_the_observer_after_stop`: `FakeMeetingSource.stop()` only counts; its `emit` after stop still calls the stored closure. The recorder must therefore drop batches itself once stopped, which is what the implementation's `isRecording` check does.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingRecorderTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile errors `cannot find type 'MeetingSampleObserver' in scope`, `extra argument 'observer' in call`.

- [ ] **Step 3: Implement the observer**

Append to `voxline/Meetings/MeetingAudioSource.swift`:

```swift
/// Receives each track's batches after the track's writer has them, on the
/// source's background thread. Must not block; silence padding is not
/// forwarded.
protocol MeetingSampleObserver: AnyObject, Sendable {
    func samples(_ samples: [Float], track: MeetingRecorder.Track)
}
```

In `MeetingRecorder`, add a stored property after `private let clock: @Sendable () -> Duration`:

```swift
    private let observer: MeetingSampleObserver?
    private let live = LiveFlag()
```

Extend `init` with a trailing parameter and assignment:

```swift
    init(
        mic: MeetingAudioSource,
        system: MeetingAudioSource?,
        directory: MeetingDirectory,
        cap: Duration = MeetingRecorder.defaultCap,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Duration = MeetingRecorder.wallClock(),
        observer: MeetingSampleObserver? = nil
    ) {
        self.mic = mic
        self.system = system
        self.directory = directory
        self.cap = cap
        self.sleep = sleep
        self.clock = clock
        self.observer = observer
    }
```

In `start()`, set `live.set(true)` on the line after `isRecording = true`. In `stop(reason:)`, set `live.set(false)` on the line after `isRecording = false`.

Replace `startSource(_:)`:

```swift
    private func startSource(_ track: Track) throws {
        guard let source = source(track), let writer = writers[track] else { return }
        let clock = clock
        let startedAt = startedAt
        let observer = observer
        let live = live
        try source.start(
            onSamples: { batch in
                let expected = Self.expectedSamples(after: clock() - startedAt)
                if writer.sampleCount + batch.count < expected - Self.lagToleranceSamples {
                    writer.padSilence(toSampleCount: expected - batch.count)
                }
                writer.append(batch)
                if live.value { observer?.samples(batch, track: track) }
            },
            onFailure: { [weak self] _ in Task { @MainActor in self?.handleFailure(track) } }
        )
    }
```

Append to the bottom of `MeetingRecorder.swift`:

```swift
/// Whether the recording is live, readable from the audio thread.
private final class LiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set(_ newValue: Bool) { lock.withLock { flag = newValue } }
}
```

`start()` sets the flag after the mic source has started, so a batch that arrives between `source.start` and `isRecording = true` reaches the writer (as today) but not the observer; the live transcript opens its sessions later anyway.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingRecorderTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`, every pre-existing recorder test still passing.

- [ ] **Step 5: Commit**

```bash
git add voxline/Meetings/MeetingAudioSource.swift voxline/Meetings/MeetingRecorder.swift voxlineTests/MeetingRecorderTests.swift
git commit -s -m "feat(meetings): tee each track's samples to an optional observer"
```

---

### Task 5: LiveMeetingTranscript

**Files:**
- Create: `voxline/Meetings/LiveMeetingTranscript.swift`
- Create: `voxlineTests/LiveMeetingTranscriptTests.swift`

**Interfaces:**
- Consumes: `TranscriptionEngine` (`readiness()`, `prepare(progress:)`, `openSession(_:)`), `TranscriptionSession` (`append`, `partials`, `cancel`), `LiveTranscriptAssembler`, `MeetingSampleObserver`, `AppLog.meetings`.
- Produces:
  - `enum LiveAvailability: Equatable, Sendable { case preparing, listening, unavailable(String) }`
  - `@MainActor protocol LiveMeetingTranscribing: AnyObject, MeetingSampleObserver { var transcript: LiveTranscript { get }; var availability: LiveAvailability { get }; var showsLabels: Bool { get }; func start(tracks: Set<MeetingRecorder.Track>); func trackLost(_ track: MeetingRecorder.Track); func stop() }`
  - `@Observable @MainActor final class LiveMeetingTranscript: LiveMeetingTranscribing { init(engine: any TranscriptionEngine); private(set) var startTask: Task<Void, Never>? }`

- [ ] **Step 1: Write the failing tests**

```swift
// voxlineTests/LiveMeetingTranscriptTests.swift
import Foundation
import Testing
@testable import voxline

@MainActor
@Suite struct LiveMeetingTranscriptTests {

    private let engine = FakeTranscriptionEngine(id: .apple, metricsID: "apple:test")

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func started(_ tracks: Set<MeetingRecorder.Track> = [.mic, .system]) async -> LiveMeetingTranscript {
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: tracks)
        await live.startTask?.value
        return live
    }

    @Test func opens_one_session_per_track_with_no_hints() async {
        let live = await started()
        #expect(engine.sessions.count == 2)
        #expect(engine.openedConfigs == [SessionConfig(), SessionConfig()])
        #expect(live.availability == .listening)
        #expect(live.showsLabels)
    }

    @Test func mic_only_hides_labels() async {
        let live = await started([.mic])
        #expect(engine.sessions.count == 1)
        #expect(!live.showsLabels)
    }

    @Test func samples_reach_the_matching_session() async {
        let live = await started()
        live.samples([0.1, 0.2], track: .mic)
        live.samples([0.3], track: .system)
        #expect(engine.sessions[0].appended == [[0.1, 0.2]])
        #expect(engine.sessions[1].appended == [[0.3]])
    }

    @Test func samples_before_open_are_dropped() async {
        engine.holdsOpen = true
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: [.mic])
        live.samples([0.5], track: .mic)
        engine.releaseOpen()
        await live.startTask?.value
        #expect(engine.sessions[0].appended.isEmpty)
    }

    @Test func partials_update_the_transcript() async {
        let live = await started()
        engine.sessions[0].emit(TranscriptPartial(stable: "Hello.", volatile: ""))
        await settle()
        engine.sessions[1].emit(TranscriptPartial(stable: "", volatile: "Hi th"))
        await settle()
        #expect(live.transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello.")])
        #expect(live.transcript.volatile == [.system: "Hi th"])
    }

    @Test func lost_track_cancels_only_its_session() async {
        let live = await started()
        live.trackLost(.system)
        await settle()
        #expect(engine.sessions[1].cancelCount == 1)
        #expect(engine.sessions[0].cancelCount == 0)
        #expect(live.availability == .listening)
        live.samples([0.1], track: .system)
        #expect(engine.sessions[1].appended.isEmpty)
    }

    @Test func stop_cancels_every_session_and_keeps_the_transcript() async {
        let live = await started()
        engine.sessions[0].emit(TranscriptPartial(stable: "Keep me."))
        await settle()
        live.stop()
        await settle()
        #expect(engine.sessions.map(\.cancelCount) == [1, 1])
        #expect(live.transcript.lines.map(\.text) == ["Keep me."])
        live.samples([0.1], track: .mic)
        #expect(engine.sessions[0].appended.isEmpty)
    }

    @Test func stop_during_open_cancels_the_late_session() async {
        engine.holdsOpen = true
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: [.mic])
        live.stop()
        engine.releaseOpen()
        await live.startTask?.value
        #expect(engine.sessions.count == 1)
        #expect(engine.sessions[0].cancelCount == 1)
        #expect(live.availability == .preparing)
    }

    @Test func unavailable_engine_is_reported() async {
        engine.readinessValue = .unavailable("No English assets")
        let live = await started()
        #expect(live.availability == .unavailable("No English assets"))
        #expect(engine.sessions.isEmpty)
    }

    @Test func open_failure_is_reported() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        engine.openError = Boom()
        let live = await started()
        #expect(live.availability == .unavailable("boom"))
    }

    @Test func needs_preparation_prepares_first() async {
        engine.readinessValue = .needsPreparation(downloadMB: nil)
        let live = await started([.mic])
        #expect(engine.prepareCount == 1)
        #expect(live.availability == .listening)
    }

    @Test func last_session_ending_on_its_own_is_unavailable() async {
        let live = await started([.mic])
        engine.sessions[0].cancel()
        await settle()
        #expect(live.availability == .unavailable("Apple Speech stopped"))
    }

    @Test func start_is_idempotent() async {
        let live = await started([.mic])
        live.start(tracks: [.mic, .system])
        await live.startTask?.value
        #expect(engine.sessions.count == 1)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveMeetingTranscriptTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile error `cannot find 'LiveMeetingTranscript' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// voxline/Meetings/LiveMeetingTranscript.swift
import Foundation
import Observation

enum LiveAvailability: Equatable, Sendable {
    case preparing
    case listening
    case unavailable(String)
}

enum LiveTranscriptError: LocalizedError {
    case unavailable(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .stopped: return "Apple Speech stopped"
        }
    }
}

@MainActor
protocol LiveMeetingTranscribing: AnyObject, MeetingSampleObserver {
    var transcript: LiveTranscript { get }
    var availability: LiveAvailability { get }
    /// False in mic-only mode, where every line is the one track.
    var showsLabels: Bool { get }
    func start(tracks: Set<MeetingRecorder.Track>)
    func trackLost(_ track: MeetingRecorder.Track)
    func stop()
}

/// One Apple Speech session per live meeting track, folded into labeled
/// lines for the timer panel. Display only: nothing here is written to disk
/// or logged, and `stop()` discards the sessions but leaves the last
/// transcript for the panel's final frame.
@Observable
@MainActor
final class LiveMeetingTranscript: LiveMeetingTranscribing {

    private(set) var transcript = LiveTranscript()
    private(set) var availability: LiveAvailability = .preparing
    private(set) var showsLabels = false
    @ObservationIgnored private(set) var startTask: Task<Void, Never>?

    @ObservationIgnored private let engine: any TranscriptionEngine
    @ObservationIgnored private let sessions = SessionTable()
    @ObservationIgnored private var assembler = LiveTranscriptAssembler()
    @ObservationIgnored private var consumers: [MeetingRecorder.Track: Task<Void, Never>] = [:]
    @ObservationIgnored private var stopped = false

    init(engine: any TranscriptionEngine) {
        self.engine = engine
    }

    func start(tracks: Set<MeetingRecorder.Track>) {
        guard startTask == nil, !stopped else { return }
        showsLabels = tracks.contains(.system)
        let ordered: [MeetingRecorder.Track] = [.mic, .system].filter(tracks.contains)
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch await engine.readiness() {
                case .ready:
                    break
                case .needsPreparation:
                    try await engine.prepare { _ in }
                case .unavailable(let reason):
                    throw LiveTranscriptError.unavailable(reason)
                }
                for track in ordered {
                    let session = try await engine.openSession(SessionConfig())
                    guard !stopped else {
                        session.cancel()
                        return
                    }
                    sessions.set(session, for: track)
                    consumers[track] = consume(session, track: track)
                }
                availability = .listening
                AppLog.meetings.info("live transcript: \(ordered.count) session(s) open")
            } catch {
                guard !stopped else { return }
                availability = .unavailable(error.localizedDescription)
                AppLog.meetings.notice("live transcript unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func trackLost(_ track: MeetingRecorder.Track) {
        sessions.remove(track)?.cancel()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        startTask?.cancel()
        for session in sessions.removeAll() { session.cancel() }
        consumers.values.forEach { $0.cancel() }
        consumers = [:]
    }

    nonisolated func samples(_ samples: [Float], track: MeetingRecorder.Track) {
        sessions.session(for: track)?.append(samples)
    }

    private func consume(_ session: any TranscriptionSession, track: MeetingRecorder.Track) -> Task<Void, Never> {
        Task { [weak self] in
            for await partial in session.partials {
                guard let self, !Task.isCancelled else { return }
                transcript = assembler.apply(partial, track: track)
            }
            self?.sessionEnded(track)
        }
    }

    private func sessionEnded(_ track: MeetingRecorder.Track) {
        consumers[track] = nil
        sessions.remove(track)
        guard !stopped, availability == .listening, sessions.isEmpty else { return }
        availability = .unavailable(LiveTranscriptError.stopped.localizedDescription)
        AppLog.meetings.notice("live transcript ended: last session closed")
    }
}

/// The open sessions, readable from the audio thread.
private final class SessionTable: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MeetingRecorder.Track: any TranscriptionSession] = [:]

    var isEmpty: Bool { lock.withLock { sessions.isEmpty } }

    func session(for track: MeetingRecorder.Track) -> (any TranscriptionSession)? {
        lock.withLock { sessions[track] }
    }

    func set(_ session: any TranscriptionSession, for track: MeetingRecorder.Track) {
        lock.withLock { sessions[track] = session }
    }

    @discardableResult
    func remove(_ track: MeetingRecorder.Track) -> (any TranscriptionSession)? {
        lock.withLock { sessions.removeValue(forKey: track) }
    }

    func removeAll() -> [any TranscriptionSession] {
        lock.withLock {
            defer { sessions = [:] }
            return Array(sessions.values)
        }
    }
}
```

If Task 1's results say sessions must restart every 10 minutes, add to `LiveMeetingTranscript` a per-track `Task` started in `consume`'s caller that sleeps `.seconds(600)`, then waits until `transcript.volatile[track] == nil` has held for 2 s (poll every 500 ms), then opens a replacement session with `engine.openSession(SessionConfig())`, swaps it into `sessions` under `track`, cancels the old session, and starts a new consumer; the assembler already treats the new session's non-extending `stable` as a fresh segment. Add a test with `FakeTranscriptionEngine.nextSessions` pre-seeded with two sessions and a `sleep` injected like `MeetingRecorder`'s. Skip this paragraph if the spike passed.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LiveMeetingTranscriptTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`. If `last_session_ending_on_its_own_is_unavailable` is flaky, raise `settle()` to 20 yields; the fake's `cancel()` finishes the stream synchronously, so the consumer needs only a few hops.

- [ ] **Step 5: Commit**

```bash
git add voxline/Meetings/LiveMeetingTranscript.swift voxlineTests/LiveMeetingTranscriptTests.swift
git commit -s -m "feat(meetings): live transcript sessions fed from the recorder"
```

---

### Task 6: Controller wiring

**Files:**
- Modify: `voxline/Meetings/MeetingController.swift:25-50` (stored closures, init), `:67-104` (`start`), `:151-166` (`recordingStopped`)
- Modify: `voxlineTests/MeetingControllerTests.swift`
- Modify: `voxline/AppCoordinator.swift:496-510` (the `makeRecorder` closure; compile only, full wiring in Task 8)

**Interfaces:**
- Consumes: `LiveMeetingTranscribing`, `MeetingSampleObserver`, `MeetingRecorder.init(…observer:)`.
- Produces: `MeetingController.init(store:settings:makeRecorder:makeLiveTranscript:pipeline:notifier:prompts:now:)` where `makeRecorder: @MainActor (MeetingDirectory, MeetingSampleObserver?) -> MeetingRecording` and `makeLiveTranscript: @MainActor () -> (any LiveMeetingTranscribing)? = { nil }`; `MeetingController.liveTranscript: (any LiveMeetingTranscribing)?` (non-nil only while recording).

- [ ] **Step 1: Write the failing tests**

In `voxlineTests/MeetingControllerTests.swift`, add after `FakePrompts`:

```swift
@MainActor
final class FakeLiveTranscript: LiveMeetingTranscribing {
    var transcript = LiveTranscript()
    var availability: LiveAvailability = .preparing
    var showsLabels = false
    private(set) var startedTracks: Set<MeetingRecorder.Track>?
    private(set) var lostTracks: [MeetingRecorder.Track] = []
    private(set) var stopCount = 0
    func start(tracks: Set<MeetingRecorder.Track>) { startedTracks = tracks }
    func trackLost(_ track: MeetingRecorder.Track) { lostTracks.append(track) }
    func stop() { stopCount += 1 }
    nonisolated func samples(_ samples: [Float], track: MeetingRecorder.Track) {}
}
```

Change the suite's stored properties and `makeController`:

```swift
    private let recorder = FakeRecorder()
    private let live = FakeLiveTranscript()
    private let observers = LockedBox<[MeetingSampleObserver?]>([])

    private func makeController(now: Date = Date(timeIntervalSince1970: 1_000), live: FakeLiveTranscript? = nil) -> MeetingController {
        let recorder = recorder
        let observers = observers
        return MeetingController(
            store: store, settings: AppSettings(defaults: defaults),
            makeRecorder: { _, observer in
                observers.mutate { $0.append(observer) }
                return recorder
            },
            makeLiveTranscript: { live },
            pipeline: processing, notifier: notifier, prompts: prompts,
            now: { now }
        )
    }
```

Every existing call `makeController()` and `makeController(now:)` keeps compiling. Add these tests:

```swift
    @Test func live_transcript_starts_after_the_recorder_with_both_tracks() {
        let controller = makeController(live: live)
        controller.start()
        #expect(live.startedTracks == [.mic, .system])
        #expect(controller.liveTranscript === live)
        #expect(observers.read().count == 1)
        #expect(observers.read()[0] === live)
    }

    @Test func live_transcript_gets_mic_only_when_the_tap_did_not_start() {
        recorder.systemTapStarted = false
        let controller = makeController(live: live)
        controller.start()
        #expect(live.startedTracks == [.mic])
    }

    @Test func live_transcript_is_not_started_when_the_recorder_fails() {
        recorder.startError = NSError(domain: "t", code: 1)
        let controller = makeController(live: live)
        controller.start()
        #expect(live.startedTracks == nil)
        #expect(controller.liveTranscript == nil)
    }

    @Test func live_transcript_stops_and_clears_on_stop() async throws {
        let controller = makeController(live: live)
        controller.start()
        controller.stop()
        #expect(live.stopCount == 1)
        #expect(controller.liveTranscript == nil)
        await controller.processingTask?.value
    }

    @Test func lost_system_track_reaches_the_live_transcript() {
        let controller = makeController(live: live)
        controller.start()
        recorder.onSystemTrackLost?()
        #expect(live.lostTracks == [.system])
        #expect(notifier.notices == [.systemAudioLost])
    }

    @Test func no_live_transcript_when_the_factory_returns_nil() {
        let controller = makeController()
        controller.start()
        #expect(controller.liveTranscript == nil)
        #expect(observers.read().count == 1)
        #expect(observers.read()[0] == nil)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingControllerTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile errors `extra argument 'makeLiveTranscript' in call`, `value of type 'MeetingController' has no member 'liveTranscript'`.

- [ ] **Step 3: Implement the wiring**

In `MeetingController`, change the stored closure and add two members:

```swift
    @ObservationIgnored private let makeRecorder: @MainActor (MeetingDirectory, MeetingSampleObserver?) -> MeetingRecording
    @ObservationIgnored private let makeLiveTranscript: @MainActor () -> (any LiveMeetingTranscribing)?
```

and, next to `phase`:

```swift
    /// The live transcript for the recording in progress; nil otherwise.
    private(set) var liveTranscript: (any LiveMeetingTranscribing)?
```

Change `init`:

```swift
    init(
        store: MeetingStore,
        settings: AppSettings,
        makeRecorder: @escaping @MainActor (MeetingDirectory, MeetingSampleObserver?) -> MeetingRecording,
        makeLiveTranscript: @escaping @MainActor () -> (any LiveMeetingTranscribing)? = { nil },
        pipeline: MeetingProcessing,
        notifier: MeetingNotifying,
        prompts: MeetingPrompting,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.makeRecorder = makeRecorder
        self.makeLiveTranscript = makeLiveTranscript
        self.pipeline = pipeline
        self.notifier = notifier
        self.prompts = prompts
        self.now = now
        pipeline.onStage = { [weak self] stage in self?.phase = .processing(stage) }
        refreshRegenerable()
    }
```

In `start()`, replace the block from `let recorder = makeRecorder(…)` through `phase = .recording(…)`:

```swift
        let live = makeLiveTranscript()
        let recorder = makeRecorder(store.directory(for: meta.id), live)
        recorder.onWarning = { [weak self] in self?.notifier.post(.capWarning) }
        recorder.onStopped = { [weak self] reason in self?.recordingStopped(meta.id, reason: reason) }
        recorder.onSystemTrackLost = { [weak self] in
            self?.liveTranscript?.trackLost(.system)
            self?.notifier.post(.systemAudioLost)
        }
        do {
            try recorder.start()
        } catch {
            store.delete(meta.id)
            prompts.showError("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        var started = meta
        started.systemTapStarted = recorder.systemTapStarted
        do { try store.save(started) } catch {
            AppLog.meetings.error("saving meeting metadata failed: \(error.localizedDescription, privacy: .public)")
        }
        if !recorder.systemTapStarted && !settings.meetingSilentSystemNoticeShown {
            settings.meetingSilentSystemNoticeShown = true
            notifier.post(.systemAudioUnavailable)
        }
        live?.start(tracks: recorder.systemTapStarted ? [.mic, .system] : [.mic])
        self.recorder = recorder
        liveTranscript = live
        activeRecordingID = meta.id
        phase = .recording(startedAt: meta.startedAt)
```

`liveTranscript` is assigned before `phase`, so the coordinator's phase observer finds it when it shows the panel.

In `recordingStopped(_:reason:)`, add as the first two lines:

```swift
        liveTranscript?.stop()
        liveTranscript = nil
```

In `AppCoordinator.buildMeetings`, change the `makeRecorder` closure so the project compiles (the live factory comes in Task 8):

```swift
            makeRecorder: { directory, observer in
                let current = AppSettings()
                return MeetingRecorder(
                    mic: MicMeetingSource(preferredInputDeviceUID: current.audioInputDeviceUID),
                    system: SystemAudioTap(),
                    directory: directory,
                    cap: current.meetingCapSeconds.map { .seconds($0) } ?? MeetingRecorder.defaultCap,
                    observer: observer
                )
            },
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingControllerTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`, all pre-existing controller tests still passing.

- [ ] **Step 5: Commit**

```bash
git add voxline/Meetings/MeetingController.swift voxline/AppCoordinator.swift voxlineTests/MeetingControllerTests.swift
git commit -s -m "feat(meetings): start and stop the live transcript with the recording"
```

---

### Task 7: Layout for an expanding panel

**Files:**
- Modify: `voxline/Meetings/MeetingTimerLayout.swift`
- Modify: `voxlineTests/MeetingTimerLayoutTests.swift`

**Interfaces:**
- Produces: `MeetingTimerLayout.resized(_ frame: CGRect, to size: CGSize, visibleFrame: CGRect) -> CGRect`; `MeetingTimerLayout.bodySize == CGSize(width: 360, height: 150)`.

- [ ] **Step 1: Write the failing tests**

Append inside the suite in `MeetingTimerLayoutTests.swift`:

```swift
    // MARK: - resized

    @Test func resized_keeps_the_top_left_corner_and_grows_downward() {
        let chip = CGRect(x: 400, y: 600, width: 110, height: 28)
        let frame = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        #expect(frame == CGRect(x: 400, y: 600 + 28 - 178, width: 360, height: 178))
    }

    @Test func resized_back_to_the_chip_returns_the_corner() {
        let chip = CGRect(x: 400, y: 600, width: 110, height: 28)
        let expanded = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        let collapsed = MeetingTimerLayout.resized(expanded, to: CGSize(width: 110, height: 28), visibleFrame: screen)
        #expect(collapsed == chip)
    }

    @Test func resized_clamps_at_the_bottom_and_right_edges() {
        let chip = CGRect(x: 1440 - 110 - 16, y: 25 + 40, width: 110, height: 28)
        let frame = MeetingTimerLayout.resized(chip, to: CGSize(width: 360, height: 178), visibleFrame: screen)
        #expect(frame == CGRect(x: 1440 - 360, y: 25, width: 360, height: 178))
    }

    @Test func body_size_is_the_spec_size() {
        #expect(MeetingTimerLayout.bodySize == CGSize(width: 360, height: 150))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingTimerLayoutTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: compile errors `type 'MeetingTimerLayout' has no member 'resized'` and `'bodySize'`.

- [ ] **Step 3: Implement**

Add to `MeetingTimerLayout`:

```swift
    /// The expanded live-transcript body under the chip.
    static let bodySize = CGSize(width: 360, height: 150)

    /// Resizes a frame while keeping its top-left corner, so the panel grows
    /// downward from the chip, then clamps to the visible frame.
    static func resized(_ frame: CGRect, to size: CGSize, visibleFrame: CGRect) -> CGRect {
        let topLeft = CGPoint(x: frame.minX, y: frame.maxY - size.height)
        return self.frame(size: size, saved: CGRect(origin: topLeft, size: size), visibleFrame: visibleFrame)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/MeetingTimerLayoutTests 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add voxline/Meetings/MeetingTimerLayout.swift voxlineTests/MeetingTimerLayoutTests.swift
git commit -s -m "feat(meetings): layout for a timer chip that expands downward"
```

---

### Task 8: The panel view, panel expansion, and coordinator wiring

**Files:**
- Create: `voxline/Meetings/MeetingLivePanelView.swift`
- Modify: `voxline/Meetings/MeetingTimerPanel.swift` (whole file)
- Modify: `voxline/AppCoordinator.swift:496-510` (add `makeLiveTranscript`), `:534-540` (`updateMeetingTimer`)

**Interfaces:**
- Consumes: `LiveMeetingTranscribing`, `LiveTranscript`, `LiveLine`, `LiveAvailability`, `MeetingTimerLayout.resized`, `MeetingTimerLayout.bodySize`, `AppSettings.meetingLivePanelExpanded`, `AppSettings.liveTranscriptEnabled`, `LiveMeetingTranscript.init(engine:)`, `TranscriptionEngines.engine(for:)`, `MeetingController.liveTranscript`.
- Produces: `MeetingTimerPanel.show(startedAt: Date, live: (any LiveMeetingTranscribing)?)`; `struct MeetingLivePanelView: View { init(startedAt: Date, live: (any LiveMeetingTranscribing)?, expanded: Bool, onToggle: @escaping () -> Void) }`.

No unit test covers SwiftUI layout here; the manual checks in Task 9 do. The build must succeed and the full suite must stay green.

- [ ] **Step 1: Write the view**

```swift
// voxline/Meetings/MeetingLivePanelView.swift
import SwiftUI

/// The timer chip, plus the live transcript body when expanded.
struct MeetingLivePanelView: View {
    let startedAt: Date
    let live: (any LiveMeetingTranscribing)?
    let expanded: Bool
    let onToggle: () -> Void

    private var showsBody: Bool { expanded && live != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showsBody, let live {
                Divider().padding(.horizontal, 10)
                LiveTranscriptBody(live: live)
                    .frame(width: MeetingTimerLayout.bodySize.width, height: MeetingTimerLayout.bodySize.height)
            }
        }
        .background(.regularMaterial, in: shape)
        .accessibilityElement(children: .contain)
    }

    private var shape: AnyShape {
        showsBody ? AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)) : AnyShape(Capsule())
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            ZStack {
                Text(MeetingTimerLayout.widestLabel).hidden()
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(MeetingTimerLayout.label(elapsed: context.date.timeIntervalSince(startedAt)))
                }
            }
            .monospacedDigit()
            .font(.system(size: 12, weight: .medium))
            .fixedSize()
            if live != nil {
                if showsBody { Spacer(minLength: 0) }
                Button(action: onToggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide live transcript" : "Show live transcript")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: showsBody ? MeetingTimerLayout.bodySize.width : nil, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting recording")
    }
}

private struct LiveTranscriptBody: View {
    let live: any LiveMeetingTranscribing

    private static let bottomID = "bottom"

    var body: some View {
        switch live.availability {
        case .preparing:
            placeholder("Preparing Apple Speech…")
        case .unavailable(let reason):
            placeholder("Live transcript unavailable: \(reason)")
        case .listening where live.transcript.lines.isEmpty && live.transcript.volatile.isEmpty:
            placeholder("Listening…")
        case .listening:
            lines
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(live.transcript.lines) { line in
                        row(label: line.track.liveLabel, text: line.text, dim: false)
                    }
                    ForEach([MeetingRecorder.Track.mic, .system], id: \.self) { track in
                        if let tail = live.transcript.volatile[track] {
                            row(label: track.liveLabel, text: tail, dim: true)
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
            .onChange(of: live.transcript) { _, _ in proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }

    private func row(label: String, text: String, dim: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if live.showsLabels {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(dim ? .tertiary : .primary)
                .textSelection(.disabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(live.showsLabels ? "\(label): \(text)" : text)
    }
}
```

- [ ] **Step 2: Rewrite the panel**

Replace the contents of `voxline/Meetings/MeetingTimerPanel.swift`:

```swift
import AppKit
import SwiftUI

/// The elapsed-time chip shown while a meeting records, expandable to the
/// live transcript. Borderless, non-activating, never key or main, on every
/// Space, draggable; its position is remembered. A panel, so `DockPolicy`
/// ignores it.
@MainActor
final class MeetingTimerPanel {

    private static let autosaveName = "voxline.meetingTimer"
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MeetingLivePanelView>?
    private var startedAt = Date()
    private var live: (any LiveMeetingTranscribing)?
    private var expanded = false

    func show(startedAt: Date, live: (any LiveMeetingTranscribing)?) {
        guard panel == nil else { return }
        self.startedAt = startedAt
        self.live = live
        expanded = live != nil && AppSettings().meetingLivePanelExpanded
        let hostingView = NSHostingView(rootView: rootView())
        let panel = ChipPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = hostingView
        let saved = panel.setFrameUsingName(Self.autosaveName) ? panel.frame : nil
        if let screen = Self.screen(for: saved) {
            let frame = MeetingTimerLayout.frame(
                size: hostingView.fittingSize, saved: saved, visibleFrame: screen.visibleFrame
            )
            panel.setFrame(frame, display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hostingView
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        live = nil
    }

    private func rootView() -> MeetingLivePanelView {
        MeetingLivePanelView(startedAt: startedAt, live: live, expanded: expanded) { [weak self] in
            self?.toggle()
        }
    }

    private func toggle() {
        expanded.toggle()
        var settings = AppSettings()
        settings.meetingLivePanelExpanded = expanded
        guard let panel, let hostingView else { return }
        hostingView.rootView = rootView()
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        guard let screen = Self.screen(for: panel.frame) else { return }
        panel.setFrame(
            MeetingTimerLayout.resized(panel.frame, to: size, visibleFrame: screen.visibleFrame),
            display: true
        )
    }

    private static func screen(for frame: CGRect?) -> NSScreen? {
        frame.flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
    }
}

private final class ChipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 3: Wire the coordinator**

In `AppCoordinator.buildMeetings`, add the live factory argument after `makeRecorder:` (the controller's `init` takes it before `pipeline:`):

```swift
            makeLiveTranscript: { [weak self] in
                guard AppSettings().liveTranscriptEnabled, let engine = self?.engines?.engine(for: .apple) else { return nil }
                return LiveMeetingTranscript(engine: engine)
            },
```

Replace `updateMeetingTimer`:

```swift
    private func updateMeetingTimer(state: AppState) {
        if case .recording(let startedAt) = state.meetings?.phase, AppSettings().showMeetingTimer {
            meetingTimer.show(startedAt: startedAt, live: state.meetings?.liveTranscript)
        } else {
            meetingTimer.hide()
        }
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E 'error:|warning: .*LiveMeeting|warning: .*MeetingTimerPanel|SUCCEEDED|FAILED' | head -20`
Expected: `** TEST SUCCEEDED **`, no `error:` lines. A Swift 6 concurrency error on `live` being captured in the `Task`-free closure means `LiveMeetingTranscribing` lost `Sendable`; it inherits it from `MeetingSampleObserver`, so check that protocol's declaration.

- [ ] **Step 5: Smoke it in the real app**

Run: `./scripts/build-local.sh --debug`
Then: start a meeting from the menu bar, confirm the chip shows a chevron, expand it, speak, and see "Me" lines appear; collapse, expand again, drag by the time. If lines never appear although `scripts/tail-logs.sh meetings` shows "live transcript: 2 session(s) open", the view is not observing through the existential: change `LiveTranscriptBody.live` to the concrete `LiveMeetingTranscript` by adding `var concrete: LiveMeetingTranscript? { live as? LiveMeetingTranscript }` in `MeetingLivePanelView` and passing that, keeping the fake-friendly protocol everywhere else.

- [ ] **Step 6: Commit**

```bash
git add voxline/Meetings/MeetingLivePanelView.swift voxline/Meetings/MeetingTimerPanel.swift voxline/AppCoordinator.swift
git commit -s -m "feat(meetings): expand the recording timer into a live transcript"
```

---

### Task 9: Docs and manual checks

**Files:**
- Modify: `CHANGELOG.md:91-96` (the meetings entry), `README.md:51,194`, `AGENTS.md:22`, `docs/release/MANUAL_TESTS.md` (Meetings section, after the one-hour item), the spec's "Status" line.

- [ ] **Step 1: CHANGELOG**

After the `**Meeting recording and notes.**` bullet in Unreleased → Added, add:

```markdown
- **Live transcript during meetings.** The recording timer has a chevron;
  expand it to see the last few things said, labeled Me (your mic) and Them
  (your Mac's sound output), with words that may still change shown dim.
  Transcribed on this Mac by Apple Speech, kept only in memory, and gone when
  you stop; the notes after Stop are unchanged. Settings → Meetings → Live
  transcript turns it off (it needs the timer shown).
```

- [ ] **Step 2: README**

In the `**Meeting notes**` feature bullet (line 51), after "a speaker-labeled transcript.", insert: "While it records, the timer chip can expand to show the last few lines live."

In the Privacy section's Meetings bullet (line 194), after "Transcription and speaker separation run on-device.", insert: "The live transcript in the timer chip is produced on-device by Apple Speech, kept in memory only, and discarded when the meeting stops."

- [ ] **Step 3: AGENTS.md**

Replace the `voxline/Meetings/` line with:

```markdown
- `voxline/Meetings/` — meeting recording (mic + Core Audio process tap) and post-stop processing (`MeetingPipeline`: WhisperKit, SpeakerKit, LLM notes, Markdown). Separate from the dictation pipeline. The live transcript in the timer chip (`LiveMeetingTranscript`) is one Apple Speech session per track, fed by `MeetingRecorder`'s sample observer, folded by the pure `LiveTranscriptAssembler`, display only and never persisted; the post-stop pipeline does not use it.
```

- [ ] **Step 4: Manual tests**

In `docs/release/MANUAL_TESTS.md`, after the "One-hour real meeting" item in the Meetings section, add:

```markdown
- [ ] Live transcript: Start a meeting; the chip has a chevron. Expand: "Listening…", then your own words appear under "Me" within a few seconds, bright once settled, dim while changing.
- [ ] Live transcript on a call with headphones: the other side appears under "Them"; turns interleave in speaking order.
- [ ] Live transcript in-person (system tap denied or silent): lines carry no label.
- [ ] Collapse and expand: the top-left corner stays put; with the chip near the bottom of the screen the expanded panel stays on screen.
- [ ] Expanded state and position survive Stop and the next Start.
- [ ] Drag the panel by the time; the chevron toggles without moving it.
- [ ] Hold the dictation hotkey mid-meeting: dictation works; the words show under "Me".
- [ ] Unplug headphones mid-meeting: "Me" keeps updating after the restart.
- [ ] Stop: the panel disappears; the notes after processing match a meeting recorded with Live transcript off.
- [ ] Settings → Meetings → Live transcript off: the chip is exactly the old chip and `scripts/tail-logs.sh meetings` shows no "live transcript" line. Timer off disables the toggle.
- [ ] Full-screen Zoom or Teams: the expanded panel stays visible over it.
- [ ] One-hour meeting with the panel expanded: lines still arrive in the last minute; note voxline's CPU in Activity Monitor in the spec's results table.
```

- [ ] **Step 5: Spec status**

Change the spec's `**Status:**` line to `**Status:** Approved; implemented (see plan 2026-10-09-live-meeting-transcript.md).`

- [ ] **Step 6: Full suite one last time, then commit**

Run: `xcodebuild test -project voxline.xcodeproj -scheme voxline -destination 'platform=macOS' 2>&1 | grep -E 'error:|SUCCEEDED|FAILED' | head`
Expected: `** TEST SUCCEEDED **`.

```bash
git add CHANGELOG.md README.md AGENTS.md docs/release/MANUAL_TESTS.md docs/superpowers/specs/2026-10-09-live-meeting-transcript-design.md
git commit -s -m "docs(meetings): live transcript in the changelog, README, AGENTS and manual tests"
```

---

## Self-review against the spec

- **Spike gate** → Task 1. **Assembler and labels** → Task 2. **Settings and toggle, Reset to Defaults correction** → Task 3. **Sample observer and tee, padding not forwarded, byte-identical tracks** → Task 4. **Sessions, readiness, lost track, stop, availability** → Task 5 (with the 10-minute restart fallback described, applied only if the spike says so). **Controller lifecycle and `liveTranscript` set before `phase`** → Task 6. **Panel growth and clamping** → Task 7. **Chevron, 360 by 150 body, placeholders, labels, dim tails, pinned to bottom, remembered state, never key** → Task 8. **Privacy sentences, changelog, AGENTS, manual checks** → Task 9.
- Names used across tasks: `MeetingSampleObserver.samples(_:track:)` (4, 5, 6), `LiveMeetingTranscribing` members `transcript` / `availability` / `showsLabels` / `start(tracks:)` / `trackLost(_:)` / `stop()` (5, 6, 8), `MeetingController.liveTranscript` (6, 8), `MeetingTimerLayout.resized` and `bodySize` (7, 8), `AppSettings.liveTranscriptEnabled` and `meetingLivePanelExpanded` (3, 8), `MeetingTimerPanel.show(startedAt:live:)` (8). Consistent.
