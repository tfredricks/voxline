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

    @Test func anthropic_thinks_by_default_for_the_five_family_fable_and_mythos() {
        for model in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1", "claude-mythos-5-1", "CLAUDE-OPUS-5"] {
            #expect(LLMRequest.anthropicThinksByDefault(model), "\(model)")
        }
    }

    @Test func anthropic_does_not_think_by_default_for_older_models() {
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "claude-opus-4-8", "claude-3-5-haiku-latest"] {
            #expect(!LLMRequest.anthropicThinksByDefault(model), "\(model)")
        }
    }

    @Test func cleanup_budget_adds_headroom_for_anthropic_models_that_think_by_default() {
        #expect(LLMRequest.cleanupBudget(transcript: "", model: "claude-sonnet-5-5") == 256 + 4096)
        let long = String(repeating: "a", count: 20_000)
        #expect(LLMRequest.cleanupBudget(transcript: long, model: "claude-fable-5-1") == 8192)
        #expect(LLMRequest.cleanupBudget(transcript: "", model: "claude-haiku-4-5") == 256)
    }

    @Test func thinking_headroom_covers_openai_reasoning_and_anthropic_thinking_models() {
        for model in ["o1-mini", "o3-mini", "o4-mini", "gpt-5-mini", "GPT-5", "claude-sonnet-5-5", "claude-fable-5-1"] {
            #expect(LLMRequest.thinkingHeadroom(for: model) == 4096, "\(model)")
        }
        #expect(LLMRequest.thinkingHeadroom(for: "o3-mini") == 4096)
    }

    @Test func thinking_headroom_is_zero_for_other_models() {
        for model in ["claude-haiku-4-5", "claude-sonnet-4-5", "gpt-4.1-nano", "gpt-4o-mini"] {
            #expect(LLMRequest.thinkingHeadroom(for: model) == 0, "\(model)")
        }
    }

    @Test func command_budget_is_8192_plus_thinking_headroom() {
        #expect(LLMRequest.commandBudget(model: "claude-haiku-4-5") == 8192)
        #expect(LLMRequest.commandBudget(model: "claude-sonnet-5-5") == 12_288)
        #expect(LLMRequest.commandBudget(model: "gpt-5-mini") == 12_288)
        #expect(LLMRequest.commandBudget(model: "gpt-4.1-nano") == 8192)
    }

    @Test func llm_request_has_no_structured_output_by_default() {
        let req = LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil)
        #expect(req.structuredOutput == nil)
        #expect(req.maxOutputTokens == 1024)
    }

    @Test func command_edit_structured_output_is_named_edit_and_carries_the_command_schema() {
        #expect(StructuredOutput.commandEdit.name == "edit")
        #expect(StructuredOutput.commandEdit.schemaJSON == CommandResult.schemaJSON)
    }

    @Test func command_edit_schema_object_parses() throws {
        let schema = try #require(try StructuredOutput.commandEdit.schemaObject() as? [String: Any])
        #expect(schema["type"] as? String == "object")
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["action", "text"])
        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        #expect(action["enum"] as? [String] == ["replace_selection", "insert", "rewrite"])
    }

    @Test func malformed_schema_json_throws() {
        let broken = StructuredOutput(name: "x", schemaJSON: "{not json")
        #expect(throws: (any Error).self) { try broken.schemaObject() }
    }
}
