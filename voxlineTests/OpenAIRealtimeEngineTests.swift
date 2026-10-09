import Testing
import Foundation
@testable import voxline

/// Scripted stand-in for the Realtime WebSocket. Records every message the
/// engine sends; `respond` turns a sent event into the server events it
/// triggers, and `push` delivers server events at any time.
final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    typealias Responder = @Sendable (_ sent: [String: Any]) -> [[String: Any]]

    private let lock = NSLock()
    private var _sent: [String] = []
    private var inbox: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var _closed = false
    private let respond: Responder

    init(respond: @escaping Responder = { _ in [] }) {
        self.respond = respond
    }

    var sent: [String] { lock.withLock { _sent } }
    var sentEvents: [[String: Any]] { sent.compactMap(Self.object) }
    var sentTypes: [String] { sentEvents.compactMap { $0["type"] as? String } }
    var closed: Bool { lock.withLock { _closed } }

    func send(_ text: String) async throws {
        let isClosed = lock.withLock { () -> Bool in
            if !_closed { _sent.append(text) }
            return _closed
        }
        if isClosed { throw URLError(.networkConnectionLost) }
        for reply in respond(Self.object(text) ?? [:]) { push(reply) }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<String, Error>? in
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                if _closed { return .failure(URLError(.cancelled)) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            _closed = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: URLError(.cancelled))
    }

    func push(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event)
        let text = String(decoding: data, as: UTF8.self)
        let pending = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard !_closed else { return nil }
            if let waiter {
                self.waiter = nil
                return waiter
            }
            inbox.append(text)
            return nil
        }
        pending?.resume(returning: text)
    }

    private static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

private enum ServerEvent {
    static func committed(_ item: String) -> [String: Any] {
        ["type": "input_audio_buffer.committed", "item_id": item, "previous_item_id": NSNull()]
    }
    static func speechStarted(_ item: String) -> [String: Any] {
        ["type": "input_audio_buffer.speech_started", "item_id": item, "audio_start_ms": 0]
    }
    static func delta(_ item: String, _ text: String) -> [String: Any] {
        ["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "content_index": 0, "delta": text]
    }
    static func completed(_ item: String, _ text: String) -> [String: Any] {
        ["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "content_index": 0, "transcript": text]
    }
    static func failed(_ item: String, _ message: String) -> [String: Any] {
        ["type": "conversation.item.input_audio_transcription.failed", "item_id": item, "content_index": 0,
         "error": ["type": "transcription_error", "code": "audio_unintelligible", "message": message]]
    }
    static let cleared: [String: Any] = ["type": "input_audio_buffer.cleared"]
    static func error(_ message: String, code: String? = nil, eventID: String? = nil) -> [String: Any] {
        ["type": "error", "event_id": "event_1",
         "error": ["type": "invalid_request_error", "code": code ?? NSNull(), "message": message, "event_id": eventID ?? NSNull()] as [String: Any]]
    }
}

private func type(_ event: [String: Any]) -> String? { event["type"] as? String }

@Suite struct PCM16ResamplerTests {

    private func decode(_ base64: String) throws -> [Int16] {
        let data = try #require(Data(base64Encoded: base64))
        #expect(data.count % 2 == 0)
        return stride(from: 0, to: data.count, by: 2).map { i in
            Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
        }
    }

    @Test func upsamples_16k_to_24k_as_little_endian_pcm16() throws {
        let values = try decode(PCM16Resampler.base64PCM16At24k(from: Array(repeating: 0.5, count: 16)))
        #expect(values.count == 24)
        #expect(values.allSatisfy { $0 == Int16((0.5 * 32767).rounded()) })
    }

    @Test func clamps_out_of_range_samples() throws {
        let values = try decode(PCM16Resampler.base64PCM16At24k(from: Array(repeating: 1.5, count: 4)))
        #expect(values == Array(repeating: 32767, count: 6))
        let negative = try decode(PCM16Resampler.base64PCM16At24k(from: Array(repeating: -1.5, count: 4)))
        #expect(negative == Array(repeating: -32767, count: 6))
    }

    @Test func interpolates_between_samples() throws {
        let values = try decode(PCM16Resampler.base64PCM16At24k(from: [0, 0.3]))
        #expect(values.count == 3)
        #expect(values[0] == 0)
        #expect(values[1] == Int16((0.2 * 32767).rounded()))
        #expect(values[2] == Int16((0.3 * 32767).rounded()))
    }

    @Test func empty_input_is_empty_output() {
        #expect(PCM16Resampler.base64PCM16At24k(from: []) == "")
    }
}

@Suite struct RealtimeTranscriptTests {

    @Test func completed_items_join_in_commit_order_even_when_they_complete_out_of_order() {
        var transcript = RealtimeTranscript()
        transcript.register("a")
        transcript.register("b")
        transcript.complete("b", text: "second part.")
        #expect(transcript.partial == TranscriptPartial(stable: "", volatile: "second part."))
        transcript.complete("a", text: "First part,")
        #expect(transcript.partial == TranscriptPartial(stable: "First part, second part.", volatile: ""))
        #expect(transcript.finalText == "First part, second part.")
        #expect(!transcript.hasPendingItems)
    }

    @Test func deltas_are_volatile_until_their_item_completes() {
        var transcript = RealtimeTranscript()
        transcript.complete("a", text: "Hello.")
        transcript.appendDelta("How ", to: "b")
        transcript.appendDelta("are", to: "b")
        #expect(transcript.partial == TranscriptPartial(stable: "Hello.", volatile: "How are"))
        #expect(transcript.hasPendingItems)
        transcript.complete("b", text: "How are you?")
        #expect(transcript.partial == TranscriptPartial(stable: "Hello. How are you?", volatile: ""))
        #expect(transcript.finalText == "Hello. How are you?")
    }

    @Test func a_registered_item_without_a_transcript_is_pending() {
        var transcript = RealtimeTranscript()
        transcript.register("a")
        #expect(transcript.hasPendingItems)
        transcript.complete("a", text: "")
        #expect(!transcript.hasPendingItems)
        #expect(transcript.finalText == "")
    }
}

@Suite @MainActor struct OpenAIRealtimeEngineTests {

    private nonisolated static let key = "sk-test-key"

    private func engine(
        key: String? = OpenAIRealtimeEngineTests.key,
        transport: FakeRealtimeTransport = FakeRealtimeTransport(),
        finishTimeout: Duration = .seconds(10),
        requests: RequestLog = RequestLog()
    ) -> OpenAIRealtimeEngine {
        let keychain = InMemoryKeychain(seed: key.map { [KeychainAccount.openai: $0] } ?? [:])
        return OpenAIRealtimeEngine(
            keychain: keychain,
            transport: { request in
                requests.record(request)
                return transport
            },
            finishTimeout: finishTimeout
        )
    }

    final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { _requests } }
        func record(_ request: URLRequest) { lock.withLock { _requests.append(request) } }
    }

