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

    private let keychain: Keychain
    private let clientFactory: LLMClientFactory

    init(
        keychain: Keychain = Keychain(),
        clientFactory: @escaping LLMClientFactory = { provider, key in
            switch provider {
            case .anthropic: return AnthropicClient(apiKey: key)
            case .openai:    return OpenAIClient(apiKey: key)
            }
        }
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.anthropicKey = (try? keychain.string(forKey: Keychain.Account.anthropic)) ?? ""
        self.openaiKey    = (try? keychain.string(forKey: Keychain.Account.openai)) ?? ""
    }

    /// Persist the Anthropic key. Whitespace is trimmed; an empty/whitespace
    /// value deletes the keychain entry.
    func commitAnthropic() {
        persist(value: anthropicKey, account: Keychain.Account.anthropic)
    }

    /// Persist the OpenAI key. Same rules as commitAnthropic.
    func commitOpenAI() {
        persist(value: openaiKey, account: Keychain.Account.openai)
    }

    /// Issue a tiny no-op LLM call to verify the saved key for `provider`.
    /// Does NOT persist; commitX is the caller's responsibility (typically
    /// already done via save-on-blur before the user clicks Test).
    func testConnection(_ provider: LLMProvider) async {
        testing = provider
        defer { testing = nil }
        let key = (try? keychain.string(forKey: account(for: provider))) ?? ""
        guard !key.isEmpty else {
            testResult = .failed(provider, "No API key set.")
            return
        }
        let request = LLMRequest(
            model: provider.defaultModel,
            systemPrompt: "Return the word 'ok' and nothing else.",
            userPrompt: "ping",
            temperature: 0
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

    /// True when the field's current value (trimmed) matches what's
    /// persisted in keychain. Used to drive the "Saved"/"Unsaved" pill.
    func isPersisted(_ provider: LLMProvider) -> Bool {
        let saved = (try? keychain.string(forKey: account(for: provider))) ?? ""
        let live = trimmed(provider == .anthropic ? anthropicKey : openaiKey)
        return saved == live
    }

    private func onKeyChanged(_ provider: LLMProvider) {
        if case .success(let p) = testResult, p == provider { testResult = .untested }
        if case .failed(let p, _) = testResult, p == provider { testResult = .untested }
        lastError = nil
    }

    private func persist(value: String, account: String) {
        let v = trimmed(value)
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

    private func account(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return Keychain.Account.anthropic
        case .openai:    return Keychain.Account.openai
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
