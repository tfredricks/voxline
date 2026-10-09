import Foundation

/// A full-duplex text channel to the Realtime API. Production uses
/// `URLSessionRealtimeTransport`; tests script the server.
protocol RealtimeTransport: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next server message. Throws once the connection fails or is closed.
    func receive() async throws -> String
    /// Idempotent. Pending and later `send`/`receive` calls throw.
    func close()
}

typealias RealtimeTransportFactory = @Sendable (URLRequest) -> any RealtimeTransport

/// Cloud transcription over OpenAI's Realtime API (WebSocket), authenticated
/// with the OpenAI key stored for cleanup. Audio leaves the Mac.
///
/// Protocol, verified 2026-10-08 against developers.openai.com
/// (guides/realtime-transcription, reference/resources/realtime/client-events
/// and server-events) and the transcription client in openai-agents-python
/// (`voice/models/openai_stt.py`):
/// - URL: `wss://api.openai.com/v1/realtime?intent=transcription`.
/// - Headers: `Authorization: Bearer <key>`. No `OpenAI-Beta` header; that
///   selects the retired beta event shapes (`transcription_session.update`).
/// - Session configuration, sent first:
///   `{"type": "session.update", "session": {"type": "transcription",
///   "audio": {"input": {"format": {"type": "audio/pcm", "rate": 24000},
///   "transcription": {"model": "gpt-4o-transcribe", "language": "en",
///   "prompt": "…"}, "turn_detection": {"type": "server_vad", "threshold": 0.5,
///   "prefix_padding_ms": 300, "silence_duration_ms": 500}}}}}`.
///   `audio/pcm` at 24000 is 24 kHz mono little-endian PCM16, the only PCM
///   rate accepted. The model and its optional ISO-639-1 `language` and
///   free-text `prompt` live under `audio.input.transcription`.
/// - Client events: `input_audio_buffer.append` (`audio`: base64 PCM16),
///   `input_audio_buffer.commit` (optional `event_id`), and
///   `input_audio_buffer.clear`.
/// - Server events: `session.created`, `session.updated`,
///   `input_audio_buffer.speech_started` / `speech_stopped` (`item_id`),
///   `input_audio_buffer.committed` (`item_id`, `previous_item_id`),
///   `conversation.item.input_audio_transcription.delta` (`item_id`,
///   `delta`), `….completed` (`item_id`, `transcript`), `….failed`
///   (`item_id`, `error.message`), `input_audio_buffer.cleared`, and `error`
///   (`error.message`, `error.code`, `error.event_id`).
/// - Server VAD commits each pause as its own item. Completions of different
///   items may arrive out of order, so text is joined in commit order.
/// - Committing an empty buffer (VAD already committed it) is answered with
///   an `error` whose code is `input_audio_buffer_commit_empty`; that one is
///   benign. A `clear` sent right after the final commit is acknowledged with
///   `input_audio_buffer.cleared` only after the commit is answered, so once
///   it arrives every item of the recording is known.
@MainActor
final class OpenAIRealtimeEngine: TranscriptionEngine {
    nonisolated static let model = "gpt-4o-transcribe"
    nonisolated static let endpoint = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    nonisolated static let missingKeyReason = "Add an OpenAI API key in Settings → General → Recognition to use OpenAI transcription."
    nonisolated static let errorDomain = "com.voxline.openai-realtime"

    let id: EngineID = .openAIRealtime
    let metricsID = "openai:" + OpenAIRealtimeEngine.model
    let capabilities: EngineCapabilities = [.streamingPartials, .vocabularyHints, .sendsAudioOffDevice]

    private let keychain: any KeychainStorage
    private let makeTransport: RealtimeTransportFactory
    private let finishTimeout: Duration

    init(
        keychain: any KeychainStorage,
        transport: @escaping RealtimeTransportFactory = URLSessionRealtimeTransport.factory,
        finishTimeout: Duration = .seconds(10)
    ) {
        self.keychain = keychain
        self.makeTransport = transport
        self.finishTimeout = finishTimeout
    }

