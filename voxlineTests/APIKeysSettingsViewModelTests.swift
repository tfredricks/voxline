import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct APIKeysSettingsViewModelTests {

    private func keychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func commit_anthropic_persists_only_anthropic_and_trims() throws {
        let kc = keychain()
        defer { try? kc.deleteAll() }
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "  sk-ant-123\n "
        vm.openaiKey    = "should-not-write"
        vm.commitAnthropic()
        #expect(try kc.string(forKey: Keychain.Account.anthropic) == "sk-ant-123")
        #expect(try kc.string(forKey: Keychain.Account.openai) == nil)
    }

    @Test func commit_openai_persists_only_openai_and_trims() throws {
        let kc = keychain()
        defer { try? kc.deleteAll() }
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.openaiKey = "\tsk-openai-xyz \n"
        vm.commitOpenAI()
        #expect(try kc.string(forKey: Keychain.Account.openai) == "sk-openai-xyz")
    }

    @Test func empty_commit_deletes_keychain_entry() throws {
        let kc = keychain()
        try kc.set("preexisting", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "   "
        vm.commitAnthropic()
        #expect(try kc.string(forKey: Keychain.Account.anthropic) == nil)
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
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }
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
        try kc.set("k", forKey: Keychain.Account.openai)
        defer { try? kc.deleteAll() }
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
        defer { try? kc.deleteAll() }
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
        try kc.set("real-key", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "  real-key\n"   // whitespace doesn't matter
        #expect(vm.isPersisted(.anthropic) == true)
    }

    @Test func isPersisted_false_when_live_differs_from_keychain() throws {
        let kc = keychain()
        try kc.set("real-key", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }
        let vm = APIKeysSettingsViewModel(keychain: kc)
        vm.anthropicKey = "different"
        #expect(vm.isPersisted(.anthropic) == false)
    }

    @Test func isPersisted_uses_cached_value_not_keychain_read() throws {
        let kc = keychain()
        try kc.set("real-key", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(keychain: kc)
        #expect(vm.isPersisted(.anthropic))   // seeded from keychain at init

        // Mutate keychain externally — VM cache should not change.
        try kc.set("changed-out-of-band", forKey: Keychain.Account.anthropic)
        #expect(vm.isPersisted(.anthropic))   // still true; cache reflects in-memory pair

        // Edit live — cache stale until commit.
        vm.anthropicKey = "different"
        #expect(!vm.isPersisted(.anthropic))

        // Commit — cache refreshes from the live value.
        vm.commitAnthropic()
        #expect(vm.isPersisted(.anthropic))
    }
}

private struct StubClient: LLMClient {
    enum Mode { case ok, fail(LLMError) }
    let mode: Mode
    func cleanup(_ request: LLMRequest) async throws -> String {
        switch mode {
        case .ok: return "ok"
        case .fail(let err): throw err
        }
    }
}
