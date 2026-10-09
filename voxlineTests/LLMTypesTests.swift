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
        #expect(LLMProvider.openai.defaultModel == "gpt-4.1-nano")
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
            .badResponseShape(reason: "missing content"),
            .truncated,
            .refused
        ]
        for e in cases {
            #expect(!e.localizedDescription.isEmpty)
        }
    }

    @Test func truncated_and_refused_have_exact_user_text() {
        #expect(LLMError.truncated.errorDescription == "The model ran out of output tokens before finishing.")
        #expect(LLMError.refused.errorDescription == "The model declined to process this text.")
    }

    @Test func cleanup_budget_for_empty_transcript_is_the_floor() {
        #expect(LLMRequest.cleanupBudget(transcript: "", model: "claude-haiku-4-5") == 256)
    }

    @Test func cleanup_budget_scales_with_utf8_length() {
        let transcript = String(repeating: "a", count: 400)
        #expect(LLMRequest.cleanupBudget(transcript: transcript, model: "claude-haiku-4-5") == 406)
    }

    @Test func cleanup_budget_counts_utf8_bytes_not_characters() {
        let transcript = String(repeating: "é", count: 200)
        #expect(transcript.utf8.count == 400)
        #expect(LLMRequest.cleanupBudget(transcript: transcript, model: "claude-haiku-4-5") == 406)
    }

    @Test func cleanup_budget_is_capped_at_4096() {
        let transcript = String(repeating: "a", count: 20_000)
        #expect(LLMRequest.cleanupBudget(transcript: transcript, model: "claude-haiku-4-5") == 4096)
    }

    @Test func cleanup_budget_adds_reasoning_headroom_after_the_clamp() {
        #expect(LLMRequest.cleanupBudget(transcript: "", model: "gpt-5-mini") == 4352)
        let long = String(repeating: "a", count: 20_000)
        #expect(LLMRequest.cleanupBudget(transcript: long, model: "gpt-5") == 8192)
    }

    @Test func cleanup_budget_reasoning_prefixes_are_o1_o3_o4_gpt5_case_insensitive() {
        for model in ["o1-mini", "o3", "o4-mini", "gpt-5-nano", "GPT-5-Mini", "O3-Mini"] {
            #expect(LLMRequest.cleanupBudget(transcript: "", model: model) == 4352, "\(model)")
        }
    }

    @Test func cleanup_budget_gives_non_reasoning_models_no_headroom() {
        for model in ["claude-haiku-4-5", "gpt-4.1-nano", "gpt-4o-mini", "gpt-4.1"] {
            #expect(LLMRequest.cleanupBudget(transcript: "", model: model) == 256, "\(model)")
        }
    }
}