    func readiness() async -> EngineReadiness {
        storedKey() == nil ? .unavailable(Self.missingKeyReason) : .ready
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        guard let key = storedKey() else {
            throw NSError(domain: Self.errorDomain, code: 0, userInfo: [NSLocalizedDescriptionKey: Self.missingKeyReason])
        }
        let transport = makeTransport(Self.request(apiKey: key))
        do {
            try await transport.send(RealtimeClientEvent.sessionUpdate(
                model: Self.model,
                language: Self.languageCode(for: config.locale),
                prompt: Self.prompt(for: config.vocabularyHints)
            ))
        } catch {
            transport.close()
            throw error
        }
        return OpenAIRealtimeSession(transport: transport, finishTimeout: finishTimeout)
    }

    nonisolated static func request(apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func prompt(for hints: [String]) -> String? {
        hints.isEmpty ? nil : "Vocabulary: " + hints.joined(separator: ", ")
    }

    /// ISO-639-1 only; the API rejects other codes, and leaving the language
    /// out lets the model detect it.
    nonisolated static func languageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier(.alpha2)
    }

    private func storedKey() -> String? {
        guard let key = try? keychain.string(forKey: KeychainAccount.openai), !key.isBlank else { return nil }
        return key.trimmed
    }
}

/// 16 kHz Float32 capture audio to the 24 kHz PCM16 the Realtime API takes.
enum PCM16Resampler {
    /// Linear interpolation per chunk, clamped to [-1, 1], little-endian.
    static func base64PCM16At24k(from samples16k: [Float]) -> String {
        guard !samples16k.isEmpty else { return "" }
        let outputCount = Int((Double(samples16k.count) * 1.5).rounded())
        let last = samples16k.count - 1
        var pcm = [Int16](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let position = Double(index) * 2 / 3
            let lower = min(Int(position), last)
            let upper = min(lower + 1, last)
            let fraction = Float(position - Double(lower))
            let sample = samples16k[lower] + (samples16k[upper] - samples16k[lower]) * fraction
            pcm[index] = Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
        }
        return pcm.withUnsafeBytes { Data($0) }.base64EncodedString()
    }
}

enum RealtimeClientEvent {
    static func sessionUpdate(model: String, language: String?, prompt: String?) -> String {
        var transcription: [String: Any] = ["model": model]
        if let language { transcription["language"] = language }
        if let prompt { transcription["prompt"] = prompt }
        return encode([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "transcription": transcription,
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500,
                        ],
                    ],
                ],
            ],
        ])
    }

    static func append(audioBase64: String) -> String {
        encode(["type": "input_audio_buffer.append", "audio": audioBase64])
    }

    static func commit(eventID: String) -> String {
        encode(["type": "input_audio_buffer.commit", "event_id": eventID])
    }

    static func clear() -> String {
        encode(["type": "input_audio_buffer.clear"])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: .withoutEscapingSlashes) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

enum RealtimeServerEvent: Equatable {
    case committed(itemID: String)
    case delta(itemID: String, text: String)
    case completed(itemID: String, transcript: String)
    case transcriptionFailed(itemID: String, message: String)
    case cleared
    case error(message: String, code: String?)
    case other(type: String)

    static func parse(_ text: String) -> RealtimeServerEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let itemID = object["item_id"] as? String
        let error = object["error"] as? [String: Any]
        let errorMessage = error?["message"] as? String ?? "OpenAI transcription failed."
        switch type {
        case "input_audio_buffer.committed":
            return itemID.map { .committed(itemID: $0) }
        case "conversation.item.input_audio_transcription.delta":
            return itemID.map { .delta(itemID: $0, text: object["delta"] as? String ?? "") }
        case "conversation.item.input_audio_transcription.completed":
            return itemID.map { .completed(itemID: $0, transcript: object["transcript"] as? String ?? "") }
        case "conversation.item.input_audio_transcription.failed":
            return .transcriptionFailed(itemID: itemID ?? "", message: errorMessage)
        case "input_audio_buffer.cleared":
            return .cleared
        case "error":
            return .error(message: errorMessage, code: error?["code"] as? String)
        default:
            return .other(type: type)
        }
    }
}

/// The recording's items in commit order. `stable` is the run of completed
/// items from the start; everything after the first unfinished item —
/// completed or not — stays volatile, so stable text never changes.
struct RealtimeTranscript: Equatable {
    private var order: [String] = []
    private var completed: [String: String] = [:]
    private var deltas: [String: String] = [:]

