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

    @Test func full_sequence_includes_every_step() {
        #expect(WizardStep.sequence(skippingEngineStep: false) == WizardStep.allCases)
    }

    @Test func skipping_the_engine_step_removes_only_that_step() {
        #expect(WizardStep.sequence(skippingEngineStep: true) == [.welcome, .permissions, .apiKey, .done])
    }

    @Test func navigation_follows_the_given_sequence() {
        let steps = WizardStep.sequence(skippingEngineStep: true)
        #expect(WizardStep.apiKey.next(in: steps) == .done)
        #expect(WizardStep.done.previous(in: steps) == .apiKey)
        #expect(WizardStep.done.next(in: steps) == nil)
        #expect(WizardStep.welcome.previous(in: steps) == nil)
    }
}
