import Foundation
import Observation

enum APIKeyTestResult: Equatable {
    case untested
    case success(LLMProvider)
    case failed(LLMProvider, String)
}

typealias LLMClientFactory = (LLMProvider, String) -> LLMClient

@Observable
@MainActor
final class APIKeysSettingsViewModel {

    var anthropicKey: String { didSet { onKeyChanged(.anthropic) } }
    var openaiKey: String    { didSet { onKeyChanged(.openai) } }

    var lastError: String?
    var testResult: APIKeyTestResult = .untested
    var testing: LLMProvider?

    private let keychain: any KeychainStorage
    private let clientFactory: LLMClientFactory
    private var anthropicPersisted: String = ""
    private var openaiPersisted: String = ""

    init(
        keychain: any KeychainStorage = DataProtectionKeychain(),
        clientFactory: @escaping LLMClientFactory = { provider, key in
            switch provider {
            case .anthropic: return AnthropicClient(apiKey: key)
            case .openai:    return OpenAIClient(apiKey: key)
            }
        }
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.anthropicKey = (try? keychain.string(forKey: KeychainAccount.anthropic)) ?? ""
        self.openaiKey    = (try? keychain.string(forKey: KeychainAccount.openai)) ?? ""
        self.anthropicPersisted = self.anthropicKey
        self.openaiPersisted    = self.openaiKey
    }

    /// Persist the Anthropic key. Whitespace is trimmed; an empty/whitespace
    /// value deletes the keychain entry.
    func commitAnthropic() {
        persist(value: anthropicKey, account: KeychainAccount.anthropic)
        anthropicPersisted = anthropicKey.trimmed
    }

    /// Persist the OpenAI key. Same rules as commitAnthropic.
    func commitOpenAI() {
        persist(value: openaiKey, account: KeychainAccount.openai)
        openaiPersisted = openaiKey.trimmed
    }

    /// Issue a tiny no-op LLM call to verify the current in-memory key for
    /// `provider`. Reads the live field value directly so an unsaved edit is
    /// tested immediately, without requiring a prior commit.
    func testConnection(_ provider: LLMProvider) async {
        testing = provider
        defer { testing = nil }
        let key = liveKey(for: provider).trimmed
        guard !key.isEmpty else {
            testResult = .failed(provider, "No API key set.")
            return
        }
        // temperature stays nil: gpt-5 reasoning models reject any non-default
        // temperature, and we want the Test path to exercise the same request
        // shape as real cleanup (shipped modes use temperature: nil).
        let request = LLMRequest(
            model: provider.defaultModel,
            systemPrompt: "Return the word 'ok' and nothing else.",
            userPrompt: "ping",
            temperature: nil
        )
        do {
            _ = try await clientFactory(provider, key).cleanup(request)
            testResult = .success(provider)
        } catch let err as LLMError {
            testResult = .failed(provider, err.errorDescription ?? "Failed")
        } catch {
            testResult = .failed(provider, error.localizedDescription)
        }
    }

    /// True when the field's current value (trimmed) matches the last committed
    /// value. Uses an in-memory cache — no keychain IO on every render.
    func isPersisted(_ provider: LLMProvider) -> Bool {
        let live = (provider == .anthropic ? anthropicKey : openaiKey).trimmed
        let saved = (provider == .anthropic) ? anthropicPersisted : openaiPersisted
        return saved == live
    }

    private func liveKey(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openai:    return openaiKey
        }
    }

    private func onKeyChanged(_ provider: LLMProvider) {
        if case .success(let p) = testResult, p == provider { testResult = .untested }
        if case .failed(let p, _) = testResult, p == provider { testResult = .untested }
        lastError = nil
    }

    private func persist(value: String, account: String) {
        let v = value.trimmed
        do {
            if v.isEmpty {
                try keychain.delete(forKey: account)
            } else {
                try keychain.set(v, forKey: account)
            }
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

}