    mutating func register(_ itemID: String) {
        if !order.contains(itemID) { order.append(itemID) }
    }

    mutating func appendDelta(_ text: String, to itemID: String) {
        register(itemID)
        guard completed[itemID] == nil else { return }
        deltas[itemID, default: ""] += text
    }

    mutating func complete(_ itemID: String, text: String) {
        register(itemID)
        completed[itemID] = text
        deltas[itemID] = nil
    }

    var hasPendingItems: Bool { order.contains { completed[$0] == nil } }

    var finalText: String {
        order.reduce("") { TranscriptPartial.join($0, completed[$1] ?? "") }
    }

    var partial: TranscriptPartial {
        var result = TranscriptPartial()
        var inStablePrefix = true
        for itemID in order {
            if inStablePrefix, let text = completed[itemID] {
                result.stable = TranscriptPartial.join(result.stable, text)
                continue
            }
            inStablePrefix = false
            result.volatile = TranscriptPartial.join(result.volatile, completed[itemID] ?? deltas[itemID] ?? "")
        }
        return result
    }
}

/// One Realtime connection. `append` only enqueues; a pump task resamples
/// and sends in order. A receive loop folds server events into the
/// transcript. A session released without `finish()` or `cancel()` closes
/// its connection.
final class OpenAIRealtimeSession: TranscriptionSession, @unchecked Sendable {
    static let finalCommitEventID = "voxline_final_commit"
    static let commitEmptyErrorCode = "input_audio_buffer_commit_empty"

    let partials: AsyncStream<TranscriptPartial>

    private let transport: any RealtimeTransport
    private let finishTimeout: Duration
    private let partialsContinuation: AsyncStream<TranscriptPartial>.Continuation
    private let audioContinuation: AsyncStream<[Float]>.Continuation
    private let changes: AsyncStream<Void>
    private let changesContinuation: AsyncStream<Void>.Continuation
    private var pumpTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?

    private let lock = NSLock()
    private var transcript = RealtimeTranscript()
    private var failure: Error?
    private var acceptingInput = true
    private var finalCommitSent = false
    private var inputCleared = false
    private var cancelled = false
    private var timedOut = false
    private var closed = false
    private var appendCount = 0
    private var eventCount = 0

