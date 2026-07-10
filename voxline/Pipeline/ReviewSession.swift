import Foundation

/// The short-lived "you just dictated — want to tweak it?" window. Created by
/// `CapturePipeline` after a successful paste and cleared on expiry, dismissal,
/// or the next chord press. Holds the *original transcript* (not the cleaned
/// output) so refinements re-run from everything the user actually said, plus
/// the exact string currently sitting in the target field so a refine can
/// replace precisely that text.
///
/// Clearing the session is also the memory scrub: the transcript copy dies with
/// it, bounding how long spoken secrets linger in process memory (~7s idle,
/// reset on interaction) rather than "until the next dictation".
struct ReviewSession: Equatable, Sendable {
    let transcript: String
    let mode: Mode
    let context: CapturedContext
    var insertedText: String
    var expiresAt: Date
}
