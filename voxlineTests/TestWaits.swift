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

/// Awaits `task`, which must return while the test still holds a gate it
/// would otherwise wait on. If the test is cancelled first (its time
/// limit), `release` opens the gate so a task that does wait returns and
/// the caller's check that the gate is still held fails, instead of the
/// run hanging.
@MainActor
func awaitWhileHeld<T: Sendable>(_ task: Task<T, Never>, release: @escaping @Sendable @MainActor () -> Void) async -> T {
    await withTaskCancellationHandler {
        await task.value
    } onCancel: {
        Task { @MainActor in release() }
    }
}
