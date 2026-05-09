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
}
