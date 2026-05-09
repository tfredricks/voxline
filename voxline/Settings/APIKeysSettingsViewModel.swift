import Foundation
import Observation

@Observable
@MainActor
final class APIKeysSettingsViewModel {

    var provider: LLMProvider
    var anthropicKey: String
    var openaiKey: String
    /// Surfaced to the view to render save errors inline.
    var lastError: String?

    private var settings: AppSettings
    private let keychain: Keychain

    init(settings: AppSettings = AppSettings(), keychain: Keychain = Keychain()) {
        self.settings = settings
        self.keychain = keychain
        self.provider = settings.llmProvider
        self.anthropicKey = (try? keychain.string(forKey: Keychain.Account.anthropic)) ?? ""
        self.openaiKey = (try? keychain.string(forKey: Keychain.Account.openai)) ?? ""
    }

    func save() throws {
        var snap = settings
        snap.llmProvider = provider
        try persist(value: anthropicKey, account: Keychain.Account.anthropic)
        try persist(value: openaiKey, account: Keychain.Account.openai)
        settings = snap
    }

    private func persist(value: String, account: String) throws {
        if value.isEmpty {
            try keychain.delete(forKey: account)
        } else {
            try keychain.set(value, forKey: account)
        }
    }
}
