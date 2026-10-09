import Foundation

/// Bridges the capture tap to a transcription session that opens
/// asynchronously. Audio that arrives before the session attaches is held
/// and flushed in order, so opening an engine never clips the first word.
/// Count and peak update together under one lock, so a reader never sees
/// samples without their level.
///
/// `attach` forwards pending chunks while holding the lock, which keeps
/// ordering airtight against a concurrent `append`. A session's `append`
/// must therefore never call back into the router.
///
/// Expects a single producer: one capture tap thread calls `append`.
/// Concurrent producers stay safe for the tallies but can reorder chunks
/// delivered to the session. `attach` after `close()` ignores the session
/// without cancelling it; the caller owns cancelling it.
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
