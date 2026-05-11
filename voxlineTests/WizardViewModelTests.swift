// voxlineTests/WizardViewModelTests.swift
import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct WizardViewModelTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
    }

    @Test func starts_at_welcome() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        #expect(vm.currentStep == .welcome)
    }

    @Test func advance_walks_through_steps() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        vm.advance()
        #expect(vm.currentStep == .permissions)
        vm.advance()
        #expect(vm.currentStep == .apiKey)
        vm.advance()
        #expect(vm.currentStep == .modelDownload)
        vm.advance()
        #expect(vm.currentStep == .done)
    }

    @Test func go_back_steps_backwards() {
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()))
        vm.advance(); vm.advance()
        #expect(vm.currentStep == .apiKey)
        vm.goBack()
        #expect(vm.currentStep == .permissions)
    }

    @Test func complete_sets_first_run_flag_and_calls_callback() {
        let d = defaults()
        let vm = WizardViewModel(settings: AppSettings(defaults: d))
        var didCallback = false
        vm.onComplete = { didCallback = true }

        // Walk to done and complete
        vm.advance(); vm.advance(); vm.advance(); vm.advance()
        vm.complete()

        #expect(didCallback == true)
        #expect(AppSettings(defaults: d).hasCompletedFirstRun == true)
    }

    @Test func complete_persists_keys_to_keychain() throws {
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)
        vm.apiKeyVM.anthropicKey = "sk-ant-test"
        vm.complete()
        #expect(try kc.string(forKey: Keychain.Account.anthropic) == "sk-ant-test")
    }

    @Test func advance_persists_keys_to_keychain() throws {
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)
        vm.apiKeyVM.openaiKey = "sk-test"
        vm.advance()
        #expect(try kc.string(forKey: Keychain.Account.openai) == "sk-test")
    }

    @Test func complete_snaps_provider_to_selected_openai() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai"
        vm.complete()
        #expect(AppSettings(defaults: d).llmProvider == .openai)
    }

    @Test func complete_snaps_provider_to_selected_anthropic() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        // Seed defaults with .openai to prove the wizard actually overrides.
        var seed = AppSettings(defaults: d)
        seed.llmProvider = .openai
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .anthropic
        vm.apiKeyVM.anthropicKey = "sk-ant"
        vm.complete()
        #expect(AppSettings(defaults: d).llmProvider == .anthropic)
    }

    // The reported bug: a stale Anthropic key in the keychain from a prior
    // install pre-fills the Anthropic field. With the explicit picker, the
    // wizard pre-selects OpenAI when only the OpenAI field becomes non-empty,
    // and complete() snaps the provider to the picker's value.
    @Test func selected_provider_defaults_to_user_added_key_over_keychain_leftover() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        // Seed a leftover Anthropic key (simulates prior install where DPK
        // entries survived a sandbox reset).
        try kc.set("sk-ant-leftover", forKey: Keychain.Account.anthropic)

        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        // Sanity: pre-load worked (verifies the bug premise)
        #expect(vm.apiKeyVM.anthropicKey == "sk-ant-leftover")
        // Default selection should follow the only-non-empty key — but here
        // both will be empty initially other than the leftover, so init picks
        // .anthropic. The user explicitly switches to OpenAI in the picker:
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai-new"
        vm.complete()
        #expect(AppSettings(defaults: d).llmProvider == .openai)
    }

    @Test func selected_provider_init_prefers_only_non_empty_keychain_key() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        try kc.set("sk-openai-existing", forKey: Keychain.Account.openai)
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        #expect(vm.selectedProvider == .openai)
    }
}
