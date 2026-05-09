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

    @Test func loads_existing_keys_and_provider_on_init() throws {
        let defaults = defaultsSuite()
        var settings = AppSettings(defaults: defaults)
        settings.llmProvider = .openai
        let kc = keychain()
        try kc.set("a-key", forKey: Keychain.Account.anthropic)
        try kc.set("o-key", forKey: Keychain.Account.openai)
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        #expect(vm.provider == .openai)
        #expect(vm.anthropicKey == "a-key")
        #expect(vm.openaiKey == "o-key")
    }

    @Test func save_persists_provider_and_keys() throws {
        let defaults = defaultsSuite()
        let settings = AppSettings(defaults: defaults)
        let kc = keychain()
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        vm.provider = .openai
        vm.anthropicKey = "new-a"
        vm.openaiKey = "new-o"
        try vm.save()

        #expect(AppSettings(defaults: defaults).llmProvider == .openai)
        #expect(try kc.string(forKey: Keychain.Account.anthropic) == "new-a")
        #expect(try kc.string(forKey: Keychain.Account.openai) == "new-o")
    }

    @Test func save_with_empty_key_deletes_keychain_entry() throws {
        let defaults = defaultsSuite()
        let settings = AppSettings(defaults: defaults)
        let kc = keychain()
        try kc.set("preexisting", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let vm = APIKeysSettingsViewModel(settings: settings, keychain: kc)
        vm.anthropicKey = ""   // Cleared by user
        try vm.save()

        #expect(try kc.string(forKey: Keychain.Account.anthropic) == nil)
    }
}
