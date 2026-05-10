// voxlineTests/LLMServiceTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct LLMServiceTests {

    final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        var capturedRequest: URLRequest?
        var stubResponse: (data: Data, status: Int) = (Data(), 200)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            capturedRequest = request
            return (
                stubResponse.data,
                HTTPURLResponse(url: request.url!, statusCode: stubResponse.status, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
    }

    private func defaultsSuite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func keychain() -> Keychain {
        Keychain(service: "com.voxline.voxline.test.\(UUID().uuidString)")
    }

    @Test func cleanup_with_no_key_throws_missingAPIKey() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let service = LLMService(settings: settings, keychain: keychain(), http: mock)

        let mode = Mode(bundleID: "*", displayName: "default", prompt: "S", model: nil, temperature: nil)
        do {
            _ = try await service.cleanup(transcript: "hi", mode: mode)
            Issue.record("expected throw")
        } catch let e as LLMError {
            #expect(e == .missingAPIKey)
        }
    }

    @Test func cleanup_routes_to_anthropic_when_provider_is_anthropic() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"clean"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = keychain()
        try kc.set("sk-ant", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "u", mode: mode)
        #expect(out == "clean")
        #expect(mock.capturedRequest?.url?.host == "api.anthropic.com")
    }

    @Test func cleanup_routes_to_openai_when_provider_is_openai() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"choices":[{"message":{"role":"assistant","content":"clean"}}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .openai
        let kc = keychain()
        try kc.set("sk-oai", forKey: Keychain.Account.openai)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "u", mode: mode)
        #expect(out == "clean")
        #expect(mock.capturedRequest?.url?.host == "api.openai.com")
    }

    @Test func mode_model_override_wins_over_settings_model() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"c"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        settings.llmModel = "claude-haiku-4-5"
        let kc = keychain()
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: "claude-3-5-sonnet-latest", temperature: 0.7)
        _ = try await service.cleanup(transcript: "u", mode: mode)

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        #expect(body["model"] as? String == "claude-3-5-sonnet-latest")
        #expect(body["temperature"] as? Double == 0.7)
    }

    @Test func cleanup_prepends_transcription_preamble_to_mode_prompt() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (
            data: #"{"content":[{"type":"text","text":"c"}]}"#.data(using: .utf8)!,
            status: 200
        )
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = keychain()
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(
            bundleID: "*",
            displayName: "d",
            prompt: "Concise, casual. Strip fillers.",
            model: nil,
            temperature: nil
        )
        _ = try await service.cleanup(transcript: "what's the score?", mode: mode)

        let body = try JSONSerialization.jsonObject(with: try #require(mock.capturedRequest?.httpBody)) as! [String: Any]
        let system = try #require(body["system"] as? String)
        #expect(system.contains(LLMService.transcriptionPreamble))
        #expect(system.contains("Concise, casual. Strip fillers."))
        // Preamble must come before the mode-specific style guidance so the
        // model reads the role definition first.
        let preambleRange = try #require(system.range(of: LLMService.transcriptionPreamble))
        let modeRange = try #require(system.range(of: "Concise, casual. Strip fillers."))
        #expect(preambleRange.lowerBound < modeRange.lowerBound)
    }

    @Test func empty_transcript_short_circuits_to_empty_without_calling_http() async throws {
        let mock = MockHTTPClient()
        var settings = AppSettings(defaults: defaultsSuite())
        settings.llmProvider = .anthropic
        let kc = keychain()
        try kc.set("k", forKey: Keychain.Account.anthropic)
        defer { try? kc.deleteAll() }

        let service = LLMService(settings: settings, keychain: kc, http: mock)
        let mode = Mode(bundleID: "*", displayName: "d", prompt: "S", model: nil, temperature: nil)

        let out = try await service.cleanup(transcript: "", mode: mode)
        #expect(out == "")
        #expect(mock.capturedRequest == nil)
    }
}
