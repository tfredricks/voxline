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

/// A JSON schema the reply must match, sent through each provider's
/// structured-output field (`output_config.format` / `response_format`).
struct StructuredOutput: Equatable, Sendable {
    let name: String
    let schemaJSON: String

    func schemaObject() throws -> Any {
        try JSONSerialization.jsonObject(with: Data(schemaJSON.utf8))
    }

    static let commandEdit = StructuredOutput(name: "edit", schemaJSON: CommandResult.schemaJSON)
    static let meetingNotes = StructuredOutput(name: "meeting_notes", schemaJSON: MeetingNotes.schemaJSON)
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

    /// When set, the client asks the provider to constrain the reply to this
    /// schema, unless `StructuredOutputSupport` has seen the model reject it.
    var structuredOutput: StructuredOutput? = nil

    private static let reasoningModelPrefixes = ["o1", "o3", "o4", "gpt-5"]
    private static let anthropicDefaultThinkingPrefixes = [
        "claude-fable", "claude-mythos", "claude-opus-5", "claude-sonnet-5", "claude-haiku-5"
    ]

    /// Claude models that think when no `thinking` parameter is sent. Their
    /// thinking tokens count toward `max_tokens`, and they reject non-default
    /// sampling, so the Anthropic client treats them differently.
    static func anthropicThinksByDefault(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return anthropicDefaultThinkingPrefixes.contains { lowered.hasPrefix($0) }
    }

    /// Extra output tokens for models that draw hidden reasoning or thinking
    /// tokens from the same cap: 4,096 for OpenAI reasoning models and Claude
    /// models that think by default, 0 otherwise.
    static func thinkingHeadroom(for model: String) -> Int {
        let lowered = model.lowercased()
        let isOpenAIReasoning = reasoningModelPrefixes.contains { lowered.hasPrefix($0) }
        return isOpenAIReasoning || anthropicThinksByDefault(model) ? 4096 : 0
    }

    /// Output budget for transcript cleanup: 1.5x the transcript's estimated
    /// token count plus 256, clamped to 256...4096, plus `thinkingHeadroom`.
    static func cleanupBudget(transcript: String, model: String) -> Int {
        let estimatedTokens = Double(transcript.utf8.count) / 4
        let base = min(max(Int((estimatedTokens * 1.5).rounded(.up)) + 256, 256), 4096)
        return base + thinkingHeadroom(for: model)
    }

    /// Output budget for a command: 8,192 plus `thinkingHeadroom`. A rewrite
    /// returns the whole field window, so the budget does not scale with the
    /// instruction.
    static func commandBudget(model: String) -> Int {
        8192 + thinkingHeadroom(for: model)
    }

    /// Output budget for meeting notes: 8,192 plus `thinkingHeadroom`.
    static func meetingNotesBudget(model: String) -> Int {
        8192 + thinkingHeadroom(for: model)
    }
}

enum LLMError: Error, LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case rateLimited
    case quotaExceeded
    case network(Error)
    case badStatus(code: Int, body: String)
    case badResponseShape(reason: String)
    case truncated
    case refused

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Open Settings → AI Provider to set one."
        case .invalidAPIKey:
            return "API key was rejected by the provider."
        case .rateLimited:
            return "Rate limited by the provider; try again in a moment."
        case .quotaExceeded:
            return "The provider account is out of credit — check billing."
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
    func complete(_ request: LLMRequest) async throws -> String
}
