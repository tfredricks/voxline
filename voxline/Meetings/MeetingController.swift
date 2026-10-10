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
    /// The live transcript for the recording in progress; nil otherwise.
    private(set) var liveTranscript: (any LiveMeetingTranscribing)?
    /// The newest meeting whose processing failed, which the menu's Retry
    /// Processing reruns. Read from disk, so it outlives a relaunch.
    private(set) var lastFailedMeeting: UUID?
    /// Cached, like `lastFailedMeeting`, so the menu doesn't read every
    /// `meta.json` on each redraw; both are refreshed when processing
    /// finishes, after retention, and after a recovery discard.
    private(set) var regenerableMeetings: [MeetingMeta] = []
    @ObservationIgnored private(set) var processingTask: Task<Void, Never>?

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let makeRecorder: @MainActor (MeetingDirectory, MeetingSampleObserver?) -> MeetingRecording
    @ObservationIgnored private let makeLiveTranscript: @MainActor () -> (any LiveMeetingTranscribing)?
    @ObservationIgnored private let pipeline: MeetingProcessing
    @ObservationIgnored private let notifier: MeetingNotifying
    @ObservationIgnored private let prompts: MeetingPrompting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var recorder: MeetingRecording?
    @ObservationIgnored private var activeRecordingID: UUID?
    @ObservationIgnored private var isStarting = false

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
        refreshLists()
    }

    static let sleepStopMessage = "Your Mac went to sleep"

    var needsQuitConfirmation: Bool { phase != .idle }

    func toggle() {
        switch phase {
        case .idle:       start()
        case .recording:  stop()
        case .processing: break
        }
    }

    /// Ignores a call made while a start is already under way, such as a
    /// shortcut press delivered during the consent alert's modal loop.
    func start() {
        guard phase == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
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
    }

    func stop() {
        recorder?.stop()
    }

    func retryFailed() {
        guard let id = lastFailedMeeting else { return }
        retryFailed(id)
    }

    func retryFailed(_ id: UUID) {
        guard phase == .idle else { return }
        runProcessing(id)
    }

    func regenerate(_ id: UUID) {
        guard phase == .idle else { return }
        phase = .processing(.writingNotes)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await pipeline.regenerateNotes(id)
            finish(outcome, retryable: false)
        }
    }

    /// Offers each unfinished meeting, oldest first, one at a time.
    func recoverUnfinished() async {
        for meta in store.unfinished().reversed() {
            guard phase == .idle, meta.id != activeRecordingID else { return }
            let accepted = prompts.confirmProcessUnfinished(startedAt: meta.startedAt)
            guard phase == .idle, meta.id != activeRecordingID else { return }
            if accepted {
                runProcessing(meta.id)
                await processingTask?.value
            } else {
                store.delete(meta.id)
                refreshLists()
            }
        }
    }

    func applyRetention() {
        store.applyRetention(settings.meetingAudioRetention, now: now())
        refreshLists()
    }

    private func refreshLists() {
        regenerableMeetings = store.regenerable()
        lastFailedMeeting = store.all().first { $0.state == .failed }?.id
    }

    private func recordingStopped(_ id: UUID, reason: MeetingStopReason) {
        liveTranscript?.stop()
        liveTranscript = nil
        recorder = nil
        activeRecordingID = nil
        do {
            var meta = try store.load(id)
            meta.durationSeconds = max(0, now().timeIntervalSince(meta.startedAt))
            meta.state = .recorded
            try store.save(meta)
        } catch {
            AppLog.meetings.error("updating recorded meeting failed: \(error.localizedDescription, privacy: .public)")
        }
        switch reason {
        case .failed(let message):
            AppLog.meetings.error("recording ended early: \(message, privacy: .public)")
            notifier.post(.recordingStopped(message))
        case .systemSleep:
            notifier.post(.recordingStopped(Self.sleepStopMessage))
        case .user, .cap:
            break
        }
        runProcessing(id)
    }

    private func runProcessing(_ id: UUID) {
        phase = .processing(nil)
        processingTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await pipeline.process(id)
            finish(outcome)
        }
    }

    private func finish(_ outcome: MeetingOutcome, retryable: Bool = true) {
        phase = .idle
        refreshLists()
        switch outcome {
        case .written(let url):
            notifier.post(.notesReady(url))
        case .nothingRecorded:
            notifier.post(.nothingRecorded)
        case .failed(let message):
            notifier.post(.failed(message, retryable: retryable))
        }
    }
}

extension MeetingController.Phase {
    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}
