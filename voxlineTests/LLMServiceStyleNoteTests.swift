import Foundation
import Testing
@testable import voxline

@Suite struct LLMServiceStyleNoteTests {

    private func service(http: MockHTTPClient) throws -> LLMService {
        var settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.llmProvider = .anthropic
        let keychain = InMemoryKeychain()
        try keychain.set("k", forKey: KeychainAccount.anthropic)
        return LLMService(settings: settings, keychain: keychain, http: http, structuredOutput: StructuredOutputSupport())
    }

    private func reply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "stop_reason": "end_turn"])
    }

    private let request = StyleNoteRequest(categoryName: "Chat", currentNote: nil, texts: ["Sounds good"], pairs: [], model: "claude-haiku-4-5")

    @Test func sends_the_style_prompt_and_returns_the_note() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (reply("- Uses contractions.\n- No sign-off."), 200)
        let note = try await service(http: mock).styleNote(request)
        #expect(note == "- Uses contractions.\n- No sign-off.")
        let bodyData = try #require(mock.capturedRequest?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["max_tokens"] as? Int == 400)
        #expect((body["system"] as? String)?.contains("writing habits in Chat messages") == true)
    }

    @Test func an_empty_reply_is_an_error() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (reply("   \n "), 200)
        let service = try service(http: mock)
        await #expect(throws: (any Error).self) { try await service.styleNote(request) }
    }
}