    init(transport: any RealtimeTransport, finishTimeout: Duration) {
        self.transport = transport
        self.finishTimeout = finishTimeout
        (partials, partialsContinuation) = AsyncStream.makeStream(of: TranscriptPartial.self, bufferingPolicy: .bufferingNewest(1))
        (changes, changesContinuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let (audio, audioContinuation) = AsyncStream.makeStream(of: [Float].self)
        self.audioContinuation = audioContinuation

        pumpTask = Task { [weak self] in
            for await samples in audio {
                let message = RealtimeClientEvent.append(audioBase64: PCM16Resampler.base64PCM16At24k(from: samples))
                do {
                    try await transport.send(message)
                } catch {
                    self?.fail(error)
                    return
                }
                self?.countAppend()
            }
        }
        receiveTask = Task { [weak self] in
            while true {
                let text: String
                do {
                    text = try await transport.receive()
                } catch {
                    self?.fail(error)
                    return
                }
                self?.handle(text)
            }
        }
    }

    deinit {
        partialsContinuation.finish()
        close()
    }

    var isAcceptingInput: Bool { lock.withLock { acceptingInput } }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard acceptingInput else { return }
            audioContinuation.yield(samples)
        }
    }

    /// Sends the remaining audio, commits it, and returns the completed items
    /// joined in commit order once every committed item has completed.
    /// Throws a server error, `URLError(.timedOut)` after `finishTimeout`,
    /// or `CancellationError` after `cancel()`.
    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            defer {
                partialsContinuation.finish()
                close()
            }
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.flushAndCollect() }
                group.addTask {
                    try await Task.sleep(for: self.finishTimeout)
                    self.lock.withLock { self.timedOut = true }
                    self.close()
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let text = try await group.next() else { throw CancellationError() }
                return text
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard first else { return }
        partialsContinuation.finish()
        close()
    }

    private func flushAndCollect() async throws -> String {
        do {
            lock.withLock { acceptingInput = false }
            audioContinuation.finish()
            await pumpTask?.value
            _ = try settledText()
            lock.withLock { finalCommitSent = true }
            try await transport.send(RealtimeClientEvent.commit(eventID: Self.finalCommitEventID))
            try await transport.send(RealtimeClientEvent.clear())
            if let text = try settledText() { return text }
            for await _ in changes {
                if let text = try settledText() { return text }
            }
            throw CancellationError()
        } catch {
            throw lock.withLock { terminalError(otherwise: error) }
        }
    }

    /// The final text once the commit is answered and every item completed;
    /// nil while waiting. Throws the session's failure.
    private func settledText() throws -> String? {
        try lock.withLock {
            if cancelled || timedOut || failure != nil { throw terminalError(otherwise: CancellationError()) }
            guard finalCommitSent, inputCleared, !transcript.hasPendingItems else { return nil }
            return transcript.finalText
        }
    }

    /// Must be called with `lock` held.
    private func terminalError(otherwise error: Error) -> Error {
        if cancelled { return CancellationError() }
        if timedOut { return URLError(.timedOut) }
        return failure ?? error
    }

    private func handle(_ text: String) {
        guard let event = RealtimeServerEvent.parse(text) else { return }
        if case .error(_, let code) = event {
            if code == Self.commitEmptyErrorCode {
                AppLog.pipeline.debug("openai realtime: empty final commit, already committed by VAD")
            } else {
                AppLog.pipeline.error("openai realtime: error event \(code ?? "without code", privacy: .public)")
            }
        }
        let partial: TranscriptPartial? = lock.withLock {
            guard !cancelled, !closed else { return nil }
            eventCount += 1
            switch event {
            case .committed(let itemID):
                transcript.register(itemID)
            case .delta(let itemID, let text):
                transcript.appendDelta(text, to: itemID)
                return transcript.partial
            case .completed(let itemID, let text):
                transcript.complete(itemID, text: text)
                return transcript.partial
            case .transcriptionFailed(_, let message):
                failure = failure ?? Self.serverError(message)
            case .cleared:
                inputCleared = true
            case .error(let message, let code):
                if code != Self.commitEmptyErrorCode {
                    failure = failure ?? Self.serverError(message)
                }
            case .other:
                break
            }
            return nil
        }
        if let partial { partialsContinuation.yield(partial) }
        changesContinuation.yield()
    }

    private func countAppend() {
        lock.withLock { appendCount += 1 }
    }

    private func fail(_ error: Error) {
        let recorded = lock.withLock { () -> Bool in
            acceptingInput = false
            guard !closed, !cancelled, failure == nil else { return false }
            failure = error
            return true
        }
        if recorded { changesContinuation.yield() }
    }

    private func close() {
        let counts = lock.withLock { () -> (appends: Int, events: Int)? in
            guard !closed else { return nil }
            closed = true
            acceptingInput = false
            return (appendCount, eventCount)
        }
        guard let counts else { return }
        audioContinuation.finish()
        changesContinuation.finish()
        pumpTask?.cancel()
        receiveTask?.cancel()
        transport.close()
        AppLog.pipeline.info("openai realtime: closed after \(counts.appends) appends, \(counts.events) events")
    }

    private static func serverError(_ message: String) -> NSError {
        NSError(domain: OpenAIRealtimeEngine.errorDomain, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// `URLSessionWebSocketTask` behind `RealtimeTransport`. A failed handshake
/// surfaces from the first `send` or `receive`; a 401 is reported as a
/// rejected key.
final class URLSessionRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    static let factory: RealtimeTransportFactory = { URLSessionRealtimeTransport(request: $0) }

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw handshakeError() ?? error
        }
    }

    func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw handshakeError() ?? error
        }
        switch message {
        case .string(let text): return text
        case .data(let data):   return String(decoding: data, as: UTF8.self)
        @unknown default:       return ""
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func handshakeError() -> NSError? {
        guard let response = task.response as? HTTPURLResponse, response.statusCode != 101 else { return nil }
        let message = response.statusCode == 401
            ? "OpenAI rejected the API key."
            : "OpenAI refused the connection (HTTP \(response.statusCode))."
        return NSError(domain: OpenAIRealtimeEngine.errorDomain, code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
