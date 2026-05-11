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

    /// User's explicit provider choice from the API-key step. `complete()`
    /// snaps `AppSettings.llmProvider` to this value so there's no guessing
    /// based on which fields happen to be populated (leftover keychain
    /// entries from a prior install used to confuse the heuristic).
    var selectedProvider: LLMProvider

    private var settings: AppSettings

    init(
        settings: AppSettings = AppSettings(),
        keychain: Keychain = Keychain()
    ) {
        self.settings = settings
        let vm = APIKeysSettingsViewModel(keychain: keychain)
        self.apiKeyVM = vm
        // Pre-select the picker based on what's already in the keychain,
        // falling back to the current settings choice. This way a returning
        // user who only has an OpenAI key sees OpenAI selected by default.
        let ws = CharacterSet.whitespacesAndNewlines
        let hasAnthropic = !vm.anthropicKey.trimmingCharacters(in: ws).isEmpty
        let hasOpenAI    = !vm.openaiKey.trimmingCharacters(in: ws).isEmpty
        if hasOpenAI && !hasAnthropic {
            self.selectedProvider = .openai
        } else if hasAnthropic && !hasOpenAI {
            self.selectedProvider = .anthropic
        } else {
            self.selectedProvider = settings.llmProvider
        }
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
        s.llmProvider = selectedProvider
        s.hasCompletedFirstRun = true
        settings = s
        onComplete?()
    }
}
