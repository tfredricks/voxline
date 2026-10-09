import Foundation

/// Resumes a single waiter exactly once, whichever of `fire()` and `wait()`
/// comes first. Later fires are ignored.
@MainActor
final class OneShotSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        guard !fired else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
