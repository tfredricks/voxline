import Testing
import Foundation
@testable import voxline

@Suite struct LLMTypesTests {

    @Test func provider_raw_values_are_stable() {
        #expect(LLMProvider.anthropic.rawValue == "anthropic")
        #expect(LLMProvider.openai.rawValue == "openai")
    }

    @Test func provider_default_models_match_spec() {
        #expect(LLMProvider.anthropic.defaultModel == "claude-haiku-4-5")
        #expect(LLMProvider.openai.defaultModel == "gpt-4.1-mini")
    }

    @Test func provider_display_names_are_friendly() {
        #expect(LLMProvider.anthropic.displayName == "Anthropic")
        #expect(LLMProvider.openai.displayName == "OpenAI")
    }

    @Test func llm_request_carries_system_user_and_model() {
        let req = LLMRequest(model: "m", systemPrompt: "sys", userPrompt: "usr", temperature: 0.5)
        #expect(req.model == "m")
        #expect(req.systemPrompt == "sys")
        #expect(req.userPrompt == "usr")
        #expect(req.temperature == 0.5)
    }

    @Test func llm_error_messages_are_descriptive() {
        let cases: [LLMError] = [
            .missingAPIKey,
            .invalidAPIKey,
            .rateLimited,
            .network(URLError(.timedOut)),
            .badStatus(code: 500, body: "server boom"),
            .badResponseShape(reason: "missing content")
        ]
        for e in cases {
            #expect(!e.localizedDescription.isEmpty)
        }
    }
}
