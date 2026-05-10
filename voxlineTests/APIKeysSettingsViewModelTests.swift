import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct APIKeysSettingsViewModelTests {

    private func defaultsSuite() -> UserDefaults {
        let n = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: n)!
        d.removePersistentDomain(forName: n)
        return d
    }
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
}
