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
    /// Called after a commit changes the saved OpenAI key, or removes it.
    private let onOpenAIKeyChange: () -> Void
    private var anthropicPersisted: String = ""
    private var openaiPersisted: String = ""
    private var anthropicReadFailed = false
    private var openaiReadFailed = false

    init(
        keychain: any KeychainStorage = DataProtectionKeychain(),
        clientFactory: @escaping LLMClientFactory = { provider, key in
            switch provider {
            case .anthropic: return AnthropicClient(apiKey: key)
            case .openai:    return OpenAIClient(apiKey: key)
            }
        },
        onOpenAIKeyChange: @escaping () -> Void = {}
    ) {
        self.keychain = keychain
        self.clientFactory = clientFactory
        self.onOpenAIKeyChange = onOpenAIKeyChange
        let anthropic = Self.load(KeychainAccount.anthropic, from: keychain)
        let openai = Self.load(KeychainAccount.openai, from: keychain)
        self.anthropicKey = anthropic.value
        self.openaiKey = openai.value
        self.anthropicPersisted = anthropic.value
        self.openaiPersisted = openai.value
        self.anthropicReadFailed = anthropic.failed
        self.openaiReadFailed = openai.failed
        if anthropic.failed || openai.failed {
            self.lastError = "Couldn't read the saved API keys from the keychain. They were left untouched — relaunch and try again."
        }
    }

    private static func load(_ account: String, from keychain: any KeychainStorage) -> (value: String, failed: Bool) {
        do {
            return (try keychain.string(forKey: account) ?? "", false)
        } catch {
            AppLog.llm.error("keychain read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ("", true)
        }
    }

    /// Persist the Anthropic key. Whitespace is trimmed; an empty/whitespace
    /// value deletes the keychain entry. A field with no edit since the last
    /// load or commit writes nothing, so a stale view model never overwrites
    /// or deletes a key saved elsewhere (the wizard, another window build).
    func commitAnthropic() {
        let value = anthropicKey.trimmed
        guard value != anthropicPersisted,
              persist(value: value, account: KeychainAccount.anthropic) else { return }
        anthropicPersisted = value
    }

    /// Persist the OpenAI key. Same rules as commitAnthropic.
    func commitOpenAI() {
        let value = openaiKey.trimmed
        guard value != openaiPersisted,
              persist(value: value, account: KeychainAccount.openai) else { return }
        openaiPersisted = value
        onOpenAIKeyChange()
    }

    /// Re-reads each saved key whose field has no unsaved edit, so keys saved
    /// or removed elsewhere show up here. A failed read leaves the slot as is.
    func reloadSavedKeys() {
        if isPersisted(.anthropic) {
            reload(KeychainAccount.anthropic, persisted: &anthropicPersisted, readFailed: &anthropicReadFailed) {
                anthropicKey = $0
            }
        }
        if isPersisted(.openai) {
            reload(KeychainAccount.openai, persisted: &openaiPersisted, readFailed: &openaiReadFailed) {
                openaiKey = $0
            }
        }
    }

    private func reload(
        _ account: String,
        persisted: inout String,
        readFailed: inout Bool,
        assign: (String) -> Void
    ) {
        let loaded = Self.load(account, from: keychain)
        guard !loaded.failed else { return }
        readFailed = false
        guard loaded.value != persisted else { return }
        persisted = loaded.value
        assign(loaded.value)
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
            _ = try await clientFactory(provider, key).complete(request)
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
        persistedKey(for: provider) == liveKey(for: provider).trimmed
    }

    /// True when a non-empty key for `provider` was loaded or last committed.
    /// Unsaved edits don't count.
    func hasSavedKey(_ provider: LLMProvider) -> Bool {
        !persistedKey(for: provider).isEmpty
    }

    private func liveKey(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return anthropicKey
        case .openai:    return openaiKey
        }
    }

    private func persistedKey(for provider: LLMProvider) -> String {
        switch provider {
        case .anthropic: return anthropicPersisted
        case .openai:    return openaiPersisted
        }
    }

    private func onKeyChanged(_ provider: LLMProvider) {
        if case .success(let p) = testResult, p == provider { testResult = .untested }
        if case .failed(let p, _) = testResult, p == provider { testResult = .untested }
        lastError = nil
    }

    /// An empty value deletes the entry — unless the entry could not be read
    /// at load time, in which case deleting would destroy a key the user
    /// never saw. A successful non-empty save clears that guard.
    /// Returns false when nothing was written, so the caller keeps its last
    /// persisted value and the row keeps offering Save.
    private func persist(value v: String, account: String) -> Bool {
        if v.isEmpty && readFailed(for: account) { return false }
        do {
            if v.isEmpty {
                try keychain.delete(forKey: account)
            } else {
                try keychain.set(v, forKey: account)
            }
            setReadFailed(false, for: account)
            return true
        } catch {
            lastError = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    private func readFailed(for account: String) -> Bool {
        account == KeychainAccount.anthropic ? anthropicReadFailed : openaiReadFailed
    }

    private func setReadFailed(_ failed: Bool, for account: String) {
        if account == KeychainAccount.anthropic {
            anthropicReadFailed = failed
        } else {
            openaiReadFailed = failed
        }
    }

}
