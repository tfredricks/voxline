import Foundation
import Testing
@testable import voxline

@Suite struct LLMServiceMeetingNotesTests {

    private let notesJSON = #"{"title":"Sync","summary":"S.","keyPoints":[],"decisions":[],"actionItems":[],"openQuestions":[],"speakerNames":[]}"#

    private func service(http: MockHTTPClient) throws -> LLMService {
        var settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.llmProvider = .anthropic
        let keychain = InMemoryKeychain()
        try keychain.set("k", forKey: KeychainAccount.anthropic)
        return LLMService(settings: settings, keychain: keychain, http: http, structuredOutput: StructuredOutputSupport())
    }

    private func request(model: String) -> MeetingNotesRequest {
        MeetingNotesRequest(
            model: model,
            utterances: [MeetingUtterance(speaker: "Me", start: 0, end: 1, text: "Hello.")],
            startedAt: Date(timeIntervalSince1970: 0), duration: 60, vocabulary: []
        )
    }

    private func anthropicReply(_ text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": text]], "stop_reason": "end_turn"])
    }

    @Test func sends_structured_request_with_notes_budget_and_parses_reply() async throws {
        let mock = MockHTTPClient()
        mock.stubResponse = (anthropicReply(notesJSON), 200)
        let notes = try await service(http: mock).meetingNotes(request(model: "claude-haiku-4-5"))
        #expect(notes.title == "Sync")

        let bodyData = try #require(mock.capturedRequest?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["max_tokens"] as? Int == 8_192)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["format"] != nil)
        #expect((body["system"] as? String)?.contains("You write meeting notes") == true)
    }

    @Test func thinking_models_get_headroom() {
        #expect(LLMRequest.meetingNotesBudget(model: "claude-sonnet-5-5") == 8_192 + 4_096)
        #expect(LLMRequest.meetingNotesBudget(model: "claude-haiku-4-5") == 8_192)
    }

    @Test func missing_key_throws() async throws {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let service = LLMService(settings: settings, keychain: InMemoryKeychain(), http: MockHTTPClient())
        await #expect(throws: LLMError.self) { try await service.meetingNotes(request(model: "m")) }
    }

    @Test func long_session_timeouts() {
        let session = URLSessionHTTPClient.makeSession(requestTimeout: 60, resourceTimeout: 180)
        #expect(session.configuration.timeoutIntervalForRequest == 60)
        #expect(session.configuration.timeoutIntervalForResource == 180)
        let dictation = URLSessionHTTPClient.makeSession()
        #expect(dictation.configuration.timeoutIntervalForResource == 30)
    }
}
