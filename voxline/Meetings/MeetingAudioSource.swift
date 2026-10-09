import Foundation

enum MeetingAudioSourceError: Error, Equatable {
    /// The device or route changed and capture stopped; restarting may work.
    case configurationChanged
    /// The source could not start, with a reason for the log and the UI.
    case unavailable(String)
}

/// One track's audio for a meeting recording.
///
/// Threading: chunks arrive on a background thread, the tail on the thread
/// calling `stop()`, and `onFailure` on an arbitrary background thread. Never
/// call `start()` or `stop()` synchronously from inside either callback; hop
/// to another queue or actor first.
protocol MeetingAudioSource: AnyObject {
    /// Starts delivering 16 kHz mono Float32 on a background thread.
    /// `onFailure` fires at most once per start, after which no more samples
    /// arrive until the next start. It never fires after `stop()` returns.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void
    ) throws
    /// Delivers the resampler's tail through `onSamples`, after every earlier
    /// chunk, then stops. Nothing is delivered once it returns. Idempotent.
    func stop()
}

/// Lets exactly one caller through, from any thread.
final class FireOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    var hasFired: Bool {
        lock.withLock { fired }
    }

    func claim() -> Bool {
        lock.withLock {
            guard !fired else { return false }
            fired = true
            return true
        }
    }
}
