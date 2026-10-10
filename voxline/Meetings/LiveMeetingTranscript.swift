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
    @ObservationIgnored private var lostTracks: Set<MeetingRecorder.Track> = []
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
                for track in ordered where !lostTracks.contains(track) {
                    let session = try await engine.openSession(SessionConfig())
                    guard !stopped else {
                        session.cancel()
                        return
                    }
                    guard !lostTracks.contains(track) else {
                        session.cancel()
                        continue
                    }
                    sessions.set(session, for: track)
                    consumers[track] = consume(session, track: track)
                }
                availability = .listening
                AppLog.meetings.info("live transcript: \(ordered.count) session(s) open")
            } catch {
                guard !stopped else { return }
                for session in sessions.removeAll() { session.cancel() }
                consumers.values.forEach { $0.cancel() }
                consumers = [:]
                availability = .unavailable(error.localizedDescription)
                AppLog.meetings.notice("live transcript unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func trackLost(_ track: MeetingRecorder.Track) {
        lostTracks.insert(track)
        sessions.remove(track)?.cancel()
        transcript = assembler.endTrack(track)
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
        sessions.remove(track)?.cancel()
        guard !stopped else { return }
        transcript = assembler.endTrack(track)
        guard availability == .listening, sessions.isEmpty else { return }
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
