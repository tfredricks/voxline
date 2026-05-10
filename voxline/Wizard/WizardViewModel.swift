// voxline/Wizard/WizardViewModel.swift
import Foundation
import Observation

@Observable
@MainActor
final class WizardViewModel {

    var currentStep: WizardStep = .first
    var onComplete: (() -> Void)?

    /// The API-key step reuses APIKeysSettingsViewModel directly.
    let apiKeyVM: APIKeysSettingsViewModel

    private var settings: AppSettings

    init(
        settings: AppSettings = AppSettings(),
        keychain: Keychain = Keychain()
    ) {
        self.settings = settings
        self.apiKeyVM = APIKeysSettingsViewModel(keychain: keychain)
    }

    var canAdvance: Bool { currentStep.next != nil }
    var canGoBack: Bool { currentStep.previous != nil }

    /// Persist whatever's typed in the API-key step. Called on every advance
    /// and on completion so the user can navigate forward/back without losing
    /// keys, and the wizard exits with keys actually written to keychain.
    func commitKeys() {
        apiKeyVM.commitAnthropic()
        apiKeyVM.commitOpenAI()
    }

    func advance() {
        commitKeys()
        if let next = currentStep.next { currentStep = next }
    }

    func goBack() {
        if let prev = currentStep.previous { currentStep = prev }
    }

    func complete() {
        commitKeys()
        var s = settings
        s.hasCompletedFirstRun = true
        settings = s
        onComplete?()
    }
}
