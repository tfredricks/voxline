// voxlineTests/LockedBox.swift
import Foundation

/// Thread-safe box for capturing closure side-effects in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ initial: T) { self.value = initial }
    func read() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func write(_ new: T) { lock.lock(); value = new; lock.unlock() }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&value); lock.unlock()
    }
}
