// voxlineTests/WizardStepTests.swift
import Testing
@testable import voxline

@Suite struct WizardStepTests {

    @Test func first_step_is_welcome() {
        #expect(WizardStep.first == .welcome)
    }

    @Test func steps_advance_in_order() {
        #expect(WizardStep.welcome.next == .permissions)
        #expect(WizardStep.permissions.next == .apiKey)
        #expect(WizardStep.apiKey.next == .modelDownload)
        #expect(WizardStep.modelDownload.next == .done)
        #expect(WizardStep.done.next == nil)
    }

    @Test func steps_go_back_in_order() {
        #expect(WizardStep.welcome.previous == nil)
        #expect(WizardStep.permissions.previous == .welcome)
        #expect(WizardStep.apiKey.previous == .permissions)
        #expect(WizardStep.modelDownload.previous == .apiKey)
        #expect(WizardStep.done.previous == .modelDownload)
    }
}
