import Foundation

enum LLMProvider: String, CaseIterable, Codable {
    case anthropic
    case openai

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openai:    return "OpenAI"
        }
    }

    /// Spec §4.3 defaults.
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-haiku-4-5"
        case .openai:    return "gpt-4o-mini"
        }
    }
}

/// Provider-agnostic request shape. The LLMService translates this into the
/// provider-specific JSON inside each client.
struct LLMRequest: Equatable {
    let model: String
    let systemPrompt: String
    let userPrompt: String
    /// Optional sampling temperature. nil means "use provider default".
    let temperature: Double?

    /// Default max output tokens for cleanup-style use. Cleaned text is
    /// almost never longer than the input transcript by much; 1024 is a
    /// generous ceiling without paying for cap-stretching latency.
    let maxOutputTokens: Int = 1024
}

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case network(Error)
    case badStatus(code: Int, body: String)
    case badResponseShape(reason: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Open Settings → API Keys to set one."
        case .invalidAPIKey:
            return "API key was rejected by the provider."
        case .rateLimited:
            return "Rate limited by the provider; try again in a moment."
        case .network(let err):
            return "Network error: \(err.localizedDescription)"
        case .badStatus(let code, let body):
            return "Provider returned HTTP \(code): \(body)"
        case .badResponseShape(let reason):
            return "Could not parse provider response: \(reason)"
        }
    }
}

/// Internal contract every LLM client conforms to. Visible to LLMService.
protocol LLMClient: Sendable {
    func cleanup(_ request: LLMRequest) async throws -> String
}
