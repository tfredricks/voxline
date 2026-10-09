import Foundation
import Testing
@testable import voxline

@MainActor
final class FakeRecorder: MeetingRecording {
    var onWarning: (() -> Void)?
    var onStopped: ((MeetingStopReason) -> Void)?
    var systemTapStarted = true
    var elapsed: Duration = .zero
    var startError: Error?
    private(set) var started = false
    func start() throws {
        if let startError { throw startError }
        started = true
    }
    func stop() { finish(.user) }
    func finish(_ reason: MeetingStopReason) {
        guard started else { return }
        started = false
        onStopped?(reason)
    }
}

@MainActor
final class FakeProcessing: MeetingProcessing {
    var onStage: ((MeetingStage) -> Void)?
    var outcome: MeetingOutcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
    private(set) var processed: [UUID] = []
    private(set) var regenerated: [UUID] = []
    func process(_ id: UUID) async -> MeetingOutcome {
        processed.append(id)
        onStage?(.writingNotes)
        return outcome
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
    private(set) var consentAsked = 0
    private(set) var errors: [String] = []
    func confirmConsent() -> Bool { consentAsked += 1; return consent }
    func confirmProcessUnfinished(startedAt: Date) -> Bool {
        onConfirmUnfinished?()
        return processUnfinished.isEmpty ? true : processUnfinished.removeFirst()
    }
    func showError(_ message: String) { errors.append(message) }
}

@MainActor
@Suite struct MeetingControllerTests {

    private let store = MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    private let defaults = UserDefaults(suiteName: UUID().uuidString)!
    private let processing = FakeProcessing()
    private let notifier = FakeNotifier()
    private let prompts = FakePrompts()
    private let recorder = FakeRecorder()

    private func makeController(now: Date = Date(timeIntervalSince1970: 1_000)) -> MeetingController {
        let recorder = recorder
        return MeetingController(
            store: store, settings: AppSettings(defaults: defaults),
            makeRecorder: { _ in recorder }, pipeline: processing, notifier: notifier, prompts: prompts,
            now: { now }
        )
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

    @Test func failed_outcome_can_be_retried() async throws {
        processing.outcome = .failed("Transcription failed: x")
        let controller = makeController()
        controller.start()
        controller.stop()
        await controller.processingTask?.value
        let id = try #require(controller.lastFailedMeeting)
        #expect(notifier.notices.contains(.failed("Transcription failed: x")))
        processing.outcome = .written(URL(fileURLWithPath: "/tmp/n.md"))
        controller.retryFailed()
        await controller.processingTask?.value
        #expect(processing.processed == [id, id])
        #expect(controller.lastFailedMeeting == nil)
    }

    @Test func toggle_starts_and_stops_but_ignores_processing() async throws {
        let controller = makeController()
        controller.toggle()
        guard case .recording = controller.phase else {
            Issue.record("expected recording")
            return
        }
        controller.toggle()
        #expect(controller.phase == .processing(nil))
        controller.toggle()
        #expect(controller.phase == .processing(nil))
        #expect(!recorder.started)
        await controller.processingTask?.value
        #expect(processing.processed.count == 1)
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
        #expect(notifier.notices.contains(.failed("Notes failed")))
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
