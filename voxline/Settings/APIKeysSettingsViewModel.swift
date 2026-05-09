import Foundation
import Observation

enum APIKeyTestResult: Equatable { case untested, success, failed(String) }

@Observable
@MainActor
final class APIKeysSettingsViewModel {

    var provider: LLMProvider
    var anthropicKey: String
    var openaiKey: String
    /// Surfaced to the view to render save errors inline.
    var lastError: String?
    var testResult: APIKeyTestResult = .untested
    var testing: Bool = false

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

    /// Issue a tiny no-op LLM call to verify the saved key.
    /// Persists the key first via save(), then dispatches the call.
    func testConnection() async {
        testing = true
        defer { testing = false }
        do {
            try save()  // persist first so the keychain has the active value
            let account = provider == .anthropic ? Keychain.Account.anthropic : Keychain.Account.openai
            let key = (try? keychain.string(forKey: account)) ?? ""
            guard !key.isEmpty else {
                testResult = .failed("No API key set.")
                return
            }
            let client: LLMClient = provider == .anthropic
                ? AnthropicClient(apiKey: key)
                : OpenAIClient(apiKey: key)
            let request = LLMRequest(
                model: provider.defaultModel,
                systemPrompt: "Return the word 'ok' and nothing else.",
                userPrompt: "ping",
                temperature: 0
            )
            _ = try await client.cleanup(request)
            testResult = .success
        } catch let err as LLMError {
            testResult = .failed(err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(error.localizedDescription)
        }
    }

    private func persist(value: String, account: String) throws {
        if value.isEmpty {
            try keychain.delete(forKey: account)
        } else {
            try keychain.set(value, forKey: account)
        }
    }
}
