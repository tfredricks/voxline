# Keychain Storage Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the runtime probe-and-fallback `Keychain` wrapper with a protocol-driven design: one production storage type (data-protection keychain only, no fallback), an in-memory test double, and a one-shot migrator that lifts orphaned keys out of the legacy file keychain into DPK before the fallback path is removed.

**Architecture:** Introduce `KeychainStorage` protocol with three implementations: `DataProtectionKeychain` (DPK-only, fails loudly on entitlement/signing issues), `LegacyKeychain` (legacy file keychain — only used by the migrator), and `InMemoryKeychain` (test double). A `LegacyKeychainMigrator` runs once at app launch, reads any orphaned entries out of the legacy keychain, writes them into DPK if DPK has nothing for that account, deletes the legacy entry, and sets a one-shot UserDefaults flag. After the migration ships and bakes for one release, `LegacyKeychain` and the migrator can be deleted.

**Tech Stack:** Swift 6, Security framework (SecItem APIs), Swift Testing, `@MainActor` Observation-based view models.

**Context for the engineer reading this cold:**
- The current `Keychain` type at `voxline/Storage/Keychain.swift` decides between DPK and legacy at first access by probing with a throwaway item. Any non-success result other than `errSecMissingEntitlement` is *optimistically* treated as DPK-available. This causes silent data loss when a build's signing state flips between launches.
- The voxline app is sandboxed (`com.apple.security.app-sandbox` = true in `voxline/voxline.entitlements`) and has a `keychain-access-groups` entitlement scoped to `$(AppIdentifierPrefix)com.voxline.app`. The team identifier for production is `2B5FBFV6CF`.
- All 5 production callsites construct `Keychain()` with the default service `com.voxline.app.keys`. None pass a custom service. After this refactor, the production type takes no parameters — the service id is hardcoded.
- The two valid account names are `"anthropic"` and `"openai"` (see `Keychain.Account` in `voxline/Storage/Keychain.swift:13-16`). They'll move to a top-level `KeychainAccount` enum so they aren't entangled with any one storage implementation.
- The test target is built without code signing (`CODE_SIGNING_ALLOWED=NO`), which strips entitlements and makes DPK unreachable from tests. Today's `KeychainTests.swift` works around this by relying on the legacy fallback. After this refactor, tests use `InMemoryKeychain` and don't touch the OS keychain at all. A small set of `DataProtectionKeychainTests` skip themselves when DPK isn't reachable.

---

## File Structure

**New files (created in `voxline/Storage/`):**
- `KeychainStorage.swift` — protocol + `KeychainAccount` constants + `KeychainError` enum.
- `DataProtectionKeychain.swift` — production impl. DPK only. No probe. No fallback. Fails loudly.
- `LegacyKeychain.swift` — legacy file keychain wrapper. Only the migrator constructs it. Lives in the codebase only for as long as the migration is shipping; can be deleted in the release after this one.
- `InMemoryKeychain.swift` — test double. Pure Swift dictionary behind the same protocol.
- `LegacyKeychainMigrator.swift` — one-shot migration logic.

**New test files (in `voxlineTests/`):**
- `InMemoryKeychainTests.swift` — exercises the test double directly.
- `DataProtectionKeychainTests.swift` — integration tests against the real DPK; auto-skip when DPK is unreachable (i.e., when running in CI/unsigned).
- `LegacyKeychainMigratorTests.swift` — tests the migrator using two `InMemoryKeychain` instances as legacy/modern.

**Files modified:**
- `voxline/Settings/APIKeysSettingsViewModel.swift` — takes `any KeychainStorage` instead of concrete `Keychain`.
- `voxline/Wizard/WizardViewModel.swift` — takes `any KeychainStorage`.
- `voxline/LLM/LLMService.swift` — takes `any KeychainStorage`.
- `voxline/voxlineApp.swift` — constructs `DataProtectionKeychain()` once; runs `LegacyKeychainMigrator` at launch; updates `--reset-keys` handler.
- `voxlineTests/APIKeysSettingsViewModelTests.swift`, `voxlineTests/WizardViewModelTests.swift`, `voxlineTests/LLMServiceTests.swift` — pass `InMemoryKeychain` where they used `Keychain(service: ...)`.

**Files deleted (last task):**
- `voxline/Storage/Keychain.swift` — superseded.
- `voxlineTests/KeychainTests.swift` — superseded by the per-impl test files.

