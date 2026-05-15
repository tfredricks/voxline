import Foundation
import Security
import os

/// Production keychain. Uses the data-protection keychain exclusively — the
/// per-app keychain gated by the `keychain-access-groups` entitlement. There
/// is no probe and no fallback: if DPK is unreachable, writes throw
/// `KeychainError.dataProtectionKeychainUnavailable` so the caller can
/// surface the failure instead of silently routing to a different store.
///
/// The service id is hardcoded; callers never pass one.
struct DataProtectionKeychain: KeychainStorage {

    /// Canonical service id for voxline API keys. Same value used by every
    /// production build past or present, so DPK lookups across releases hit
    /// the same records.
    static let serviceID = "com.voxline.app.keys"

    private static let log = Logger(subsystem: "com.voxline.app", category: "keychain")

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceID,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    func string(forKey account: String) throws -> String? {
        var query = baseQuery(account: account)
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
        case errSecMissingEntitlement:
            Self.log.error("DPK read missing entitlement; treating account=\(account) as absent")
            return nil
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    func set(_ value: String, forKey account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            switch addStatus {
            case errSecSuccess:
                return
            case errSecMissingEntitlement:
                Self.log.error("DPK add rejected: missing entitlement (signing broken or unsigned build)")
                throw KeychainError.dataProtectionKeychainUnavailable
            default:
                throw KeychainError.unhandledStatus(addStatus)
            }
        case errSecMissingEntitlement:
            Self.log.error("DPK update rejected: missing entitlement (signing broken or unsigned build)")
            throw KeychainError.dataProtectionKeychainUnavailable
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    func delete(forKey account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        case errSecMissingEntitlement:
            // Mirrors `set`: a broken-signing build cannot reach DPK, so we
            // genuinely don't know whether the entry exists or not. Treating
            // delete as a silent no-op would lie to the caller — Settings
            // would show the field as cleared while the keychain entry stays
            // intact for whatever build comes next. Throw so the caller
            // surfaces the failure (APIKeysSettingsViewModel sets lastError;
            // --reset-keys writes to stderr).
            Self.log.error("DPK delete rejected: missing entitlement (signing broken or unsigned build)")
            throw KeychainError.dataProtectionKeychainUnavailable
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}
