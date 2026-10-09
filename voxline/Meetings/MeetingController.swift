import Foundation
import Observation

/// The meeting feature's state, driven by the menu, the shortcut, and the
/// recorder; one meeting at a time.
@Observable
@MainActor
final class MeetingController {

    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing(MeetingStage?)
    }

    private(set) var phase: Phase = .idle
    private(set) var lastFailedMeeting: UUID?
    @ObservationIgnored private(set) var processingTask: Task<Void, Never>?

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let makeRecorder: @MainActor (MeetingDirectory) -> MeetingRecording
    @ObservationIgnored private let pipeline: MeetingProcessing
    @ObservationIgnored private let notifier: MeetingNotifying
    @ObservationIgnored private let prompts: MeetingPrompting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var recorder: MeetingRecording?

    init(
        store: MeetingStore,
        settings: AppSettings,
        makeRecorder: @escaping @MainActor (MeetingDirectory) -> MeetingRecording,
        pipeline: MeetingProcessing,
        notifier: MeetingNotifying,
        prompts: MeetingPrompting,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.settings = settings
        self.makeRecorder = makeRecorder
        self.pipeline = pipeline
        self.notifier = notifier
        self.prompts = prompts
        self.now = now
        pipeline.onStage = { [weak self] stage in self?.phase = .processing(stage) }
    }

    var needsQuitConfirmation: Bool { phase != .idle }

    var regenerableMeetings: [MeetingMeta] { store.regenerable() }

    func toggle() {
        switch phase {
        case .idle:       start()
        case .recording:  stop()
        case .processing: break
        }
    }

    func start() {
        guard phase == .idle else { return }
        if !settings.meetingConsentNoticeShown {
            guard prompts.confirmConsent() else { return }
            settings.meetingConsentNoticeShown = true
        }
        let meta: MeetingMeta
        do {
            meta = try store.create(startedAt: now(), systemTapStarted: false)
        } catch {
            prompts.showError("Couldn't create the meeting folder: \(error.localizedDescription)")
            return
        }
        let recorder = makeRecorder(store.directory(for: meta.id))
        recorder.onWarning = { [weak self] in self?.notifier.post(.capWarning) }
        recorder.onStopped = { [weak self] reason in self?.recordingStopped(meta.id, reason: reason) }
        do {
            try recorder.start()
        } catch {
            store.delete(meta.id)
            prompts.showError("Couldn't start recording: \(error.localizedDescription)")
            return
        }
        var started = meta
        started.systemTapStarted = recorder.systemTapStarted
        try? store.save(started)
        if !recorder.systemTapStarted && !settings.meetingSilentSystemNoticeShown {
            settings.meetingSilentSystemNoticeShown = true
            notifier.post(.systemAudioUnavailable)
        }
        self.recorder = recorder
        phase = .recording(startedAt: meta.startedAt)
    }

    func stop() {
        recorder?.stop()
    }

    func retryFailed() {
        guard phase == .idle, let id = lastFailedMeeting else { return }
        runProcessing(id)
    }

    func regenerate(_ id: UUID) {
        guard phase == .idle else { return }
        phase = .processing(.writingNotes)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await pipeline.regenerateNotes(id)
            finish(outcome, id: id)
        }
    }

    /// Offers each unfinished meeting, oldest first, one at a time.
    func recoverUnfinished() async {
        for meta in store.unfinished().reversed() {
            guard phase == .idle else { return }
            if prompts.confirmProcessUnfinished(startedAt: meta.startedAt) {
                runProcessing(meta.id)
                await processingTask?.value
            } else {
                store.delete(meta.id)
            }
        }
    }

    func applyRetention() {
        _ = store.applyRetention(settings.meetingAudioRetention, now: now())
    }

    private func recordingStopped(_ id: UUID, reason: MeetingStopReason) {
        recorder = nil
        if var meta = try? store.load(id) {
            meta.durationSeconds = max(0, now().timeIntervalSince(meta.startedAt))
            meta.state = .recorded
            try? store.save(meta)
        }
        if case .failed(let message) = reason {
            AppLog.meetings.error("recording ended early: \(message, privacy: .public)")
        }
        runProcessing(id)
    }

    private func runProcessing(_ id: UUID) {
        phase = .processing(nil)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await pipeline.process(id)
            finish(outcome, id: id)
        }
    }

    private func finish(_ outcome: MeetingOutcome, id: UUID) {
        phase = .idle
        switch outcome {
        case .written(let url):
            lastFailedMeeting = nil
            notifier.post(.notesReady(url))
        case .nothingRecorded:
            notifier.post(.nothingRecorded)
        case .failed(let message):
            lastFailedMeeting = id
            notifier.post(.failed(message))
        }
    }
}
