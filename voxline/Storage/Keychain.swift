import Foundation
import Security

/// Generic-password Keychain wrapper. One instance per logical "service"
/// (a namespace like `com.fredricks.voxline.keys`); within a service, items
/// are addressed by a string `key` (i.e., the Keychain `account`).
struct Keychain {

    /// Canonical service id used by the app for API keys.
    static let appServiceID = "com.fredricks.voxline.keys"

    /// Canonical account names.
    enum Account {
        static let anthropic = "anthropic"
        static let openai = "openai"
    }

    enum KeychainError: Error, Equatable {
        case unhandledStatus(OSStatus)
        case unexpectedDataFormat
    }

    let service: String

    init(service: String = Keychain.appServiceID) {
        self.service = service
    }

    /// Whether the data-protection keychain is reachable from this binary.
    /// Probed once on first access by issuing a harmless lookup against a
    /// nonexistent service. Production builds (signed with the
    /// `keychain-access-groups` entitlement) get `true` and use the modern
    /// per-app keychain → no ACL prompts ever. Unsigned test bundles
    /// (CODE_SIGNING_ALLOWED=NO strips entitlements) get `false` and fall
    /// back to the legacy file keychain.
    private static let dataProtectionKeychainAvailable: Bool = {
        // Probe by trying to ADD a throwaway item — read queries don't gate
        // on the entitlement (an unentitled binary just sees an empty DPK),
        // so reads can't tell us whether writes will succeed.
        let probeService = "voxline.dpk-probe.\(UUID().uuidString)"
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecMissingEntitlement { return false }
        // Clean up probe item.
        if addStatus == errSecSuccess {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecUseDataProtectionKeychain as String: true
            ]
            _ = SecItemDelete(deleteQuery as CFDictionary)
        }
        return true
    }()

    /// Base query attrs used by every operation. Includes
    /// `kSecUseDataProtectionKeychain` only when the binary actually has
    /// access — otherwise the SecItem call would return -34018.
    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if Keychain.dataProtectionKeychainAvailable {
            q[kSecUseDataProtectionKeychain as String] = true
        }
        return q
    }

    func string(forKey key: String) throws -> String? {
        var query = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedDataFormat
            }
            return s
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: key)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            // Survives device reboot; doesn't require unlock per access.
            // Only meaningful on the data-protection keychain; harmless on legacy.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    func delete(forKey key: String) throws {
        let query = baseQuery(account: key)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Test helper: removes every item with this service id. Production code
    /// has no reason to call this.
    func deleteAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if Keychain.dataProtectionKeychainAvailable {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}
