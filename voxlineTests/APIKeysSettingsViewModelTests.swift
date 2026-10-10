import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct APIKeysSettingsViewModelTests {

    private func keychain() -> InMemoryKeychain {
        InMemoryKeychain()
    }

    @Test func commit_anthropic_persists_only_anthropic_and_trims() throws {
        let kc = keychain()
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "  sk-ant-123\n "
        vm.openaiKey    = "should-not-write"
        vm.commitAnthropic()
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-ant-123")
        #expect(try kc.string(forKey: KeychainAccount.openai) == nil)
    }

    @Test func commit_openai_persists_only_openai_and_trims() throws {
        let kc = keychain()
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.openaiKey = "\tsk-openai-xyz \n"
        vm.commitOpenAI()
        #expect(try kc.string(forKey: KeychainAccount.openai) == "sk-openai-xyz")
    }

    @Test func empty_commit_deletes_keychain_entry() throws {
        let kc = keychain()
        try kc.set("preexisting", forKey: KeychainAccount.anthropic)
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "   "
        vm.commitAnthropic()
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == nil)
    }

    @Test func has_saved_key_follows_commits_not_typing() throws {
        let kc = keychain()
        try kc.set("sk-openai-saved", forKey: KeychainAccount.openai)
        let vm = APIKeysSettingsViewModel(keychain: kc)
        #expect(vm.hasSavedKey(.openai))
        #expect(!vm.hasSavedKey(.anthropic))

        vm.openaiKey = ""
        #expect(vm.hasSavedKey(.openai))
        vm.commitOpenAI()
        #expect(!vm.hasSavedKey(.openai))

        vm.anthropicKey = "sk-ant-new"
        #expect(!vm.hasSavedKey(.anthropic))
        vm.commitAnthropic()
        #expect(vm.hasSavedKey(.anthropic))
    }

    @Test func test_result_resets_when_relevant_key_changes() {
        let vm = APIKeysSettingsViewModel(keychain: keychain())
        vm.testResult = .success(.anthropic)
        vm.anthropicKey = "new-key"
        #expect(vm.testResult == .untested)
    }

    @Test func test_result_for_other_provider_persists_when_unrelated_key_changes() {
        let vm = APIKeysSettingsViewModel(keychain: keychain())
        vm.testResult = .success(.anthropic)
        vm.openaiKey = "new-openai-key"
        #expect(vm.testResult == .success(.anthropic))
    }

    @Test func last_error_clears_when_any_key_changes() {
        let vm = APIKeysSettingsViewModel(keychain: keychain())
        vm.lastError = "Save failed: keychain unavailable"
        vm.anthropicKey = "x"
        #expect(vm.lastError == nil)
    }

    @Test func test_connection_success_sets_success_for_provider() async throws {
        let kc = keychain()
        try kc.set("k", forKey: KeychainAccount.anthropic)
        let vm = APIKeysSettingsViewModel(
            keychain: kc,
            clientFactory: { _, _ in StubClient(mode: .ok) }
        )
        // testConnection now reads the live in-memory key (not keychain).
        vm.anthropicKey = "k"
        await vm.testConnection(.anthropic)
        if case .success(let p) = vm.testResult { #expect(p == .anthropic) } else { Issue.record("expected .success(.anthropic), got \(vm.testResult)") }
    }

    @Test func test_connection_fail_sets_failed_for_provider_with_message() async throws {
        let kc = keychain()
        try kc.set("k", forKey: KeychainAccount.openai)
        let vm = APIKeysSettingsViewModel(
            keychain: kc,
            clientFactory: { _, _ in StubClient(mode: .fail(.invalidAPIKey)) }
        )
        vm.openaiKey = "k"
        await vm.testConnection(.openai)
        if case .failed(let p, let msg) = vm.testResult {
            #expect(p == .openai)
            #expect(msg.contains("rejected") || msg.contains("API key"))
        } else {
            Issue.record("expected .failed(.openai, _), got \(vm.testResult)")
        }
    }

    @Test func test_connection_no_key_sets_failed_without_calling_factory() async throws {
        let kc = keychain()
        final class CallCounter { var n = 0 }
        let counter = CallCounter()
        let vm = APIKeysSettingsViewModel(
            keychain: kc,
            clientFactory: { _, _ in counter.n += 1; return StubClient(mode: .ok) }
        )
        // Live key empty (default) → factory should never be called
        await vm.testConnection(.anthropic)
        #expect(counter.n == 0)
        if case .failed(let p, let msg) = vm.testResult {
            #expect(p == .anthropic)
            #expect(msg == "No API key set.")
        } else {
            Issue.record("expected .failed(.anthropic, \"No API key set.\")")
        }
    }

    @Test func isPersisted_true_when_trimmed_live_matches_keychain() throws {
        let kc = keychain()
        try kc.set("real-key", forKey: KeychainAccount.anthropic)
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "  real-key\n"   // whitespace doesn't matter
        #expect(vm.isPersisted(.anthropic) == true)
    }

    @Test func isPersisted_false_when_live_differs_from_keychain() throws {
        let kc = keychain()
        try kc.set("real-key", forKey: KeychainAccount.anthropic)
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "different"
        #expect(vm.isPersisted(.anthropic) == false)
    }

    @Test func isPersisted_uses_cached_value_not_keychain_read() throws {
        let kc = keychain()
        try kc.set("real-key", forKey: KeychainAccount.anthropic)

        let vm = APIKeysSettingsViewModel(keychain: kc)
        #expect(vm.isPersisted(.anthropic))   // seeded from keychain at init

        // Mutate keychain externally — VM cache should not change.
        try kc.set("changed-out-of-band", forKey: KeychainAccount.anthropic)
        #expect(vm.isPersisted(.anthropic))   // still true; cache reflects in-memory pair

        // Edit live — cache stale until commit.
        vm.anthropicKey = "different"
        #expect(!vm.isPersisted(.anthropic))

        // Commit — cache refreshes from the live value.
        vm.commitAnthropic()
        #expect(vm.isPersisted(.anthropic))
    }

    @Test func read_failure_leaves_field_empty_and_reports() {
        let kc = keychain()
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)
        #expect(vm.anthropicKey == "")
        #expect(vm.openaiKey == "")
        #expect(vm.lastError?.lowercased().contains("keychain") == true)
    }

    @Test func empty_commit_after_read_failure_keeps_stored_key() throws {
        let kc = keychain()
        try kc.set("sk-real", forKey: KeychainAccount.anthropic)
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)

        vm.commitAnthropic()

        kc.readError = nil
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-real")
    }

    @Test func openai_key_change_is_reported_only_when_the_saved_key_changes() {
        var changes = 0
        let vm = APIKeysSettingsViewModel(keychain: keychain(), onOpenAIKeyChange: { changes += 1 })

        vm.commitOpenAI()
        #expect(changes == 0)

        vm.openaiKey = "sk-openai-new"
        vm.commitOpenAI()
        #expect(changes == 1)

        vm.openaiKey = " sk-openai-new\n"
        vm.commitOpenAI()
        #expect(changes == 1)

        vm.openaiKey = ""
        vm.commitOpenAI()
        #expect(changes == 2)

        vm.anthropicKey = "sk-ant-new"
        vm.commitAnthropic()
        #expect(changes == 2)
    }

    @Test func commit_without_an_edit_keeps_a_key_saved_elsewhere() throws {
        let kc = keychain()
        let vm = APIKeysSettingsViewModel(keychain: kc)
        try kc.set("sk-ant-from-wizard", forKey: KeychainAccount.anthropic)
        try kc.set("sk-openai-from-wizard", forKey: KeychainAccount.openai)

        vm.commitAnthropic()
        vm.commitOpenAI()

        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-ant-from-wizard")
        #expect(try kc.string(forKey: KeychainAccount.openai) == "sk-openai-from-wizard")
    }

    @Test func failed_save_keeps_offering_save() throws {
        let kc = FailingWriteKeychain()
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "sk-ant-new"
        vm.commitAnthropic()
        #expect(!vm.isPersisted(.anthropic))
        #expect(!vm.hasSavedKey(.anthropic))
        #expect(vm.lastError?.hasPrefix("Save failed") == true)
    }

    @Test func reload_picks_up_keys_saved_elsewhere() throws {
        let kc = keychain()
        var openAIChanges = 0
        let vm = APIKeysSettingsViewModel(keychain: kc, onOpenAIKeyChange: { openAIChanges += 1 })
        try kc.set("sk-ant-from-wizard", forKey: KeychainAccount.anthropic)
        try kc.set("sk-openai-from-wizard", forKey: KeychainAccount.openai)

        vm.reloadSavedKeys()

        #expect(vm.anthropicKey == "sk-ant-from-wizard")
        #expect(vm.openaiKey == "sk-openai-from-wizard")
        #expect(vm.isPersisted(.anthropic))
        #expect(vm.hasSavedKey(.openai))
        #expect(openAIChanges == 0)
    }

    @Test func reload_keeps_an_unsaved_edit() throws {
        let kc = keychain()
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "sk-ant-typing"
        try kc.set("sk-ant-from-wizard", forKey: KeychainAccount.anthropic)

        vm.reloadSavedKeys()

        #expect(vm.anthropicKey == "sk-ant-typing")
        #expect(!vm.isPersisted(.anthropic))
    }

    @Test func reload_after_a_read_failure_recovers_the_key() throws {
        let kc = keychain()
        try kc.set("sk-real", forKey: KeychainAccount.anthropic)
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)
        kc.readError = nil

        vm.reloadSavedKeys()

        #expect(vm.anthropicKey == "sk-real")
        #expect(vm.hasSavedKey(.anthropic))
    }

    @Test func typed_key_after_read_failure_saves_and_reenables_delete() throws {
        let kc = keychain()
        kc.readError = KeychainError.dataProtectionKeychainUnavailable
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "sk-new"
        vm.commitAnthropic()
        kc.readError = nil
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == "sk-new")

        vm.anthropicKey = ""
        vm.commitAnthropic()
        #expect(try kc.string(forKey: KeychainAccount.anthropic) == nil)
    }
}

private struct FailingWriteKeychain: KeychainStorage {
    func string(forKey account: String) throws -> String? { nil }
    func set(_ value: String, forKey account: String) throws {
        throw KeychainError.dataProtectionKeychainUnavailable
    }
    func delete(forKey account: String) throws {
        throw KeychainError.dataProtectionKeychainUnavailable
    }
}

private struct StubClient: LLMClient {
    enum Mode { case ok, fail(LLMError) }
    let mode: Mode
    func complete(_ request: LLMRequest) async throws -> String {
        switch mode {
        case .ok: return "ok"
        case .fail(let err): throw err
        }
    }
}
