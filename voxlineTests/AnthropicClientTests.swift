import Testing
import Foundation
@testable import voxline

@Suite struct AnthropicClientTests {

    @Test func sends_post_to_messages_endpoint_with_api_key_header() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"hello"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "sk-test", http: mock)

        _ = try await client.complete(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "sys", userPrompt: "usr", temperature: nil))

        let req = try #require(mock.capturedRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func body_includes_system_user_and_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.complete(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "S", userPrompt: "U", temperature: 0.4))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["system"] as? String == "S")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect(body["temperature"] as? Double == 0.4)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "U")
    }

    @Test func omits_temperature_when_nil() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["temperature"] == nil)
    }

    @Test func thinking_by_default_models_get_low_effort_and_no_temperature_or_thinking() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.complete(LLMRequest(model: "claude-sonnet-5-5", systemPrompt: "s", userPrompt: "u", temperature: 0.3))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")
        #expect(body["temperature"] == nil)
        #expect(body["thinking"] == nil)
    }

    @Test func models_that_do_not_think_by_default_keep_temperature_and_get_no_output_config() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)

        _ = try await client.complete(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: 0.3))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["temperature"] as? Double == 0.3)
        #expect(body["output_config"] == nil)
        #expect(body["thinking"] == nil)
    }

    @Test func returns_concatenated_text_blocks() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"hello "},{"type":"text","text":"world"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)
        let out = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "hello world")
    }

    private func cleanupError(forBody json: String) async -> LLMError? {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(json.utf8), status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            return nil
        } catch let e as LLMError {
            return e
        } catch {
            return nil
        }
    }

    @Test func refusal_stop_reason_with_no_blocks_throws_refused() async {
        let e = await cleanupError(forBody: #"{"content":[],"stop_reason":"refusal"}"#)
        #expect(e == .refused)
    }

    @Test func max_tokens_stop_reason_with_text_throws_truncated() async {
        let e = await cleanupError(forBody: #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#)
        #expect(e == .truncated)
    }

    @Test func end_turn_stop_reason_returns_the_text() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)
        let out = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "done")
    }

    @Test func empty_content_with_end_turn_keeps_the_no_text_blocks_error() async {
        let e = await cleanupError(forBody: #"{"content":[],"stop_reason":"end_turn"}"#)
        #expect(e == .badResponseShape(reason: "no text blocks in response"))
    }

    @Test func missing_stop_reason_keeps_the_existing_behavior() async {
        let e = await cleanupError(forBody: #"{"content":[]}"#)
        #expect(e == .badResponseShape(reason: "no text blocks in response"))
    }

    @Test func max_output_tokens_from_the_request_reach_the_body() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"x"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = AnthropicClient(apiKey: "k", http: mock)
        _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil, maxOutputTokens: 406))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 406)
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data("nope".utf8), status: 401)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .invalidAPIKey)
        }
    }

    @Test func http_429_maps_to_rateLimited() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(), status: 429)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .rateLimited)
        }
    }

    @Test func http_5xx_maps_to_badStatus_with_body() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data("kaboom".utf8), status: 503)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            switch e {
            case .badStatus(let code, let body):
                #expect(code == 503)
                #expect(body == "kaboom")
            default:
                Issue.record("expected .badStatus, got \(e)")
            }
        }
    }

    // MARK: Structured output

    private static let okBody = Data(#"{"content":[{"type":"text","text":"{\"action\":\"insert\",\"text\":\"hi\"}"}]}"#.utf8)
    private static let formatRejection = Data(#"{"error":{"message":"output_config.format is not supported"}}"#.utf8)

    private func requestBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func expectCommandSchema(_ format: [String: Any]) throws {
        #expect(format["type"] as? String == "json_schema")
        let schema = try #require(format["schema"] as? NSDictionary)
        let expected = try #require(try StructuredOutput.commandEdit.schemaObject() as? NSDictionary)
        #expect(schema.isEqual(expected))
    }

    @Test func thinking_model_with_structured_output_merges_effort_and_format() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        _ = try await client.complete(LLMRequest(
            model: "claude-sonnet-5-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            maxOutputTokens: 12_288, structuredOutput: .commandEdit
        ))

        let body = try requestBody(mock.capturedRequest)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(Set(outputConfig.keys) == ["effort", "format"])
        #expect(outputConfig["effort"] as? String == "low")
        try expectCommandSchema(try #require(outputConfig["format"] as? [String: Any]))
        #expect(body["temperature"] == nil)
        #expect(body["thinking"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["tool_choice"] == nil)
        #expect(mock.capturedRequest?.value(forHTTPHeaderField: "anthropic-beta") == nil)
    }

    @Test func haiku_4_5_with_structured_output_sends_format_without_effort() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        _ = try await client.complete(LLMRequest(
            model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            structuredOutput: .commandEdit
        ))

        let body = try requestBody(mock.capturedRequest)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(Set(outputConfig.keys) == ["format"])
        try expectCommandSchema(try #require(outputConfig["format"] as? [String: Any]))
        #expect(body["temperature"] == nil)
    }

    @Test func haiku_4_5_with_structured_output_keeps_a_requested_temperature() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        _ = try await client.complete(LLMRequest(
            model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: 0.2,
            structuredOutput: .commandEdit
        ))

        let body = try requestBody(mock.capturedRequest)
        #expect(body["temperature"] as? Double == 0.2)
        #expect((body["output_config"] as? [String: Any])?["format"] != nil)
    }

    @Test func haiku_4_5_without_structured_output_sends_no_output_config_and_keeps_temperature() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        _ = try await client.complete(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: 0.3))

        let body = try requestBody(mock.capturedRequest)
        #expect(body["output_config"] == nil)
        #expect(body["temperature"] as? Double == 0.3)
    }

    @Test func structured_output_json_comes_back_from_the_text_block() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        let out = try await client.complete(LLMRequest(
            model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            structuredOutput: .commandEdit
        ))

        #expect(out == #"{"action":"insert","text":"hi"}"#)
    }

    @Test func format_rejection_retries_once_prompt_only_and_remembers_the_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        let out = try await client.complete(LLMRequest(
            model: "claude-sonnet-5-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            maxOutputTokens: 12_288, structuredOutput: .commandEdit
        ))

        #expect(out == #"{"action":"insert","text":"hi"}"#)
        #expect(mock.capturedRequests.count == 2)
        let first = try requestBody(mock.capturedRequests.first)
        #expect((first["output_config"] as? [String: Any])?["format"] != nil)
        let second = try requestBody(mock.capturedRequests.last)
        let secondConfig = try #require(second["output_config"] as? [String: Any])
        #expect(secondConfig["format"] == nil)
        #expect(secondConfig["effort"] as? String == "low")
        #expect(second["max_tokens"] as? Int == 12_288)
        #expect(second["system"] as? String == "s")
        #expect(support.rejects("claude-sonnet-5-5"))
    }

    @Test func format_rejection_on_haiku_retries_with_no_output_config() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        _ = try await client.complete(LLMRequest(
            model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            structuredOutput: .commandEdit
        ))

        #expect(mock.capturedRequests.count == 2)
        #expect(try requestBody(mock.capturedRequests.last)["output_config"] == nil)
        #expect(support.rejects("claude-haiku-4-5"))
    }

    @Test func a_second_failure_after_the_prompt_only_retry_is_thrown() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Data("still bad".utf8), 400)]
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        do {
            _ = try await client.complete(LLMRequest(
                model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
                structuredOutput: .commandEdit
            ))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: "still bad"))
        }
        #expect(mock.capturedRequests.count == 2)
    }

    @Test func unrelated_400_throws_after_one_request_and_does_not_mark_the_model() async throws {
        let mock = MockHTTPClient()
        let unrelated = #"{"error":{"message":"messages: at least one message is required"}}"#
        mock.stubResponses = [(Data(unrelated.utf8), 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        do {
            _ = try await client.complete(LLMRequest(
                model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
                structuredOutput: .commandEdit
            ))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: unrelated))
        }
        #expect(mock.capturedRequests.count == 1)
        #expect(!support.rejects("claude-haiku-4-5"))
    }

    @Test func format_rejection_without_structured_output_does_not_retry() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        do {
            _ = try await client.complete(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: String(decoding: Self.formatRejection, as: UTF8.self)))
        }
        #expect(mock.capturedRequests.count == 1)
        #expect(!support.rejects("claude-haiku-4-5"))
    }

    @Test func a_model_already_marked_sends_no_format_and_makes_one_request() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        support.markRejected("claude-sonnet-5-5")
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        do {
            _ = try await client.complete(LLMRequest(
                model: "claude-sonnet-5-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
                structuredOutput: .commandEdit
            ))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: String(decoding: Self.formatRejection, as: UTF8.self)))
        }
        #expect(mock.capturedRequests.count == 1)
        let outputConfig = try #require(try requestBody(mock.capturedRequest)["output_config"] as? [String: Any])
        #expect(Set(outputConfig.keys) == ["effort"])
    }

    @Test func a_model_already_marked_succeeds_prompt_only_in_one_request() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let support = StructuredOutputSupport()
        support.markRejected("claude-haiku-4-5")
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: support)

        _ = try await client.complete(LLMRequest(
            model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
            structuredOutput: .commandEdit
        ))

        #expect(mock.capturedRequests.count == 1)
        #expect(try requestBody(mock.capturedRequest)["output_config"] == nil)
    }

    @Test func refusal_with_structured_output_maps_to_refused_before_parsing() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(#"{"content":[{"type":"text","text":"I can't help with that."}],"stop_reason":"refusal"}"#.utf8), status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        do {
            _ = try await client.complete(LLMRequest(
                model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
                structuredOutput: .commandEdit
            ))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .refused)
        }
    }

    @Test func truncation_with_structured_output_maps_to_truncated() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(#"{"content":[{"type":"text","text":"{\"action\":\"ins"}],"stop_reason":"max_tokens"}"#.utf8), status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        do {
            _ = try await client.complete(LLMRequest(
                model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: nil,
                structuredOutput: .commandEdit
            ))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .truncated)
        }
        #expect(mock.capturedRequests.count == 1)
    }
}

/// Test-only: `.network` cases compare equal whatever the inner error, which
/// is enough for tests but not for app code.
extension LLMError: @retroactive Equatable {
    public static func == (lhs: LLMError, rhs: LLMError) -> Bool {
        switch (lhs, rhs) {
        case (.missingAPIKey, .missingAPIKey),
             (.invalidAPIKey, .invalidAPIKey),
             (.rateLimited, .rateLimited):
            return true
        case (.badStatus(let lc, let lb), .badStatus(let rc, let rb)):
            return lc == rc && lb == rb
        case (.badResponseShape(let lr), .badResponseShape(let rr)):
            return lr == rr
        case (.truncated, .truncated),
             (.refused, .refused):
            return true
        case (.network, .network):
            return true   // Sufficient for tests; we don't compare inner errors.
        default:
            return false
        }
    }
}
