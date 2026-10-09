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

        _ = try await client.cleanup(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "sys", userPrompt: "usr", temperature: nil))

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

        _ = try await client.cleanup(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "S", userPrompt: "U", temperature: 0.4))

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

        _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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

        _ = try await client.cleanup(LLMRequest(model: "claude-sonnet-5-5", systemPrompt: "s", userPrompt: "u", temperature: 0.3))

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

        _ = try await client.cleanup(LLMRequest(model: "claude-haiku-4-5", systemPrompt: "s", userPrompt: "u", temperature: 0.3))

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
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
        #expect(out == "hello world")
    }

    private func cleanupError(forBody json: String) async -> LLMError? {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data(json.utf8), status: 200)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
        let out = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
        _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil, maxOutputTokens: 406))
        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 406)
    }

    @Test func http_401_maps_to_invalidAPIKey() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (data: Data("nope".utf8), status: 401)
        let client = AnthropicClient(apiKey: "k", http: mock)
        do {
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
            _ = try await client.cleanup(LLMRequest(model: "m", systemPrompt: "s", userPrompt: "u", temperature: nil))
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
}

/// LLMError needs Equatable for these tests AND for tests in OpenAIClientTests
/// and LLMServiceTests later in this branch. Keep this conformance test-only.
extension LLMError: Equatable {
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
