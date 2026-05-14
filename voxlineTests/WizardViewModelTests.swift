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

        vm.advance(); vm.advance(); vm.advance(); vm.advance()
        vm.apiKeyVM.anthropicKey = "sk-ant-test"
        vm.selectedProvider = .anthropic
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

    // complete() writes `selectedProvider` verbatim — what the picker shows
    // is what gets saved. No inference, no fallback.

    @Test func complete_saves_selected_provider_openai() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai"
        vm.complete()
        #expect(AppSettings(defaults: d).llmProvider == .openai)
    }

    @Test func complete_saves_selected_provider_anthropic() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        var seed = AppSettings(defaults: d)
        seed.llmProvider = .openai
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .anthropic
        vm.apiKeyVM.anthropicKey = "sk-ant"
        vm.complete()
        #expect(AppSettings(defaults: d).llmProvider == .anthropic)
    }

    @Test func selected_provider_init_prefers_only_non_empty_keychain_key() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        try kc.set("sk-openai-existing", forKey: Keychain.Account.openai)
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        #expect(vm.selectedProvider == .openai)
    }

    // ── Continue gate ──────────────────────────────────────────────────────
    //
    // The picker's provider must have a non-empty key before the wizard
    // advances. This blocks the failure mode where complete() would save a
    // provider whose keychain slot is empty.

    @Test func cannot_advance_when_selected_provider_has_no_key() {
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.anthropicKey = "sk-ant"
        // Picker says openai but only anthropic is filled.
        #expect(vm.canAdvanceFromAPIKeyStep == false)
    }

    @Test func can_advance_when_selected_provider_has_key() {
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai"
        #expect(vm.canAdvanceFromAPIKeyStep == true)
    }

    @Test func whitespace_only_key_does_not_satisfy_gate() {
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: defaults()), keychain: kc)
        vm.selectedProvider = .anthropic
        vm.apiKeyVM.anthropicKey = "   \n"
        #expect(vm.canAdvanceFromAPIKeyStep == false)
    }

    // ── Partial completion ────────────────────────────────────────────────
    //
    // If the user closes the wizard before clicking "Get started", `advance()`
    // is still the only thing that ran. It must persist the picker's provider
    // choice — otherwise the saved keys are paired with the hardcoded default
    // provider on next launch, which is the failure mode we already shipped
    // once.

    @Test func advance_persists_selected_provider_to_user_defaults() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai"
        vm.advance()
        #expect(AppSettings(defaults: d).llmProvider == .openai)
        // But firstRun stays false until complete() runs.
        #expect(AppSettings(defaults: d).hasCompletedFirstRun == false)
    }

    // `AppSettings.llmProvider`'s setter clears any custom `Key.model`
    // override as a side effect. `commitProgress()` must skip the write when
    // the provider is unchanged, otherwise a returning user re-running the
    // wizard would silently lose their model override on the first advance.
    @Test func commit_progress_does_not_clear_model_when_provider_unchanged() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        var seed = AppSettings(defaults: d)
        seed.llmProvider = .openai
        seed.llmModel = "gpt-custom-tuned"
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        #expect(vm.selectedProvider == .openai)
        vm.apiKeyVM.openaiKey = "sk-openai"
        vm.advance()
        // Provider was unchanged, so the custom model override must survive.
        #expect(d.string(forKey: AppSettings.Key.model) == "gpt-custom-tuned")
    }

    @Test func advance_then_change_provider_then_advance_writes_latest_choice() throws {
        let d = defaults()
        let kc = Keychain(service: "com.voxline.test.\(UUID().uuidString)")
        defer { try? kc.deleteAll() }
        let vm = WizardViewModel(settings: AppSettings(defaults: d), keychain: kc)
        vm.selectedProvider = .openai
        vm.apiKeyVM.openaiKey = "sk-openai"
        vm.advance()
        // User backs up and changes their mind:
        vm.selectedProvider = .anthropic
        vm.apiKeyVM.anthropicKey = "sk-ant"
        vm.advance()
        #expect(AppSettings(defaults: d).llmProvider == .anthropic)
    }
}