    /// A server that commits whatever is buffered on the client's commit,
    /// transcribes it as `finalText`, and acknowledges the clear.
    private static func committingServer(item: String = "item_final", finalText: String) -> FakeRealtimeTransport.Responder {
        { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit":
                return [ServerEvent.committed(item), ServerEvent.delta(item, finalText), ServerEvent.completed(item, finalText)]
            case "input_audio_buffer.clear":
                return [ServerEvent.cleared]
            default:
                return []
            }
        }
    }

    // MARK: identity and readiness

    @Test func identity_and_capabilities() {
        let e = engine()
        #expect(e.id == .openAIRealtime)
        #expect(e.metricsID == "openai:gpt-4o-transcribe")
        #expect(e.capabilities.contains(.streamingPartials))
        #expect(e.capabilities.contains(.vocabularyHints))
        #expect(e.capabilities.contains(.sendsAudioOffDevice))
    }

    @Test func no_key_is_unavailable() async {
        let reason = "Add an OpenAI API key in Settings → General → Recognition to use OpenAI transcription."
        #expect(await engine(key: nil).readiness() == .unavailable(reason))
        #expect(await engine(key: "   ").readiness() == .unavailable(reason))
    }

    @Test func an_unreadable_keychain_is_unavailable() async {
        let keychain = InMemoryKeychain(seed: [KeychainAccount.openai: Self.key])
        keychain.readError = KeychainError.dataProtectionKeychainUnavailable
        let e = OpenAIRealtimeEngine(keychain: keychain, transport: { _ in FakeRealtimeTransport() })
        guard case .unavailable = await e.readiness() else {
            Issue.record("expected unavailable")
            return
        }
    }

    @Test func a_stored_key_is_ready_and_prepare_does_nothing() async throws {
        let e = engine()
        #expect(await e.readiness() == .ready)
        try await e.prepare { _ in Issue.record("prepare reported progress") }
    }

    @Test func opening_without_a_key_throws_and_never_connects() async {
        let requests = RequestLog()
        let e = engine(key: nil, requests: requests)
        await #expect(throws: (any Error).self) {
            _ = try await e.openSession(SessionConfig())
        }
        #expect(requests.requests.isEmpty)
    }

    // MARK: connection and session configuration

    @Test func connects_to_the_transcription_endpoint_with_a_bearer_header() async throws {
        let requests = RequestLog()
        let transport = FakeRealtimeTransport()
        let session = try await engine(transport: transport, requests: requests).openSession(SessionConfig())
        defer { session.cancel() }

        let request = try #require(requests.requests.first)
        #expect(request.url?.absoluteString == "wss://api.openai.com/v1/realtime?intent=transcription")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        #expect(request.url?.absoluteString.contains(Self.key) == false)
    }

    @Test func session_configuration_is_sent_first_with_model_language_prompt_and_vad() async throws {
        let transport = FakeRealtimeTransport()
        let config = SessionConfig(vocabularyHints: ["Voxline", "Kubernetes"], locale: Locale(identifier: "en_US"))
        let session = try await engine(transport: transport).openSession(config)
        defer { session.cancel() }

        let first = try #require(transport.sentEvents.first)
        #expect(type(first) == "session.update")
        let sessionConfig = try #require(first["session"] as? [String: Any])
        #expect(sessionConfig["type"] as? String == "transcription")
        let input = try #require((sessionConfig["audio"] as? [String: Any])?["input"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-4o-transcribe")
        #expect(transcription["language"] as? String == "en")
        #expect(transcription["prompt"] as? String == "Vocabulary: Voxline, Kubernetes")
        let turnDetection = try #require(input["turn_detection"] as? [String: Any])
        #expect(turnDetection["type"] as? String == "server_vad")
    }

    @Test func no_hints_sends_no_prompt() async throws {
        let transport = FakeRealtimeTransport()
        let session = try await engine(transport: transport).openSession(SessionConfig(vocabularyHints: []))
        defer { session.cancel() }

        let first = try #require(transport.sentEvents.first)
        let input = (((first["session"] as? [String: Any])?["audio"] as? [String: Any])?["input"] as? [String: Any])
        let transcription = try #require(input?["transcription"] as? [String: Any])
        #expect(transcription["prompt"] == nil)
    }

    @Test func a_failed_configuration_send_closes_the_transport_and_throws() async {
        let transport = FakeRealtimeTransport()
        transport.close()
        await #expect(throws: (any Error).self) {
            _ = try await engine(transport: transport).openSession(SessionConfig())
        }
    }

    // MARK: streaming

    @Test func appends_are_base64_pcm16_at_24k_sent_in_order() async throws {
        let transport = FakeRealtimeTransport(respond: Self.committingServer(finalText: "hi"))
        let session = try await engine(transport: transport).openSession(SessionConfig())
        session.append(Array(repeating: 0.5, count: 16))
        session.append(Array(repeating: -0.5, count: 32))
        _ = try await session.finish()

        let appends = transport.sentEvents.filter { type($0) == "input_audio_buffer.append" }
        #expect(appends.count == 2)
        let sizes = appends.compactMap { ($0["audio"] as? String).flatMap { Data(base64Encoded: $0)?.count } }
        #expect(sizes == [48, 96])
        #expect(Array(transport.sentTypes.suffix(2)) == ["input_audio_buffer.commit", "input_audio_buffer.clear"])
        #expect(transport.sentTypes.first == "session.update")
    }

    @Test func deltas_and_completions_yield_partials_and_finish_joins_completed_text() async throws {
        let transport = FakeRealtimeTransport(respond: Self.committingServer(item: "item_2", finalText: "How are you?"))
        let session = try await engine(transport: transport).openSession(SessionConfig())
        var iterator = session.partials.makeAsyncIterator()

        transport.push(ServerEvent.speechStarted("item_1"))
        transport.push(ServerEvent.committed("item_1"))
        transport.push(ServerEvent.delta("item_1", "Hello"))
        #expect(await iterator.next() == TranscriptPartial(stable: "", volatile: "Hello"))
        transport.push(ServerEvent.completed("item_1", "Hello there."))
        #expect(await iterator.next() == TranscriptPartial(stable: "Hello there.", volatile: ""))

        session.append(Array(repeating: 0.1, count: 1_600))
        let text = try await session.finish()
        #expect(text == "Hello there. How are you?")
        #expect(transport.closed)
    }

    @Test func finish_waits_for_items_committed_by_vad_before_the_final_commit() async throws {
        let transport = FakeRealtimeTransport { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit":
                return [ServerEvent.error("Error committing input audio buffer: buffer too small.", code: "input_audio_buffer_commit_empty", eventID: sent["event_id"] as? String)]
            case "input_audio_buffer.clear":
                return [ServerEvent.cleared]
            default:
                return []
            }
        }
        let session = try await engine(transport: transport).openSession(SessionConfig())
        transport.push(ServerEvent.committed("item_1"))
        let finishing = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(50))
        transport.push(ServerEvent.completed("item_1", "Late but complete."))
        #expect(try await finishing.value == "Late but complete.")
    }

    @Test func an_empty_buffer_rejection_of_the_final_commit_is_benign() async throws {
        let transport = FakeRealtimeTransport { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit":
                return [ServerEvent.error("Error committing input audio buffer: buffer too small.", code: "input_audio_buffer_commit_empty", eventID: sent["event_id"] as? String)]
            case "input_audio_buffer.clear":
                return [ServerEvent.cleared]
            default:
                return []
            }
        }
        let session = try await engine(transport: transport).openSession(SessionConfig())
        transport.push(ServerEvent.committed("item_1"))
        transport.push(ServerEvent.completed("item_1", "Already done."))
        #expect(try await session.finish() == "Already done.")
    }

    // MARK: failures

    @Test func a_server_error_event_makes_finish_throw_with_its_message() async throws {
        let transport = FakeRealtimeTransport(respond: Self.committingServer(finalText: "ignored"))
        let session = try await engine(transport: transport).openSession(SessionConfig())
        transport.push(ServerEvent.error("Invalid value: 'xx'. Supported languages are ..."))
        try await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await session.finish()
            Issue.record("finish should throw")
        } catch {
            #expect((error as NSError).localizedDescription == "Invalid value: 'xx'. Supported languages are ...")
        }
        #expect(transport.closed)
    }

    @Test func a_failed_item_transcription_makes_finish_throw() async throws {
        let transport = FakeRealtimeTransport { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit":
                return [ServerEvent.committed("item_1"), ServerEvent.failed("item_1", "The audio could not be transcribed.")]
            case "input_audio_buffer.clear":
                return [ServerEvent.cleared]
            default:
                return []
            }
        }
        let session = try await engine(transport: transport).openSession(SessionConfig())
        await #expect(throws: (any Error).self) { _ = try await session.finish() }
    }

    @Test func finish_times_out_when_a_committed_item_never_completes() async throws {
        let transport = FakeRealtimeTransport { sent in
            switch sent["type"] as? String {
            case "input_audio_buffer.commit": return [ServerEvent.committed("item_1")]
            case "input_audio_buffer.clear":  return [ServerEvent.cleared]
            default:                          return []
            }
        }
        let session = try await engine(transport: transport, finishTimeout: .milliseconds(200)).openSession(SessionConfig())
        await #expect(throws: URLError(.timedOut)) { _ = try await session.finish() }
        #expect(transport.closed)
    }

    @Test func a_dropped_connection_makes_finish_throw() async throws {
        let transport = FakeRealtimeTransport()
        let session = try await engine(transport: transport).openSession(SessionConfig())
        transport.close()
        await #expect(throws: (any Error).self) { _ = try await session.finish() }
    }

    @Test func cancel_fails_a_pending_finish_with_cancellation_and_closes() async throws {
        let transport = FakeRealtimeTransport { sent in
            sent["type"] as? String == "input_audio_buffer.commit" ? [ServerEvent.committed("item_1")] : []
        }
        let session = try await engine(transport: transport).openSession(SessionConfig())
        let finishing = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(50))
        session.cancel()
        await #expect(throws: CancellationError.self) { _ = try await finishing.value }
        #expect(transport.closed)
    }

    @Test func cancel_finishes_partials() async throws {
        let session = try await engine().openSession(SessionConfig())
        session.cancel()
        var iterator = session.partials.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }
}

