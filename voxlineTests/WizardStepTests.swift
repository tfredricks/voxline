// voxlineTests/WizardStepTests.swift
import Testing
@testable import voxline

@Suite struct WizardStepTests {

    @Test func first_step_is_welcome() {
        #expect(WizardStep.first == .welcome)
    }

    @Test func steps_advance_in_order() {
        #expect(WizardStep.welcome.next(in: WizardStep.allCases) == .permissions)
        #expect(WizardStep.permissions.next(in: WizardStep.allCases) == .apiKey)
        #expect(WizardStep.apiKey.next(in: WizardStep.allCases) == .modelDownload)
        #expect(WizardStep.modelDownload.next(in: WizardStep.allCases) == .done)
        #expect(WizardStep.done.next(in: WizardStep.allCases) == nil)
    }

    @Test func steps_go_back_in_order() {
        #expect(WizardStep.welcome.previous(in: WizardStep.allCases) == nil)
        #expect(WizardStep.permissions.previous(in: WizardStep.allCases) == .welcome)
        #expect(WizardStep.apiKey.previous(in: WizardStep.allCases) == .permissions)
        #expect(WizardStep.modelDownload.previous(in: WizardStep.allCases) == .apiKey)
        #expect(WizardStep.done.previous(in: WizardStep.allCases) == .modelDownload)
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
