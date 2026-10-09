import Foundation

enum MeetingStopReason: Equatable {
    case user
    case cap
    case failed(String)
}

@MainActor
protocol MeetingRecording: AnyObject {
    var onWarning: (() -> Void)? { get set }
    var onStopped: ((MeetingStopReason) -> Void)? { get set }
    /// Fires once when the system track can't be restarted; the mic keeps
    /// recording.
    var onSystemTrackLost: (() -> Void)? { get set }
    var systemTapStarted: Bool { get }
    var elapsed: Duration { get }
    func start() throws
    func stop()
}

/// One meeting recording: the mic and, when it starts, the system tap,
/// each written to its raw track in `directory`. A mic that can't be
/// restarted stops the recording; a system tap that can't be restarted is
/// dropped and the mic keeps recording.
@MainActor
final class MeetingRecorder: MeetingRecording {

    static let defaultCap: Duration = .seconds(3_600)
    static let restartDelay: Duration = .milliseconds(500)
    static let maxConsecutiveFailures = 3
    static let failureWindow: Duration = .seconds(30)

    static func warningLead(forCap cap: Duration) -> Duration {
        cap >= .seconds(600) ? .seconds(300) : cap / 2
    }

    private static let lagToleranceSamples = 8_000

    nonisolated static func expectedSamples(after elapsed: Duration) -> Int {
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Int(seconds * AudioFormat.whisperSampleRate)
    }

    enum Track { case mic, system }

    var onWarning: (() -> Void)?
    var onStopped: ((MeetingStopReason) -> Void)?
    var onSystemTrackLost: (() -> Void)?
    private(set) var systemTapStarted = false
    private(set) var systemTrackLost = false

    private let mic: MeetingAudioSource
    private let system: MeetingAudioSource?
    private let directory: MeetingDirectory
    private let cap: Duration
    private let sleep: @MainActor (Duration) async throws -> Void
    private let clock: @Sendable () -> Duration
    private var startedAt: Duration = .zero
    private var isRecording = false
    private var writers: [Track: PCMTrackWriter] = [:]
    private var failures: [Track: Int] = [:]
    private var lastFailure: [Track: Duration] = [:]
    private var capTask: Task<Void, Never>?
    private var restartTasks: [Task<Void, Never>] = []

    init(
        mic: MeetingAudioSource,
        system: MeetingAudioSource?,
        directory: MeetingDirectory,
        cap: Duration = MeetingRecorder.defaultCap,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clock: @escaping @Sendable () -> Duration = MeetingRecorder.wallClock()
    ) {
        self.mic = mic
        self.system = system
        self.directory = directory
        self.cap = cap
        self.sleep = sleep
        self.clock = clock
    }

    nonisolated static func wallClock() -> @Sendable () -> Duration {
        let base = ContinuousClock.now
        return { ContinuousClock.now - base }
    }

    var elapsed: Duration { isRecording ? clock() - startedAt : .zero }

    func start() throws {
        guard !isRecording else { return }
        let writeFailed: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.stop(reason: .failed("Couldn't write meeting audio: \(error.localizedDescription)")) }
        }
        do {
            writers[.mic] = try PCMTrackWriter(url: directory.micPCM, onFailure: writeFailed)
            writers[.system] = try PCMTrackWriter(url: directory.systemPCM, onFailure: writeFailed)
            startedAt = clock()
            try startSource(.mic)
        } catch {
            writers.values.forEach { $0.close() }
            writers = [:]
            throw error
        }
        isRecording = true
        if system != nil {
            do {
                try startSource(.system)
                systemTapStarted = true
            } catch {
                AppLog.meetings.notice("system audio unavailable; recording mic only: \(String(describing: error), privacy: .public)")
            }
        }
        let lead = Self.warningLead(forCap: cap)
        let warningAt = cap - lead
        capTask = Task { [weak self, sleep] in
            do {
                try await sleep(warningAt)
                guard self?.isRecording == true else { return }
                self?.onWarning?()
                try await sleep(lead)
                guard self?.isRecording == true else { return }
                self?.stop(reason: .cap)
            } catch {}
        }
        AppLog.meetings.info("recording started (system tap: \(self.systemTapStarted))")
    }

    func stop() { stop(reason: .user) }

    private func stop(reason: MeetingStopReason) {
        guard isRecording else { return }
        isRecording = false
        capTask?.cancel()
        restartTasks.forEach { $0.cancel() }
        restartTasks = []
        mic.stop()
        system?.stop()
        writers.values.forEach { $0.close() }
        AppLog.meetings.info("recording stopped: \(String(describing: reason), privacy: .public)")
        onStopped?(reason)
    }

    private func source(_ track: Track) -> MeetingAudioSource? {
        track == .mic ? mic : system
    }

    private func startSource(_ track: Track) throws {
        guard let source = source(track), let writer = writers[track] else { return }
        let clock = clock
        let startedAt = startedAt
        try source.start(
            onSamples: { batch in
                let expected = Self.expectedSamples(after: clock() - startedAt)
                if writer.sampleCount + batch.count < expected - Self.lagToleranceSamples {
                    writer.padSilence(toSampleCount: expected - batch.count)
                }
                writer.append(batch)
            },
            onFailure: { [weak self] _ in Task { @MainActor in self?.handleFailure(track) } }
        )
    }

    private func isLive(_ track: Track) -> Bool {
        isRecording && !(track == .system && systemTrackLost)
    }

    private func handleFailure(_ track: Track) {
        guard isLive(track) else { return }
        let now = clock()
        if let last = lastFailure[track], now - last > Self.failureWindow {
            failures[track] = 0
        }
        failures[track, default: 0] += 1
        lastFailure[track] = now
        guard failures[track, default: 0] <= Self.maxConsecutiveFailures else {
            if track == .mic {
                stop(reason: .failed("The microphone stopped and couldn't be restarted."))
            } else {
                loseSystemTrack()
            }
            return
        }
        AppLog.meetings.notice("\(track == .mic ? "mic" : "system", privacy: .public) track failed; restarting")
        restartTasks.append(Task { [weak self, sleep] in
            do { try await sleep(Self.restartDelay) } catch { return }
            self?.restart(track)
        })
    }

    private func loseSystemTrack() {
        systemTrackLost = true
        system?.stop()
        writers[.system]?.close()
        AppLog.meetings.notice("system track couldn't be restarted; recording mic only")
        onSystemTrackLost?()
    }

    private func restart(_ track: Track) {
        guard isLive(track), let source = source(track) else { return }
        source.stop()
        writers[track]?.padSilence(toSampleCount: Self.expectedSamples(after: elapsed))
        do {
            try startSource(track)
        } catch {
            handleFailure(track)
        }
    }
}

extension MeetingRecorder.Track {
    /// The live transcript's speaker label for this track.
    var liveLabel: String { self == .mic ? "Me" : "Them" }
}