/// One real round trip to OpenAI with a synthesized clip. Opt-in: needs
/// `VOXLINE_OPENAI_LIVE=1` (`TEST_RUNNER_VOXLINE_OPENAI_LIVE=1 xcodebuild test
/// ... -only-testing:voxlineTests/OpenAIRealtimeLiveTests`) and an OpenAI key
/// saved in Voxline. Sends audio to OpenAI and costs a fraction of a cent.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_OPENAI_LIVE"] == "1", "Set VOXLINE_OPENAI_LIVE=1 to call OpenAI"))
@MainActor
struct OpenAIRealtimeLiveTests {

    @Test func transcribes_a_short_clip() async throws {
        let stored = Result { try DataProtectionKeychain().string(forKey: KeychainAccount.openai) }
        guard case .success(let key?) = stored, !key.isBlank else {
            if case .failure(let error) = stored {
                print("OpenAI live smoke: keychain unreadable (\(error.localizedDescription)); skipped")
            } else {
                print("OpenAI live smoke: no OpenAI key stored; skipped")
            }
            return
        }
        let engine = OpenAIRealtimeEngine(keychain: DataProtectionKeychain())
        let samples = try SpeechClipFixture.synthesize("The quick brown fox jumps over the lazy dog.")
        let clock = ContinuousClock()
        let openStart = clock.now
        let session = try await engine.openSession(SessionConfig(vocabularyHints: ["Voxline"], locale: Locale(identifier: "en_US")))
        let open = clock.now - openStart
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 1_600, samples.count)
            session.append(Array(samples[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(100))
        }
        let finishStart = clock.now
        let text = try await session.finish()
        let finish = clock.now - finishStart
        print("OpenAI live smoke: open \(open), finish \(finish), transcript: \(text)")
        #expect(text.lowercased().contains("fox"))
    }
}
