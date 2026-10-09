import Foundation

enum MeetingAudioSourceError: Error, Equatable {
    /// The device or route changed and capture stopped; restarting may work.
    case configurationChanged
    /// The source could not start, with a reason for the log and the UI.
    case unavailable(String)
}

/// One track's audio for a meeting recording.
protocol MeetingAudioSource: AnyObject {
    /// Starts delivering 16 kHz mono Float32 on a background thread.
    /// `onFailure` fires at most once per start, after which no more samples
    /// arrive until the next start.
    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void
    ) throws
    /// Delivers the resampler's tail through `onSamples`, then stops.
    /// Idempotent.
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