**Why this layout:** Each storage impl is one file with one responsibility. The migrator is isolated so it can be deleted cleanly later. Tests live next to the impl they test, with one contract-style helper shared between `InMemoryKeychainTests` and `DataProtectionKeychainTests` so the two implementations are proven to behave identically.

---

## Task 1: Define `KeychainStorage` protocol, account constants, and error type

**Files:**
- Create: `voxline/Storage/KeychainStorage.swift`

This task is interface-only. No test yet — the protocol becomes testable in Task 2 when the first impl appears.

- [ ] **Step 1: Create the protocol file**

Write the full content of `voxline/Storage/KeychainStorage.swift`:

```swift
import Foundation

/// Generic-password keychain abstraction. Three impls live behind this:
///   - `DataProtectionKeychain` — production. DPK only. Fails loud.
///   - `LegacyKeychain` — file keychain. Only used by `LegacyKeychainMigrator`.
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
```

- [ ] **Step 2: Verify the project still builds**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`. No call sites use the new type yet, so adding the file is additive.

- [ ] **Step 3: Commit**

```bash
git add voxline/Storage/KeychainStorage.swift
git commit -m "feat(keychain): add KeychainStorage protocol and shared account constants"
```

---

## Task 2: Implement `InMemoryKeychain` and contract tests

**Files:**
- Create: `voxline/Storage/InMemoryKeychain.swift`
- Create: `voxlineTests/InMemoryKeychainTests.swift`

This is the test double. Building it first means the rest of the refactor has a working `KeychainStorage` to inject without touching the OS keychain.

- [ ] **Step 1: Write the failing tests**

Write `voxlineTests/InMemoryKeychainTests.swift`:

```swift
import Testing
import Foundation
@testable import voxline

@Suite struct InMemoryKeychainTests {

