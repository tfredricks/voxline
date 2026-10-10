import Foundation
import Testing
@testable import voxline

@MainActor
final class FakeRecorder: MeetingRecording {
    var onWarning: (() -> Void)?
    var onStopped: ((MeetingStopReason) -> Void)?
    var onSystemTrackLost: (() -> Void)?
    var systemTapStarted = true
    var startError: Error?
    private(set) var started = false
    private(set) var startCount = 0
    func start() throws {
        if let startError { throw startError }
        startCount += 1
        started = true
    }
    func stop() { finish(.user) }
    func finish(_ reason: MeetingStopReason) {
        guard started else { return }
        started = false
        onStopped?(reason)
    }
}

/// With a `store`, `process` leaves the meeting on disk the way
/// `MeetingPipeline` does: done, failed, or deleted.
@MainActor
final class FakeProcessing: MeetingProcessing {
    var onStage: ((MeetingStage) -> Void)?
    var outcome: MeetingOutcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
    var store: MeetingStore?
    private(set) var processed: [UUID] = []
    private(set) var regenerated: [UUID] = []
    func process(_ id: UUID) async -> MeetingOutcome {
        processed.append(id)
        onStage?(.writingNotes)
        if let store {
            switch outcome {
            case .written:         mark(id, .done, in: store)
            case .failed:          mark(id, .failed, in: store)
            case .nothingRecorded: store.delete(id)
            }
        }
        return outcome
    }
    private func mark(_ id: UUID, _ state: MeetingState, in store: MeetingStore) {
        guard var meta = try? store.load(id) else { return }
        meta.state = state
        try? store.save(meta)
    }
    func regenerateNotes(_ id: UUID) async -> MeetingOutcome {
        regenerated.append(id)
        return outcome
    }
}

@MainActor
final class FakeNotifier: MeetingNotifying {
    private(set) var notices: [MeetingNotice] = []
    func post(_ notice: MeetingNotice) { notices.append(notice) }
}

@MainActor
final class FakePrompts: MeetingPrompting {
    var consent = true
    var processUnfinished: [Bool] = []
    var onConfirmUnfinished: (() -> Void)?
    var onConsent: (() -> Void)?
    private(set) var consentAsked = 0
    private(set) var errors: [String] = []
    func confirmConsent() -> Bool {
        consentAsked += 1
        onConsent?()
        return consent
    }
    func confirmProcessUnfinished(startedAt: Date) -> Bool {
        onConfirmUnfinished?()
        return processUnfinished.isEmpty ? true : processUnfinished.removeFirst()
    }
    func showError(_ message: String) { errors.append(message) }
}

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

@MainActor
@Suite struct MeetingControllerTests {

    private let store = MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!
    private let processing = FakeProcessing()
    private let notifier = FakeNotifier()
    private let prompts = FakePrompts()
    private let recorder = FakeRecorder()
    private let live = FakeLiveTranscript()
    private let observers = LockedBox<[MeetingSampleObserver?]>([])

