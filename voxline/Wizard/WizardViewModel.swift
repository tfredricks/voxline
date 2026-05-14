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

    /// Single source of truth for the provider the wizard will save. Driven by
    /// the segmented picker in the API-key step; the visible key field is
    /// bound to *this provider's* key slot. `complete()` writes this verbatim
    /// to `AppSettings.llmProvider` — no inference, no fallback heuristics.
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
        // falling back to the current settings choice. A returning user who
        // only has an OpenAI key sees OpenAI selected by default.
        let hasAnt = !Self.trimmedIsEmpty(vm.anthropicKey)
        let hasOA  = !Self.trimmedIsEmpty(vm.openaiKey)
        if hasOA && !hasAnt {
            self.selectedProvider = .openai
        } else if hasAnt && !hasOA {
            self.selectedProvider = .anthropic
        } else {
            self.selectedProvider = settings.llmProvider
        }
    }

    /// Continue gate for the API-key step: the picker's provider must have a
    /// non-empty key. With only one field shown — bound to the picker's slot —
    /// this means "the user has typed something into the field that's
    /// currently visible." Prevents advancing in a state where the saved
    /// provider has no key.
    var canAdvanceFromAPIKeyStep: Bool {
        switch selectedProvider {
        case .anthropic: return !Self.trimmedIsEmpty(apiKeyVM.anthropicKey)
        case .openai:    return !Self.trimmedIsEmpty(apiKeyVM.openaiKey)
        }
    }

    var canAdvance: Bool { currentStep.next != nil }
    var canGoBack: Bool { currentStep.previous != nil }

    /// Persist all in-progress wizard state — keys to keychain, picker choice
    /// to UserDefaults. Called on every advance and on completion so the
    /// user's choices survive a partial wizard run. Previously the provider
    /// was only written by `complete()`, so closing the wizard before the
    /// final "Get started" click left keys saved but provider unset →
    /// runtime fell back to the hardcoded default and the configured
    /// provider's key was the wrong one.
    func commitProgress() {
        apiKeyVM.commitAnthropic()
        apiKeyVM.commitOpenAI()
        // Guarded: AppSettings.llmProvider's setter clears any custom
        // `Key.model` override as a side effect, since a model id from one
        // provider is almost never valid for another. Writing the same
        // provider back would unnecessarily wipe that override (relevant
        // for a returning user re-running the wizard with a model id set).
        if settings.llmProvider != selectedProvider {
            var s = settings
            s.llmProvider = selectedProvider
            settings = s
        }
    }

    func advance() {
        commitProgress()
        if let next = currentStep.next { currentStep = next }
    }

    func goBack() {
        if let prev = currentStep.previous { currentStep = prev }
    }

    func complete() {
        commitProgress() // already persists keys + provider
        var s = settings
        s.hasCompletedFirstRun = true
        settings = s
        onComplete?()
    }

    private static func trimmedIsEmpty(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