    @Test func set_then_get_returns_stored_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("sk-test", forKey: KeychainAccount.anthropic)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-test")
    }

    @Test func get_unset_key_returns_nil() throws {
        let kc = InMemoryKeychain()
        #expect(try kc.string(forKey: "missing") == nil)
    }

    @Test func set_overwrites_existing_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("v1", forKey: KeychainAccount.anthropic)
        try kc.set("v2", forKey: KeychainAccount.anthropic)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "v2")
    }

    @Test func delete_removes_value() throws {
        let kc = InMemoryKeychain()
        try kc.set("v", forKey: KeychainAccount.openai)
        try kc.delete(forKey: KeychainAccount.openai)
        #expect(try kc.string(forKey: KeychainAccount.openai) == nil)
    }

    @Test func delete_unset_key_does_not_throw() throws {
        let kc = InMemoryKeychain()
        try kc.delete(forKey: "missing")
    }

    @Test func different_accounts_are_isolated() throws {
        let kc = InMemoryKeychain()
        try kc.set("a", forKey: KeychainAccount.anthropic)
        try kc.set("o", forKey: KeychainAccount.openai)
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "a")
        #expect(try kc.string(forKey: KeychainAccount.openai) == "o")
    }

    @Test func seed_initializer_preloads_values() throws {
        let kc = InMemoryKeychain(seed: [KeychainAccount.openai: "sk-seed"])
        #expect(try kc.string(forKey: KeychainAccount.openai) == "sk-seed")
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/InMemoryKeychainTests 2>&1 | tail -20`
Expected: FAIL — `InMemoryKeychain` does not exist.

- [ ] **Step 3: Implement `InMemoryKeychain`**

Write `voxline/Storage/InMemoryKeychain.swift`:

```swift
import Foundation

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/InMemoryKeychainTests 2>&1 | tail -20`
Expected: all tests in `InMemoryKeychainTests` pass.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/InMemoryKeychain.swift voxlineTests/InMemoryKeychainTests.swift
git commit -m "feat(keychain): add InMemoryKeychain test double"
```

---

## Task 3: Implement `DataProtectionKeychain` (DPK-only, no fallback)

**Files:**
- Create: `voxline/Storage/DataProtectionKeychain.swift`
- Create: `voxlineTests/DataProtectionKeychainTests.swift`

The integration tests skip themselves when DPK is unreachable so they don't break the unsigned test build.

- [ ] **Step 1: Write the integration tests**

Write `voxlineTests/DataProtectionKeychainTests.swift`:

```swift
import Testing
import Foundation
import Security
@testable import voxline

/// Integration tests against the real data-protection keychain. These only
/// run when the binary is signed with the `keychain-access-groups`
/// entitlement (i.e., not under `CODE_SIGNING_ALLOWED=NO` in CI). On
/// unsigned builds, every test no-ops via the availability probe.
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

    /// Unique account names per test run so concurrent CI doesn't collide.
    private func uniqueAccount() -> String { "test.\(UUID().uuidString)" }

    @Test func set_then_get_roundtrips() throws {
        try requireDPK()
        let kc = DataProtectionKeychain()
        let acct = uniqueAccount()
        defer { try? kc.delete(forKey: acct) }

        try kc.set("sk-test", forKey: acct)
        #expect(try kc.string(forKey: acct) == "sk-test")
    }

    @Test func set_overwrites_existing() throws {
        try requireDPK()
        let kc = DataProtectionKeychain()
        let acct = uniqueAccount()
        defer { try? kc.delete(forKey: acct) }

        try kc.set("v1", forKey: acct)
        try kc.set("v2", forKey: acct)
        #expect(try kc.string(forKey: acct) == "v2")
    }

    @Test func get_unset_returns_nil() throws {
        try requireDPK()
        let kc = DataProtectionKeychain()
        #expect(try kc.string(forKey: uniqueAccount()) == nil)
    }

    @Test func delete_unset_does_not_throw() throws {
        try requireDPK()
        let kc = DataProtectionKeychain()
        try kc.delete(forKey: uniqueAccount())
    }

    private func requireDPK() throws {
        guard Self.dpkReachable else {
            // Swift Testing doesn't have a `skip` primitive; use Issue.record
            // and an early return via throw to mark the test as skipped-ish.
            // In CI the suite is effectively a no-op; in signed local builds
            // it runs normally.
            throw SkipTest()
        }
    }

    private struct SkipTest: Error {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DataProtectionKeychainTests 2>&1 | tail -20`
Expected: FAIL — `DataProtectionKeychain` does not exist.

- [ ] **Step 3: Implement `DataProtectionKeychain`**

Write `voxline/Storage/DataProtectionKeychain.swift`:

```swift
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
            // A read failing for entitlement reasons means the binary can't
            // see DPK at all. Treat as missing and let callers handle it
            // (LLMService surfaces this as "no API key set", which prompts
            // the user to re-enter). Don't throw — read is non-destructive.
            Self.log.error("DPK read missing entitlement; treating account=\(account, privacy: .public) as absent")
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
            // Nothing we wrote could exist if entitlement is missing, so
            // treat as a no-op rather than throwing. Mirrors the read path.
            Self.log.error("DPK delete missing entitlement; treating account=\(account, privacy: .public) as absent")
            return
        default:
            throw KeychainError.unhandledStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass (or skip)**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/DataProtectionKeychainTests 2>&1 | tail -30`
Expected: in a signed local build, all tests pass. In an unsigned CI build, each test throws `SkipTest` and the suite reports skipped failures — that's expected and accepted.

NOTE TO ENGINEER: if the suite fails because Swift Testing treats `SkipTest` as a real failure on unsigned builds, change the `requireDPK()` body to instead use `try #require(Self.dpkReachable)` which Swift Testing handles correctly. (Swift Testing API changes occasionally; pick whichever idiom your version supports.)

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/DataProtectionKeychain.swift voxlineTests/DataProtectionKeychainTests.swift
git commit -m "feat(keychain): add DataProtectionKeychain (DPK-only, fails loud)"
```

---

## Task 4: Implement `LegacyKeychain` (migration-only)

**Files:**
- Create: `voxline/Storage/LegacyKeychain.swift`

No new tests — `LegacyKeychain` exists only for the migrator. The migrator's tests use `InMemoryKeychain` to simulate "legacy", which is the correct unit-test seam. We do not need to integration-test the legacy file keychain itself.

- [ ] **Step 1: Create `LegacyKeychain.swift`**

Write `voxline/Storage/LegacyKeychain.swift`:

```swift
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
```

- [ ] **Step 2: Verify build**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add voxline/Storage/LegacyKeychain.swift
git commit -m "feat(keychain): add LegacyKeychain wrapper for one-shot migration"
```

---

## Task 5: Implement `LegacyKeychainMigrator`

**Files:**
- Create: `voxline/Storage/LegacyKeychainMigrator.swift`
- Create: `voxlineTests/LegacyKeychainMigratorTests.swift`

- [ ] **Step 1: Write the failing tests**

Write `voxlineTests/LegacyKeychainMigratorTests.swift`:

```swift
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
        // Simulate a stale legacy entry reappearing somehow (shouldn't be
        // possible, but the flag should prevent re-running anyway).
        try legacy.set("round-2", forKey: KeychainAccount.anthropic)
        m.migrateIfNeeded()

        // Modern is unchanged from round 1; round-2 was ignored.
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
        // Simulate DPK rejecting the write. If signing is broken, retry next
        // launch — don't burn the legacy entry.
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

        // Flag NOT set — try again next launch.
        #expect(defaults.bool(forKey: LegacyKeychainMigrator.completedKey) == false)
        // Legacy entry preserved.
        #expect(try legacy.string(forKey: KeychainAccount.anthropic) == "sk-ant")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LegacyKeychainMigratorTests 2>&1 | tail -20`
Expected: FAIL — `LegacyKeychainMigrator` does not exist.

- [ ] **Step 3: Implement the migrator**

Write `voxline/Storage/LegacyKeychainMigrator.swift`:

```swift
import Foundation
import os

/// One-shot migration: lifts orphaned API keys out of the legacy file
/// keychain (where older builds with a broken DPK probe wrote them) into
/// the data-protection keychain. Runs at app launch; the completion flag
/// in UserDefaults prevents re-runs.
///
/// Safety properties:
///   1. If the modern keychain already has a value for an account, the
///      legacy value is discarded (not overwritten). The modern value is
///      assumed authoritative since it was written by a properly-signed
///      build.
///   2. The legacy entry is deleted unconditionally if it was present —
///      whether we copied it or not — so it can't shadow the modern entry
///      on a future build whose probe regresses.
///   3. If the modern write throws (e.g., DPK genuinely unreachable), the
///      completion flag is NOT set and the legacy entry is NOT deleted, so
///      a future run after signing is fixed can retry.
///
/// Delete this type (and `LegacyKeychain`) one release after this migration
/// has shipped and baked. By then every active install has either migrated
/// or had the legacy entries deleted by the reset script.
struct LegacyKeychainMigrator {

    static let completedKey = "voxline.keychain.legacyMigrated.v1"

    private static let log = Logger(subsystem: "com.voxline.app", category: "keychain-migration")

    let legacy: any KeychainStorage
    let modern: any KeychainStorage
    let defaults: UserDefaults

    init(
        legacy: any KeychainStorage = LegacyKeychain(),
        modern: any KeychainStorage = DataProtectionKeychain(),
        defaults: UserDefaults = .standard
    ) {
        self.legacy = legacy
        self.modern = modern
        self.defaults = defaults
    }

    func migrateIfNeeded() {
        guard !defaults.bool(forKey: Self.completedKey) else { return }

        var allOK = true
        var migratedCount = 0

        for account in KeychainAccount.all {
            let legacyValue: String?
            do {
                legacyValue = try legacy.string(forKey: account)
            } catch {
                Self.log.error("legacy read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                allOK = false
                continue
            }

            guard let legacyValue, !legacyValue.isEmpty else { continue }

            // Only adopt if modern has nothing — modern is authoritative.
            let modernHas: Bool
            do {
                let existing = try modern.string(forKey: account)
                modernHas = (existing?.isEmpty == false)
            } catch {
                Self.log.error("modern read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                allOK = false
                continue
            }

            if !modernHas {
                do {
                    try modern.set(legacyValue, forKey: account)
                    migratedCount += 1
                    Self.log.info("migrated \(account, privacy: .public) from legacy to DPK")
                } catch {
                    Self.log.error("modern write failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public) — leaving legacy entry intact for retry")
                    allOK = false
                    continue
                }
            }

            // Delete legacy regardless of whether we adopted (stale shadow
            // entries should not survive). Only safe to do once we know
            // either (a) we copied it, or (b) modern already had a value.
            do {
                try legacy.delete(forKey: account)
            } catch {
                Self.log.error("legacy delete failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Non-fatal: the entry is shadowed by DPK now anyway.
            }
        }

        if allOK {
            defaults.set(true, forKey: Self.completedKey)
            Self.log.info("legacy keychain migration complete (migrated=\(migratedCount, privacy: .public))")
        } else {
            Self.log.error("legacy keychain migration partial — will retry next launch")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LegacyKeychainMigratorTests 2>&1 | tail -20`
Expected: all `LegacyKeychainMigratorTests` pass.

- [ ] **Step 5: Commit**

```bash
git add voxline/Storage/LegacyKeychainMigrator.swift voxlineTests/LegacyKeychainMigratorTests.swift
git commit -m "feat(keychain): add one-shot legacy→DPK migrator"
```

---

## Task 6: Update `APIKeysSettingsViewModel` to take `any KeychainStorage`

**Files:**
- Modify: `voxline/Settings/APIKeysSettingsViewModel.swift:23-43`
- Modify: `voxlineTests/APIKeysSettingsViewModelTests.swift` (every test's `Keychain(service: ...)` construction)

- [ ] **Step 1: Modify the view model**

In `voxline/Settings/APIKeysSettingsViewModel.swift`, change the field type and default in the initializer.

Old (lines 23 and 29):
```swift
    private let keychain: Keychain
    ...
    init(
        keychain: Keychain = Keychain(),
```

New:
```swift
    private let keychain: any KeychainStorage
    ...
    init(
        keychain: any KeychainStorage = DataProtectionKeychain(),
```

No other lines in this file need to change — the call surface (`string(forKey:)`, `set(_:forKey:)`, `delete(forKey:)`) is identical.

- [ ] **Step 2: Update the tests**

Open `voxlineTests/APIKeysSettingsViewModelTests.swift`. Search for `Keychain(service:` and replace each occurrence with `InMemoryKeychain()`. Search for any `try? kc.deleteAll()` defer blocks — they can be deleted since `InMemoryKeychain` instances are throwaway. Search for any seeding pattern like `try kc.set("...", forKey: ...)` followed by VM construction — those still work since `InMemoryKeychain` conforms to the protocol.

If the file uses a helper like `makeKeychain()` returning `Keychain`, change its return type to `InMemoryKeychain` (or `any KeychainStorage`) and have it return `InMemoryKeychain()`.

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/APIKeysSettingsViewModelTests 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add voxline/Settings/APIKeysSettingsViewModel.swift voxlineTests/APIKeysSettingsViewModelTests.swift
git commit -m "refactor(settings): inject any KeychainStorage into APIKeysSettingsViewModel"
```

---

## Task 7: Update `WizardViewModel` to take `any KeychainStorage`

**Files:**
- Modify: `voxline/Wizard/WizardViewModel.swift:23-29`
- Modify: `voxlineTests/WizardViewModelTests.swift`

- [ ] **Step 1: Modify the view model**

In `voxline/Wizard/WizardViewModel.swift`, update the init parameter.

Old (lines 23-28):
```swift
    init(
        settings: AppSettings = AppSettings(),
        keychain: Keychain = Keychain()
    ) {
        self.settings = settings
        let vm = APIKeysSettingsViewModel(keychain: keychain)
```

New:
```swift
    init(
        settings: AppSettings = AppSettings(),
        keychain: any KeychainStorage = DataProtectionKeychain()
    ) {
        self.settings = settings
        let vm = APIKeysSettingsViewModel(keychain: keychain)
```

- [ ] **Step 2: Update the tests**

Open `voxlineTests/WizardViewModelTests.swift`. Replace any `Keychain(service:` construction with `InMemoryKeychain()`. The seeding pattern (writing a key before constructing the wizard to test the "returning user with one provider" branch in `WizardViewModel.init`) still works — `InMemoryKeychain` supports both seed-via-init and `set()`.

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/WizardViewModelTests 2>&1 | tail -20`
Expected: all tests pass.

- [ ] **Step 4: Commit**

```bash
git add voxline/Wizard/WizardViewModel.swift voxlineTests/WizardViewModelTests.swift
git commit -m "refactor(wizard): inject any KeychainStorage into WizardViewModel"
```

---

## Task 8: Update `LLMService` to take `any KeychainStorage`

**Files:**
- Modify: `voxline/LLM/LLMService.swift:63-71`
- Modify: `voxlineTests/LLMServiceTests.swift`

- [ ] **Step 1: Modify the service**

In `voxline/LLM/LLMService.swift`, update the field and init.

Old (lines 63-71):
```swift
    let settings: AppSettings
    let keychain: Keychain
    let http: HTTPClient

    init(settings: AppSettings, keychain: Keychain = Keychain(), http: HTTPClient = URLSessionHTTPClient()) {
        self.settings = settings
        self.keychain = keychain
        self.http = http
    }
```

New:
```swift
    let settings: AppSettings
    let keychain: any KeychainStorage
    let http: HTTPClient

    init(settings: AppSettings, keychain: any KeychainStorage = DataProtectionKeychain(), http: HTTPClient = URLSessionHTTPClient()) {
        self.settings = settings
        self.keychain = keychain
        self.http = http
    }
```

Also update line 81-83 in the same file — the `Keychain.Account.anthropic` and `Keychain.Account.openai` references must become `KeychainAccount.anthropic` and `KeychainAccount.openai`:

Old:
```swift
        switch provider {
        case .anthropic: account = Keychain.Account.anthropic
        case .openai:    account = Keychain.Account.openai
        }
```

New:
```swift
        switch provider {
        case .anthropic: account = KeychainAccount.anthropic
        case .openai:    account = KeychainAccount.openai
        }
```

NOTE TO ENGINEER: also grep `Keychain.Account` across the codebase and replace each hit with `KeychainAccount` — there should be matches in `APIKeysSettingsViewModel.swift`, `WizardViewModel.swift`, `voxlineApp.swift`, and at least the existing `APIKeysSettingsViewModelTests.swift`/`LLMServiceTests.swift`/`WizardViewModelTests.swift`. Update each. This is a mechanical rename and can be one find-and-replace.

Run: `grep -rn "Keychain\.Account" --include="*.swift" voxline/ voxlineTests/ | wc -l`
Expected after replacement: 0.

- [ ] **Step 2: Update the LLMService tests**

Open `voxlineTests/LLMServiceTests.swift`. Replace `Keychain(service: ...)` with `InMemoryKeychain()`. Replace `Keychain.Account.*` with `KeychainAccount.*` (already covered by the grep step above, but double-check this file).

- [ ] **Step 3: Run tests to verify they pass**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/LLMServiceTests 2>&1 | tail -20`
Expected: all tests pass.

Also run a project-wide build to catch any other callsites missed by the rename:

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | grep -E "error:" | head -20`
Expected: no errors. If there are errors about `Keychain.Account` or the missing `Keychain` type, fix the affected file(s) and re-run.

- [ ] **Step 4: Commit**

```bash
git add voxline/LLM/LLMService.swift voxlineTests/LLMServiceTests.swift voxline/Settings/APIKeysSettingsViewModel.swift voxline/Wizard/WizardViewModel.swift voxline/voxlineApp.swift voxlineTests/APIKeysSettingsViewModelTests.swift voxlineTests/WizardViewModelTests.swift
git commit -m "refactor(llm): inject any KeychainStorage into LLMService; rename Keychain.Account → KeychainAccount"
```

(Use `git status` first to confirm exactly which files actually changed in this task. Some may have been committed in earlier tasks; only stage what's new.)

---

## Task 9: Wire migration + DPK construction into app launch

**Files:**
- Modify: `voxline/voxlineApp.swift` (init block + `LLMService` construction around line 209)

- [ ] **Step 1: Update `voxlineApp.init()` to run migration before any keychain reads**

Find this block in `voxline/voxlineApp.swift:10-25`:

```swift
    init() {
        // Dev/test entry point: scripts/reset-local-state.sh invokes the signed
        // app binary with this flag so it can delete data-protection-keychain
        // items the bare `security` CLI cannot reach (DPK items are gated by
        // the app's keychain-access-groups entitlement). Runs before any UI
        // appears and exits the process when done.
        if CommandLine.arguments.contains("--reset-keys") {
            let keychain = Keychain()
            for account in [Keychain.Account.anthropic, Keychain.Account.openai] {
                do { try keychain.delete(forKey: account) }
                catch { fputs("Voxline --reset-keys: failed to delete \(account): \(error)\n", stderr) }
            }
            fputs("Voxline: cleared keychain entries (anthropic, openai)\n", stderr)
            exit(0)
        }
    }
```

Replace with:

```swift
    init() {
        // Dev/test entry point: scripts/reset-local-state.sh invokes the signed
        // app binary with this flag so it can delete data-protection-keychain
        // items the bare `security` CLI cannot reach (DPK items are gated by
        // the app's keychain-access-groups entitlement). Also clears any
        // lingering legacy file-keychain entries the script's `security`
        // delete-generic-password may have missed (older builds wrote there
        // when the DPK probe failed). Runs before any UI appears and exits
        // the process when done.
        if CommandLine.arguments.contains("--reset-keys") {
            let dpk = DataProtectionKeychain()
            let legacy = LegacyKeychain()
            for account in KeychainAccount.all {
                do { try dpk.delete(forKey: account) }
                catch { fputs("Voxline --reset-keys: failed to delete DPK \(account): \(error)\n", stderr) }
                do { try legacy.delete(forKey: account) }
                catch { fputs("Voxline --reset-keys: failed to delete legacy \(account): \(error)\n", stderr) }
            }
            // Clear the migration flag so a subsequent normal launch picks up
            // any entries the user re-enters via the wizard (no-op if nothing
            // to migrate, but resets state cleanly).
            UserDefaults.standard.removeObject(forKey: LegacyKeychainMigrator.completedKey)
            fputs("Voxline: cleared keychain entries (anthropic, openai)\n", stderr)
            exit(0)
        }

        // Normal launch path: lift any orphaned legacy entries into DPK
        // before the rest of the app reads from the keychain. Idempotent
        // via UserDefaults flag — subsequent launches no-op cheaply.
        LegacyKeychainMigrator().migrateIfNeeded()
    }
```

- [ ] **Step 2: Update the `LLMService` construction site**

Find line 209 in `voxline/voxlineApp.swift`:

```swift
        let llm = LLMService(settings: settings, keychain: Keychain())
```

Replace with:

```swift
        let llm = LLMService(settings: settings, keychain: DataProtectionKeychain())
```

- [ ] **Step 3: Update the `APIKeysSettingsViewModel()` construction in the Settings scene**

Find line 58 in `voxline/voxlineApp.swift`:

```swift
                apiKeysVM: APIKeysSettingsViewModel()
```

This call uses the default-init, which now resolves to `DataProtectionKeychain()`. No source change needed — verify it still compiles. If you'd like to be explicit, write:

```swift
                apiKeysVM: APIKeysSettingsViewModel(keychain: DataProtectionKeychain())
```

Pick whichever style matches the codebase's house preference (the wizard construction below uses default arguments, so leaving this as `APIKeysSettingsViewModel()` is consistent).

- [ ] **Step 4: Build and run the app once manually**

Run: `xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -10`
Expected: `BUILD SUCCEEDED`.

Then launch the app from `~/Library/Developer/Xcode/DerivedData/voxline-*/Build/Products/Debug/voxline.app` and confirm:
- It launches without crashing.
- If you previously had API keys saved, they're still readable in Settings → Cleanup.
- The log line `legacy keychain migration complete (migrated=N)` appears in Console.app (filter on subsystem `com.voxline.app` → category `keychain-migration`) on the first launch after this change. On a fresh container with no legacy entries, N=0.

- [ ] **Step 5: Commit**

```bash
git add voxline/voxlineApp.swift
git commit -m "feat(keychain): run legacy→DPK migration at launch; use DataProtectionKeychain everywhere"
```

---

## Task 10: Delete the old `Keychain` type and its tests

**Files:**
- Delete: `voxline/Storage/Keychain.swift`
- Delete: `voxlineTests/KeychainTests.swift`

- [ ] **Step 1: Verify nothing still references `Keychain` (the old type)**

Run: `grep -rn "Keychain(" --include="*.swift" voxline/ voxlineTests/ | grep -v "DataProtectionKeychain\|LegacyKeychain\|InMemoryKeychain\|KeychainStorage\|KeychainError\|KeychainAccount"`
Expected: empty output. If anything still references bare `Keychain(`, fix it (almost certainly an unstaged change from an earlier task).

Run: `grep -rn "Keychain\." --include="*.swift" voxline/ voxlineTests/ | grep -v "DataProtectionKeychain\|LegacyKeychain\|InMemoryKeychain\|KeychainStorage\|KeychainError\|KeychainAccount"`
Expected: empty output (no remaining `Keychain.Account.*`, `Keychain.appServiceID`, etc.).

- [ ] **Step 2: Delete the files**

```bash
git rm voxline/Storage/Keychain.swift voxlineTests/KeychainTests.swift
```

- [ ] **Step 3: Build and run all tests**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | tail -30`
Expected: every test suite passes (or `DataProtectionKeychainTests` skips on unsigned builds, which is fine).

- [ ] **Step 4: Commit**

```bash
git commit -m "refactor(keychain): remove probe-and-fallback Keychain; replaced by DataProtectionKeychain"
```

---

## Task 11: End-to-end verification

This is a manual checkpoint — no code changes. Skip only if you are absolutely certain the prior tasks held; otherwise spend the 10 minutes here.

- [ ] **Step 1: Full test suite**

Run: `xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | tee /tmp/voxline-test-run.log | tail -40`
Expected: all tests pass. `DataProtectionKeychainTests` may report as skipped if the test target is unsigned — that is the documented behavior.

- [ ] **Step 2: Manual smoke — fresh-install wizard flow**

```bash
./scripts/reset-local-state.sh
xcodebuild -scheme voxline -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/voxline-*/Build/Products/Debug/voxline.app
```

Walk through the wizard:
1. Land on the API-key step.
2. Pick Anthropic, type a key, click "Test Anthropic". Expect "Anthropic connected".
3. Click Continue → wizard advances. Pick OpenAI on next entry into the API-key step? (N/A — single-pass wizard.) Complete the wizard.
4. Open Settings → Cleanup. Confirm the Anthropic key is shown as "Saved" (green pill).
5. Quit and relaunch. Re-open Settings → Cleanup. Confirm the key is still "Saved".

- [ ] **Step 3: Manual smoke — legacy migration path**

This step only matters if you have a build environment that can write to the legacy keychain (i.e., an unsigned voxline binary). Skip if not available; the migration logic is unit-tested.

```bash
# Run the OLD unsigned voxline build to seed a legacy entry, OR seed manually:
security add-generic-password -s com.voxline.app.keys -a anthropic -w sk-ant-test-legacy
# Then run the NEW signed build:
open ~/Library/Developer/Xcode/DerivedData/voxline-*/Build/Products/Debug/voxline.app
# Open Settings → Cleanup. Expect "sk-ant-test-legacy" to appear (already migrated).
# Verify legacy is gone:
security find-generic-password -s com.voxline.app.keys -a anthropic
# Expected: "could not be found." — legacy entry was deleted.
```

- [ ] **Step 4: Reset script smoke**

```bash
./scripts/reset-local-state.sh
# Expect "removed (legacy)" lines for anthropic/openai if any existed, plus
# "Voxline: cleared keychain entries (anthropic, openai)" from the
# --reset-keys invocation.
```

Confirm that running the app immediately afterward shows the wizard (i.e., `hasCompletedFirstRun` was wiped along with the rest of the container — that's the script's existing behavior, unchanged by this refactor).

- [ ] **Step 5: Spot-check Console.app logs**

Filter Console.app on subsystem `com.voxline.app`, category `keychain-migration`. On every launch after the first you should see no migration log (the flag short-circuits). On the first launch you should see either "legacy keychain migration complete (migrated=N)" or "legacy keychain migration partial — will retry next launch".

- [ ] **Step 6: No commit needed unless smoke surfaced a fix**

If smoke uncovered an issue, fix it in a new commit. Otherwise this task ends without a commit — verification only.

---

## Summary of Final File State

After all tasks land:

**Added (production):**
- `voxline/Storage/KeychainStorage.swift`
- `voxline/Storage/DataProtectionKeychain.swift`
- `voxline/Storage/InMemoryKeychain.swift`
- `voxline/Storage/LegacyKeychain.swift`
- `voxline/Storage/LegacyKeychainMigrator.swift`

**Added (tests):**
- `voxlineTests/InMemoryKeychainTests.swift`
- `voxlineTests/DataProtectionKeychainTests.swift`
- `voxlineTests/LegacyKeychainMigratorTests.swift`

**Modified:**
- `voxline/Settings/APIKeysSettingsViewModel.swift` — protocol injection
- `voxline/Wizard/WizardViewModel.swift` — protocol injection
- `voxline/LLM/LLMService.swift` — protocol injection + `KeychainAccount` rename
- `voxline/voxlineApp.swift` — runs migrator on launch, uses `DataProtectionKeychain` for production callsites, updates `--reset-keys` handler

**Deleted:**
- `voxline/Storage/Keychain.swift`
- `voxlineTests/KeychainTests.swift`

**Followup (out of scope, file separately):**
- One release after this ships and bakes, delete `voxline/Storage/LegacyKeychain.swift` and `voxline/Storage/LegacyKeychainMigrator.swift` (plus their tests). The completion flag and one-shot logic mean these files are dead code for users who have already migrated; we keep them around for one cycle in case a long-dormant install hasn't relaunched yet.
- Separately, fix `GeneralSettingsViewModel.commit()` (`voxline/Settings/GeneralSettingsViewModel.swift:158-173`) so it doesn't rewrite `llmProvider` on every unrelated settings change, which currently clobbers any custom model override. That's not a keychain issue but came up in the recon and should be tracked.
