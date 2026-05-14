import Foundation
@testable import voxline

/// Test double. Pure Swift, no OS calls. Internally synchronized so tests can
/// share an instance across actors without TSan complaints, though most tests
/// will use one instance per test.
final class InMemoryKeychain: KeychainStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    func string(forKey account: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func set(_ value: String, forKey account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = value
    }

    func delete(forKey account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }

    /// Test-only convenience: snapshot of current contents.
    func snapshot() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
