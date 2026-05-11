// voxlineTests/OpenAIClientTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct OpenAIClientTests {

    final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var stubResponse: (data: Data, status: Int) = (Data(), 200)
        var stubError: Error?

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            capturedRequest = request
            if let stubError { throw stubError }
            return (
                stubResponse.data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: stubResponse.status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
            )
        }
    }

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
}
