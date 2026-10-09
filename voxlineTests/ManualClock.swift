// voxlineTests/ManualClock.swift
import Foundation

/// Deterministic stand-in for `Task.sleep(for:)`. Sleepers suspend until
/// `advance(by:)` moves `now` past their deadline; cancelling a sleeper
/// throws `CancellationError` like `Task.sleep` does.
final class ManualClock: @unchecked Sendable {

    private struct Sleeper {
        let id: UInt64
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var nextID: UInt64 = 0

    var now: Duration { lock.withLock { current } }

    var pendingCount: Int { lock.withLock { sleepers.count } }

    func sleep(_ duration: Duration) async throws {
        let id: UInt64 = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: current + duration, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            let cancelled: Sleeper? = lock.withLock {
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Steps `now` through each pending deadline up to `now + duration`,
    /// resuming due sleepers in deadline order and letting them run before
    /// the next step, so a sleeper that re-sleeps lands on its true deadline.
    func advance(by duration: Duration) async {
        let target = now + duration
        while true {
            let due: [Sleeper] = lock.withLock {
                guard let next = sleepers.map(\.deadline).min(), next <= target else { return [] }
                current = max(current, next)
                let ready = sleepers
                    .filter { $0.deadline <= current }
                    .sorted { ($0.deadline, $0.id) < ($1.deadline, $1.id) }
                sleepers.removeAll { $0.deadline <= current }
                return ready
            }
            if due.isEmpty { break }
            for sleeper in due { sleeper.continuation.resume() }
            await settle()
        }
        lock.withLock { current = max(current, target) }
        await settle()
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            await MainActor.run {}
        }
    }
}
