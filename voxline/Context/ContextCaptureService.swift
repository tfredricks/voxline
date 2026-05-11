import Foundation

/// Captures the user's current dictation context at push-to-talk press time.
/// Implementations run AX queries under a total time budget and must NEVER
/// throw — return a partial `CapturedContext` instead. Called from background
/// queues; must be `Sendable`.
protocol ContextCapturing: Sendable {
    /// Snapshot of the user's current focus + surroundings. Always returns;
    /// fields fall back to nil/empty when the underlying signal is unavailable.
    func capture() async -> CapturedContext
}
