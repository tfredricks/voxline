import Foundation

/// Polls `condition` until it holds or `timeout` passes; never waits longer.
/// Runs on the caller's actor, so `condition` may read that actor's state.
func eventually(timeout: Duration = .seconds(5),
                isolation: isolated (any Actor)? = #isolation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}
