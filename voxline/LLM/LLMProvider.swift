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
        case .openai:    return "gpt-4.1-nano"
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

    /// Default max output tokens for callers that don't size the budget from
    /// their input.
    var maxOutputTokens: Int = 1024

    private static let reasoningModelPrefixes = ["o1", "o3", "o4", "gpt-5"]

    /// Output budget for transcript cleanup: 1.5x the transcript's estimated
    /// token count plus 256, clamped to 256...4096. Reasoning models draw
    /// hidden thinking tokens from the same cap, so they get 4,096 more.
    static func cleanupBudget(transcript: String, model: String) -> Int {
        let estimatedTokens = Double(transcript.utf8.count) / 4
        let base = min(max(Int((estimatedTokens * 1.5).rounded(.up)) + 256, 256), 4096)
        let lowered = model.lowercased()
        let reasoningHeadroom = reasoningModelPrefixes.contains { lowered.hasPrefix($0) } ? 4096 : 0
        return base + reasoningHeadroom
    }
}

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case network(Error)
    case badStatus(code: Int, body: String)
    case badResponseShape(reason: String)
    case truncated
    case refused

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
        case .badStatus(let code, _):
            // Body intentionally omitted from user-visible text: provider
            // 401/403 responses can echo the offending API key prefix.
            return "Provider returned HTTP \(code)."
        case .badResponseShape(let reason):
            return "Could not parse provider response: \(reason)"
        case .truncated:
            return "The model ran out of output tokens before finishing."
        case .refused:
            return "The model declined to process this text."
        }
    }
}

/// Internal contract every LLM client conforms to. Visible to LLMService.
protocol LLMClient: Sendable {
    func cleanup(_ request: LLMRequest) async throws -> String
}
