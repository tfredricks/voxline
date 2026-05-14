import Testing
import Foundation
@testable import voxline

@Suite struct LegacyKeychainMigratorTests {

    private func makeDefaults() -> UserDefaults {
        let suite = "voxline.tests.migrator.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func copies_orphaned_legacy_entry_into_modern() throws {
        let legacy = InMemoryKeychain(seed: [KeychainAccount.anthropic: "sk-ant-legacy"])
        let modern = InMemoryKeychain()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(try modern.string(forKey: KeychainAccount.anthropic) == "sk-ant-legacy")
        #expect(try legacy.string(forKey: KeychainAccount.anthropic) == nil)
        #expect(defaults.bool(forKey: LegacyKeychainMigrator.completedKey) == true)
    }

    @Test func does_not_overwrite_existing_modern_value() throws {
        let legacy = InMemoryKeychain(seed: [KeychainAccount.anthropic: "sk-ant-legacy"])
        let modern = InMemoryKeychain(seed: [KeychainAccount.anthropic: "sk-ant-modern"])
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(try modern.string(forKey: KeychainAccount.anthropic) == "sk-ant-modern")
        // Legacy entry still cleared — it's stale either way.
        #expect(try legacy.string(forKey: KeychainAccount.anthropic) == nil)
    }

    @Test func is_idempotent_via_completion_flag() throws {
        let legacy = InMemoryKeychain(seed: [KeychainAccount.anthropic: "round-1"])
        let modern = InMemoryKeychain()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()
        try legacy.set("round-2", forKey: KeychainAccount.anthropic)
        m.migrateIfNeeded()

        #expect(try modern.string(forKey: KeychainAccount.anthropic) == "round-1")
        #expect(try legacy.string(forKey: KeychainAccount.anthropic) == "round-2")
    }

    @Test func no_legacy_entries_still_marks_complete() throws {
        let legacy = InMemoryKeychain()
        let modern = InMemoryKeychain()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(defaults.bool(forKey: LegacyKeychainMigrator.completedKey) == true)
    }

    @Test func empty_legacy_value_is_skipped() throws {
        let legacy = InMemoryKeychain(seed: [KeychainAccount.openai: ""])
        let modern = InMemoryKeychain()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(try modern.string(forKey: KeychainAccount.openai) == nil)
    }

    @Test func migrates_multiple_accounts() throws {
        let legacy = InMemoryKeychain(seed: [
            KeychainAccount.anthropic: "sk-ant",
            KeychainAccount.openai: "sk-oa"
        ])
        let modern = InMemoryKeychain()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(try modern.string(forKey: KeychainAccount.anthropic) == "sk-ant")
        #expect(try modern.string(forKey: KeychainAccount.openai) == "sk-oa")
    }

    @Test func does_not_set_flag_if_modern_write_throws() throws {
        struct FailingModern: KeychainStorage {
            func string(forKey account: String) throws -> String? { nil }
            func set(_ value: String, forKey account: String) throws {
                throw KeychainError.dataProtectionKeychainUnavailable
            }
            func delete(forKey account: String) throws {}
        }

        let legacy = InMemoryKeychain(seed: [KeychainAccount.anthropic: "sk-ant"])
        let modern = FailingModern()
        let defaults = makeDefaults()
        let m = LegacyKeychainMigrator(legacy: legacy, modern: modern, defaults: defaults)

        m.migrateIfNeeded()

        #expect(defaults.bool(forKey: LegacyKeychainMigrator.completedKey) == false)
        #expect(try legacy.string(forKey: KeychainAccount.anthropic) == "sk-ant")
    }
}
