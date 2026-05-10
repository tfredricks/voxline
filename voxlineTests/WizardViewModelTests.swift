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
}
