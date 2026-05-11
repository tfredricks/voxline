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
        // After a reset wipes the sandbox container, `llmProvider` defaults to
        // .anthropic. If the user only filled in the OpenAI key (or vice
        // versa), the menu bar would otherwise error with "No API key
        // configured" because LLMService looks up the wrong provider's key.
        // Snap the provider to match whichever single key was supplied.
        let hasAnthropic = !apiKeyVM.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOpenAI    = !apiKeyVM.openaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var s = settings
        if hasAnthropic && !hasOpenAI {
            s.llmProvider = .anthropic
        } else if hasOpenAI && !hasAnthropic {
            s.llmProvider = .openai
        }
        s.hasCompletedFirstRun = true
        settings = s
        onComplete?()
    }
}
