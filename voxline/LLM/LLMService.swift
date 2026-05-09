import Foundation

/// Single entry point for transcript → LLM-cleaned-text. Picks the right
/// client based on AppSettings, fetches the corresponding key from Keychain,
/// applies per-mode overrides, and runs the cleanup request.
struct LLMService {

    let settings: AppSettings
    let keychain: Keychain
    let http: HTTPClient

    init(settings: AppSettings, keychain: Keychain = Keychain(), http: HTTPClient = URLSessionHTTPClient()) {
        self.settings = settings
        self.keychain = keychain
        self.http = http
    }

    func cleanup(transcript: String, mode: Mode) async throws -> String {
        // No transcript → no work. Empty input would otherwise generate a
        // surprise greeting from some models.
        guard !transcript.isEmpty else { return "" }

        let provider = settings.llmProvider
        let account: String
        switch provider {
        case .anthropic: account = Keychain.Account.anthropic
        case .openai:    account = Keychain.Account.openai
        }
        guard
            let key = try keychain.string(forKey: account),
            !key.isEmpty
        else {
            throw LLMError.missingAPIKey
        }

        let model = mode.model ?? settings.llmModel
        let request = LLMRequest(
            model: model,
            systemPrompt: mode.prompt,
            userPrompt: transcript,
            temperature: mode.temperature
        )

        let client: any LLMClient
        switch provider {
        case .anthropic: client = AnthropicClient(apiKey: key, http: http)
        case .openai:    client = OpenAIClient(apiKey: key, http: http)
        }
        return try await client.cleanup(request)
    }
}
