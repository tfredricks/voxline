import Foundation
import Security

/// Wrapper around the legacy file keychain (`~/Library/Keychains/login.keychain-db`).
/// Exists ONLY for `LegacyKeychainMigrator` to lift orphaned entries written
/// by older voxline builds whose DPK probe returned false. Production reads
/// and writes never touch this type.
///
/// Delete this file (and `LegacyKeychainMigrator`) one release after the
/// migration has shipped and baked.
struct LegacyKeychain: KeychainStorage {

    static let serviceID = DataProtectionKeychain.serviceID

    private func baseQuery(account: String) -> [String: Any] {
        // Notably absent: `kSecUseDataProtectionKeychain`. Default is the
        // legacy file keychain.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.serviceID,
            kSecAttrAccount as String: account
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
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }

    /// Not used by the migrator (we only read + delete from legacy) but
    /// implemented for protocol completeness in case future migrations need it.
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
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unhandledStatus(addStatus)
            }
        default:
            throw KeychainError.unhandledStatus(updateStatus)
        }
    }

    func delete(forKey account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }
}
