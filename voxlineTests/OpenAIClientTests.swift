// voxlineTests/OpenAIClientTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct OpenAIClientTests {

    @Test func sends_post_to_chat_completions_with_bearer_token() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "sk-openai", http: mock)

        _ = try await client.complete(LLMRequest(model: "gpt-4o-mini", systemPrompt: "s", userPrompt: "u", temperature: nil))

        let req = try #require(mock.capturedRequest)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-openai")
        #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")
    }

    @Test func body_includes_system_and_user_messages() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"x"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)

        _ = try await client.complete(LLMRequest(model: "gpt-4o-mini", systemPrompt: "S", userPrompt: "U", temperature: 0.2))

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["max_completion_tokens"] as? Int == 1024)
        #expect(body["max_tokens"] == nil)
        #expect(body["temperature"] as? Double == 0.2)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "S")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "U")
    }

    @Test func returns_first_choice_message_content() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"only-this"}},{"message":{"role":"assistant","content":"ignored"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        let out = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "only-this")
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(), status: 401)
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .invalidAPIKey)
        }
    }

    @Test func http_429_out_of_quota_maps_to_quotaExceeded() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: Data(#"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","param":null,"code":"insufficient_quota"}}"#.utf8),
            status: 429
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .quotaExceeded)
            #expect(e.errorDescription?.contains("billing") == true)
        }
    }

    @Test func http_429_rate_limit_maps_to_rateLimited() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: Data(#"{"error":{"message":"Rate limit reached for requests","type":"requests","param":null,"code":"rate_limit_exceeded"}}"#.utf8),
            status: 429
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .rateLimited)
        }
    }

    @Test func empty_choices_throws_badResponseShape() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            switch e {
            case .badResponseShape: break
            default: Issue.record("expected .badResponseShape, got \(e)")
            }
        }
    }

    private func cleanupError(forBody json: String) async -> LLMError? {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(json.utf8), status: 200)
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            return nil
        } catch let e as LLMError {
            return e
        } catch {
            return nil
        }
    }

    @Test func length_finish_reason_with_empty_content_throws_truncated() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":""},"finish_reason":"length"}]}"#)
        #expect(e == .truncated)
    }

    @Test func length_finish_reason_with_null_content_throws_truncated() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"length"}]}"#)
        #expect(e == .truncated)
    }

    @Test func length_finish_reason_with_partial_content_throws_truncated() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]}"#)
        #expect(e == .truncated)
    }

    @Test func content_filter_finish_reason_throws_refused() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"content_filter"}]}"#)
        #expect(e == .refused)
    }

    @Test func refusal_message_with_null_content_throws_refused() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#)
        #expect(e == .refused)
    }

    @Test func null_refusal_does_not_mask_the_content() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"content":"fine","refusal":null},"finish_reason":"stop"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        let out = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "fine")
    }

    @Test func null_content_with_stop_throws_badResponseShape() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":null},"finish_reason":"stop"}]}"#)
        #expect(e == .badResponseShape(reason: "empty message content"))
    }

    @Test func whitespace_only_content_throws_badResponseShape() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant","content":" \n "},"finish_reason":"stop"}]}"#)
        #expect(e == .badResponseShape(reason: "empty message content"))
    }

    @Test func missing_content_key_throws_badResponseShape() async {
        let e = await cleanupError(forBody: #"{"choices":[{"message":{"role":"assistant"},"finish_reason":"stop"}]}"#)
        #expect(e == .badResponseShape(reason: "empty message content"))
    }

    @Test func stop_finish_reason_returns_the_content() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        let out = try await client.complete(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "done")
    }

    @Test func max_output_tokens_from_the_request_reach_the_body() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"x"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        _ = try await client.complete(LLMRequest(model: "gpt-5-mini", systemPrompt: "s", userPrompt: "u", temperature: nil, maxOutputTokens: 4353))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["max_completion_tokens"] as? Int == 4353)
    }

    // MARK: Structured output

    private static let okBody = Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"action\":\"insert\",\"text\":\"hi\"}"},"finish_reason":"stop"}]}"#.utf8)
    private static let formatRejection = Data(#"{"error":{"message":"Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model.","type":"invalid_request_error","param":"response_format"}}"#.utf8)

    private func requestBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try #require(request?.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func structuredRequest(model: String = "gpt-4.1-nano") -> LLMRequest {
        LLMRequest(model: model, systemPrompt: "s", userPrompt: "u", temperature: nil, maxOutputTokens: 8192, structuredOutput: .commandEdit)
    }

    @Test func structured_output_sends_strict_json_schema_response_format() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        let out = try await client.complete(structuredRequest())

        #expect(out == #"{"action":"insert","text":"hi"}"#)
        let body = try requestBody(mock.capturedRequest)
        let responseFormat = try #require(body["response_format"] as? [String: Any])
        #expect(responseFormat["type"] as? String == "json_schema")
        let jsonSchema = try #require(responseFormat["json_schema"] as? [String: Any])
        #expect(jsonSchema["name"] as? String == "edit")
        #expect(jsonSchema["strict"] as? Bool == true)
        let schema = try #require(jsonSchema["schema"] as? NSDictionary)
        let expected = try #require(try StructuredOutput.commandEdit.schemaObject() as? NSDictionary)
        #expect(schema.isEqual(expected))
        #expect(body["temperature"] == nil)
        #expect(body["max_completion_tokens"] as? Int == 8192)
    }

    @Test func no_structured_output_sends_no_response_format() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Self.okBody, status: 200)
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        _ = try await client.complete(LLMRequest(model: "gpt-4.1-nano", systemPrompt: "s", userPrompt: "u", temperature: 0.2))

        let body = try requestBody(mock.capturedRequest)
        #expect(body["response_format"] == nil)
        #expect(body["temperature"] as? Double == 0.2)
    }

    @Test func response_format_rejection_retries_once_without_it_and_remembers_the_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: support)

        let out = try await client.complete(structuredRequest(model: "gpt-3.5-turbo"))

        #expect(out == #"{"action":"insert","text":"hi"}"#)
        #expect(mock.capturedRequests.count == 2)
        #expect(try requestBody(mock.capturedRequests.first)["response_format"] != nil)
        let second = try requestBody(mock.capturedRequests.last)
        #expect(second["response_format"] == nil)
        #expect(second["max_completion_tokens"] as? Int == 8192)
        #expect(support.rejects("gpt-3.5-turbo"))
    }

    @Test func unrelated_400_throws_after_one_request_and_does_not_mark_the_model() async throws {
        let mock = MockHTTPClient()
        let unrelated = #"{"error":{"message":"The model `gpt-9` does not exist","code":"model_not_found"}}"#
        mock.stubResponses = [(Data(unrelated.utf8), 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: support)

        do {
            _ = try await client.complete(structuredRequest(model: "gpt-9"))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: unrelated))
        }
        #expect(mock.capturedRequests.count == 1)
        #expect(!support.rejects("gpt-9"))
    }

    @Test func a_model_already_marked_sends_no_response_format_and_makes_one_request() async throws {
        let mock = MockHTTPClient()
        mock.stubResponses = [(Self.formatRejection, 400), (Self.okBody, 200)]
        let support = StructuredOutputSupport()
        support.markRejected("gpt-3.5-turbo")
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: support)

        do {
            _ = try await client.complete(structuredRequest(model: "gpt-3.5-turbo"))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .badStatus(code: 400, body: String(decoding: Self.formatRejection, as: UTF8.self)))
        }
        #expect(mock.capturedRequests.count == 1)
        #expect(try requestBody(mock.capturedRequest)["response_format"] == nil)
    }

    @Test func refusal_with_structured_output_maps_to_refused() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(#"{"choices":[{"message":{"content":null,"refusal":"I can't help with that."},"finish_reason":"stop"}]}"#.utf8), status: 200)
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        do {
            _ = try await client.complete(structuredRequest())
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .refused)
        }
    }

    @Test func truncation_with_structured_output_maps_to_truncated() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(#"{"choices":[{"message":{"content":"{\"action\":\"ins"},"finish_reason":"length"}]}"#.utf8), status: 200)
        let client = OpenAIClient(apiKey: "k", http: mock, structuredOutput: StructuredOutputSupport())

        do {
            _ = try await client.complete(structuredRequest())
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .truncated)
        }
        #expect(mock.capturedRequests.count == 1)
    }
}