    private func makeController(
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) }, live: FakeLiveTranscript? = nil
    ) -> MeetingController {
        let recorder = recorder
        let observers = observers
        processing.store = store
        return MeetingController(
            store: store, settings: AppSettings(defaults: defaults),
            makeRecorder: { _, observer in
                observers.mutate { $0.append(observer) }
                return recorder
            },
            makeLiveTranscript: { live },
            pipeline: processing, notifier: notifier, prompts: prompts,
            now: now
        )
    }

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

    @Test func start_asks_consent_once_and_records() async throws {
        let controller = makeController()
        controller.start()
        #expect(prompts.consentAsked == 1)
        #expect(controller.phase == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
        #expect(store.all().count == 1)
        controller.stop()
        await controller.processingTask?.value
        controller.start()
        #expect(prompts.consentAsked == 1)
        guard case .recording = controller.phase else {
            Issue.record("expected a second recording")
            return
        }
    }

    @Test func start_during_consent_prompt_is_ignored() {
        let controller = makeController()
        prompts.onConsent = { controller.start() }
        controller.start()
        #expect(prompts.consentAsked == 1)
        #expect(store.all().count == 1)
        #expect(recorder.startCount == 1)
        #expect(controller.phase == .recording(startedAt: Date(timeIntervalSince1970: 1_000)))
    }

    @Test func declined_consent_does_not_record() {
        prompts.consent = false
        let controller = makeController()
        controller.start()
        #expect(controller.phase == .idle)
        #expect(store.all().isEmpty)
    }

    @Test func recorder_start_failure_cleans_up_and_shows_error() {
        recorder.startError = MeetingAudioSourceError.unavailable("No microphone input is available.")
        let controller = makeController()
        controller.start()
        #expect(controller.phase == .idle)
        #expect(store.all().isEmpty)
        #expect(prompts.errors.count == 1)
    }

    @Test func stop_processes_and_posts_notes_ready() async throws {
        let controller = makeController()
        controller.start()
        let id = try #require(store.all().first?.id)
        controller.stop()
        await controller.processingTask?.value
        #expect(processing.processed == [id])
        #expect(notifier.notices.contains(.notesReady(URL(fileURLWithPath: "/tmp/n.md"))))
        #expect(controller.phase == .idle)
    }

    @Test func cap_warning_and_cap_stop() async throws {
        let controller = makeController()
        controller.start()
        recorder.onWarning?()
        recorder.finish(.cap)
        await controller.processingTask?.value
        #expect(notifier.notices.first == .capWarning)
        #expect(processing.processed.count == 1)
    }

    @Test func sleep_stop_says_why_and_processes() async throws {
        let controller = makeController()
        controller.start()
        recorder.finish(.systemSleep)
        #expect(notifier.notices == [.recordingStopped(MeetingController.sleepStopMessage)])
        await controller.processingTask?.value
        #expect(processing.processed.count == 1)
    }

    @Test func early_stop_posts_recording_stopped_before_processing() async throws {
        let controller = makeController()
        controller.start()
        recorder.finish(.failed("The microphone stopped and couldn't be restarted."))
        #expect(notifier.notices == [.recordingStopped("The microphone stopped and couldn't be restarted.")])
        await controller.processingTask?.value
        #expect(processing.processed.count == 1)
        #expect(notifier.notices.last == .notesReady(URL(fileURLWithPath: "/tmp/n.md")))
    }

    @Test func user_and_cap_stops_post_no_recording_stopped_notice() async throws {
        let controller = makeController()
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        #expect(!notifier.notices.contains { if case .recordingStopped = $0 { true } else { false } })
    }

    @Test func lost_system_track_posts_a_notice_and_keeps_recording() {
        let controller = makeController()
        controller.start()
        recorder.onSystemTrackLost?()
        #expect(notifier.notices == [.systemAudioLost])
        #expect(controller.phase.isRecording)
    }

    @Test func regenerable_list_is_cached_and_refreshed_after_processing_and_retention() async throws {
        var old = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        old.state = .done
        try store.save(old)
        try Data("{}".utf8).write(to: store.directory(for: old.id).transcript)
        let controller = makeController(now: { Date(timeIntervalSince1970: 100 * 86_400) })
        #expect(controller.regenerableMeetings.map(\.id) == [old.id])

        controller.start()
        let id = try #require(store.all().first { $0.id != old.id }?.id)
        try Data("{}".utf8).write(to: store.directory(for: id).transcript)
        #expect(controller.regenerableMeetings.map(\.id) == [old.id])
        controller.stop()
        await controller.processingTask?.value
        #expect(controller.regenerableMeetings.map(\.id) == [id, old.id])

        controller.applyRetention()
        #expect(controller.regenerableMeetings.map(\.id) == [id])
    }

    @Test func discarded_recovery_leaves_the_regenerable_list() async throws {
        var unfinished = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        unfinished.state = .processing
        try store.save(unfinished)
        try Data("{}".utf8).write(to: store.directory(for: unfinished.id).transcript)
        let controller = makeController()
        #expect(controller.regenerableMeetings.map(\.id) == [unfinished.id])
        prompts.processUnfinished = [false]

        await controller.recoverUnfinished()

        #expect(controller.regenerableMeetings.isEmpty)
    }

    @Test func failed_outcome_can_be_retried() async throws {
        processing.outcome = .failed("Transcription failed: x")
        let controller = makeController()
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        let id = try #require(controller.lastFailedMeeting)
        #expect(notifier.notices.contains(.failed("Transcription failed: x", retryable: true)))
        processing.outcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
        controller.retryFailed()
        await controller.processingTask?.value
        #expect(processing.processed == [id, id])
        #expect(controller.lastFailedMeeting == nil)
    }

    @Test func failed_meta_on_disk_at_init_is_retryable() async throws {
        var failed = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        failed.state = .failed
        try store.save(failed)
        let controller = makeController()
        #expect(controller.lastFailedMeeting == failed.id)

        controller.retryFailed()
        await controller.processingTask?.value

        #expect(processing.processed == [failed.id])
        #expect(controller.lastFailedMeeting == nil)
    }

    @Test func two_failures_keep_both_retryable() async throws {
        processing.outcome = .failed("x")
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let controller = makeController(now: { clock.read() })
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        let first = try #require(controller.lastFailedMeeting)
        clock.write(Date(timeIntervalSince1970: 2_000))
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        let second = try #require(controller.lastFailedMeeting)
        #expect(second != first)

        processing.outcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
        controller.retryFailed()
        await controller.processingTask?.value
        #expect(processing.processed.last == second)
        #expect(controller.lastFailedMeeting == first)

        controller.retryFailed(first)
        await controller.processingTask?.value
        #expect(processing.processed.last == first)
        #expect(controller.lastFailedMeeting == nil)
    }

    @Test func retry_of_a_named_meeting_waits_for_idle() async throws {
        var failed = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        failed.state = .failed
        try store.save(failed)
        let controller = makeController()
        controller.start()
        controller.retryFailed(failed.id)
        #expect(processing.processed.isEmpty)
        #expect(controller.phase.isRecording)
    }

    @Test func toggle_starts_and_stops_but_only_says_busy_while_processing() async throws {
        let controller = makeController()
        controller.toggle()
        guard case .recording = controller.phase else {
            Issue.record("expected recording")
            return
        }
        controller.toggle()
        #expect(controller.phase == .processing(nil))
        #expect(notifier.notices.isEmpty)
        controller.toggle()
        #expect(controller.phase == .processing(nil))
        #expect(!recorder.started)
        #expect(notifier.notices == [.busy])
        await controller.processingTask?.value
        #expect(processing.processed.count == 1)
        #expect(store.all().count == 1)
    }

    @Test func recovery_processes_accepted_and_discards_declined() async throws {
        var first = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        first.state = .recording
        try store.save(first)
        var second = try store.create(startedAt: Date(timeIntervalSince1970: 2), systemTapStarted: false)
        second.state = .processing
        try store.save(second)
        prompts.processUnfinished = [true, false]

        await makeController().recoverUnfinished()

        #expect(processing.processed == [first.id])
        #expect((try? store.load(second.id)) == nil)
    }

    @Test func system_audio_notice_posts_once() async throws {
        recorder.systemTapStarted = false
        let controller = makeController()
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        #expect(notifier.notices.filter { $0 == .systemAudioUnavailable }.count == 1)
    }

    @Test func regenerate_posts_notes_ready() async throws {
        let controller = makeController()
        let id = UUID()
        controller.regenerate(id)
        await controller.processingTask?.value
        #expect(processing.regenerated == [id])
        #expect(notifier.notices.contains(.notesReady(URL(fileURLWithPath: "/tmp/n.md"))))
    }

    @Test func quit_confirmation_only_when_busy() {
        let controller = makeController()
        #expect(!controller.needsQuitConfirmation)
        controller.start()
        #expect(controller.needsQuitConfirmation)
    }

    @Test func failed_regenerate_is_not_retryable() async throws {
        processing.outcome = .failed("Notes failed")
        let controller = makeController()
        controller.regenerate(UUID())
        await controller.processingTask?.value
        #expect(notifier.notices.contains(.failed("Notes failed", retryable: false)))
        #expect(controller.lastFailedMeeting == nil)
        controller.retryFailed()
        #expect(controller.phase == .idle)
        #expect(processing.processed.isEmpty)
    }

    @Test func recording_started_during_recovery_prompt_is_untouched() async throws {
        var old = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        old.state = .recording
        try store.save(old)
        let controller = makeController()
        prompts.processUnfinished = [false]
        prompts.onConfirmUnfinished = { controller.start() }

        await controller.recoverUnfinished()

        guard case .recording = controller.phase else {
            Issue.record("expected the new recording to stay active")
            return
        }
        #expect(processing.processed.isEmpty)
        #expect((try? store.load(old.id)) != nil)
    }

    @Test func unrelated_success_keeps_failed_meeting_and_nothing_recorded_clears_it() async throws {
        processing.outcome = .failed("x")
        let controller = makeController()
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        let failed = try #require(controller.lastFailedMeeting)

        processing.outcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
        controller.regenerate(UUID())
        await controller.processingTask?.value
        #expect(controller.lastFailedMeeting == failed)

        processing.outcome = .nothingRecorded
        controller.retryFailed()
        await controller.processingTask?.value
        #expect(controller.lastFailedMeeting == nil)
    }
}
