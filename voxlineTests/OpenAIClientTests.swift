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

        _ = try await client.cleanup(LLMRequest(model: "gpt-4o-mini", systemPrompt: "s", userPrompt: "u", temperature: nil))

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

        _ = try await client.cleanup(LLMRequest(model: "gpt-4o-mini", systemPrompt: "S", userPrompt: "U", temperature: 0.2))

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
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "only-this")
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(), status: 401)
        let client = OpenAIClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .invalidAPIKey)
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
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "done")
    }

    @Test func max_output_tokens_from_the_request_reach_the_body() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"x"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        let client = OpenAIClient(apiKey: "k", http: mock)
        _ = try await client.cleanup(LLMRequest(model: "gpt-5-mini", systemPrompt: "s", userPrompt: "u", temperature: nil, maxOutputTokens: 4353))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["max_completion_tokens"] as? Int == 4353)
    }
}
