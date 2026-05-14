import Foundation

/// Generic-password keychain abstraction. Two impls live behind this:
///   - `DataProtectionKeychain` — production. DPK only. Fails loud.
///   - `InMemoryKeychain` — test double.
///
/// `account` is the per-record name (e.g. "anthropic", "openai"); the service
/// id is fixed at the implementation layer and never crosses this boundary.
protocol KeychainStorage: Sendable {
    func string(forKey account: String) throws -> String?
    func set(_ value: String, forKey account: String) throws
    func delete(forKey account: String) throws
}

/// Canonical account names. Domain concept, not a storage detail — kept at
/// top level so every caller (Settings, Wizard, LLMService, --reset-keys)
/// references the same constants without importing a specific impl.
enum KeychainAccount {
    static let anthropic = "anthropic"
    static let openai = "openai"

    /// All known accounts. Used by the migrator and the --reset-keys handler
    /// so a new provider added in the future only needs to be listed once.
    static let all: [String] = [anthropic, openai]
}

enum KeychainError: Error, Equatable {
    case unhandledStatus(OSStatus)
    case unexpectedDataFormat
    /// DPK rejected the write because the binary lacks the
    /// `keychain-access-groups` entitlement. In production this means
    /// signing is broken — surface it to the user instead of silently
    /// routing writes elsewhere.
    case dataProtectionKeychainUnavailable
}
