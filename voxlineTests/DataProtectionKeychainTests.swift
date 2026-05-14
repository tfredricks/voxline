import Testing
import Foundation
import Security
@testable import voxline

/// Integration tests against the real data-protection keychain. These only
/// run when the binary is signed with the `keychain-access-groups`
/// entitlement (i.e., not under `CODE_SIGNING_ALLOWED=NO` in CI). On
/// unsigned builds, every test no-ops via early-return guard.
///
/// Skip strategy: `guard Self.dpkReachable else { return }` in every test
/// body. This makes tests pass-as-no-op on unsigned builds. `throw SkipTest()`
/// was considered but would register as test failures in Swift Testing on this
/// toolchain when the error is not a recognized skip type, so early-return is
/// the safe choice here.
@Suite struct DataProtectionKeychainTests {

    /// One-shot probe: try to add a throwaway DPK item. If we get back
    /// `errSecMissingEntitlement`, DPK is unreachable and we skip the suite.
    private static let dpkReachable: Bool = {
        let probeService = "voxline.dpk-probe-test.\(UUID().uuidString)"
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data("probe".utf8),
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        if status == errSecSuccess {
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecUseDataProtectionKeychain as String: true
            ]
            _ = SecItemDelete(del as CFDictionary)
            return true
        }
        return false
    }()

    private func uniqueAccount() -> String { "test.\(UUID().uuidString)" }

    @Test func set_then_get_roundtrips() throws {
        guard Self.dpkReachable else { return }
        let kc = DataProtectionKeychain()
        let acct = uniqueAccount()
        defer { try? kc.delete(forKey: acct) }

        try kc.set("sk-test", forKey: acct)
        #expect(try kc.string(forKey: acct) == "sk-test")
    }

    @Test func set_overwrites_existing() throws {
        guard Self.dpkReachable else { return }
        let kc = DataProtectionKeychain()
        let acct = uniqueAccount()
        defer { try? kc.delete(forKey: acct) }

        try kc.set("v1", forKey: acct)
        try kc.set("v2", forKey: acct)
        #expect(try kc.string(forKey: acct) == "v2")
    }

    @Test func get_unset_returns_nil() throws {
        guard Self.dpkReachable else { return }
        let kc = DataProtectionKeychain()
        #expect(try kc.string(forKey: uniqueAccount()) == nil)
    }

    @Test func delete_unset_does_not_throw() throws {
        guard Self.dpkReachable else { return }
        let kc = DataProtectionKeychain()
        try kc.delete(forKey: uniqueAccount())
    }
}
