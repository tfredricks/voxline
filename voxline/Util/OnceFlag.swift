import Foundation

/// A flag any thread can try to raise; only the first caller succeeds.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    /// True for the one call that raised the flag.
    func trySet() -> Bool {
        lock.withLock {
            guard !raised else { return false }
            raised = true
            return true
        }
    }
}
