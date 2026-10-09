import Foundation

enum EngineID: String, Codable, CaseIterable, Sendable {
    case apple = "apple"
    case whisperKit = "whisperkit"
    case openAIRealtime = "openai-realtime"

    /// Engine used when the user has not picked one. Set by the bake-off
    /// decision rule (spec, "Decision rule"); never a cloud engine.
    static let `default`: EngineID = .apple

    /// On-device engine the pipeline falls back to when a cloud session fails.
    static var onDeviceDefault: EngineID { EngineID.default.isOnDevice ? EngineID.default : .whisperKit }

    var isOnDevice: Bool { self != .openAIRealtime }

    var displayName: String {
        switch self {
        case .apple:          return "Apple Speech — on-device, fastest"
        case .whisperKit:     return "Whisper — on-device"
        case .openAIRealtime: return "OpenAI — cloud, audio leaves your Mac"
        }
    }

    /// The bare engine name for inline copy, e.g. "Couldn't start Whisper".
    var shortName: String {
        switch self {
        case .apple:          return "Apple Speech"
        case .whisperKit:     return "Whisper"
        case .openAIRealtime: return "OpenAI"
        }
    }
}

struct EngineCapabilities: OptionSet, Sendable {
    let rawValue: Int
    static let streamingPartials   = EngineCapabilities(rawValue: 1 << 0)
    static let vocabularyHints     = EngineCapabilities(rawValue: 1 << 1)
    static let sendsAudioOffDevice = EngineCapabilities(rawValue: 1 << 2)
}

enum EngineReadiness: Equatable, Sendable {
    case ready
    /// `downloadMB` is nil when the size is unknown (OS-managed assets).
    case needsPreparation(downloadMB: Int?)
    /// User-facing reason the engine can't run right now.
    case unavailable(String)
}

struct SessionConfig: Equatable, Sendable {
    var vocabularyHints: [String]
    var locale: Locale

    init(vocabularyHints: [String] = [], locale: Locale = .current) {
        self.vocabularyHints = vocabularyHints
        self.locale = locale
    }
}

struct TranscriptPartial: Equatable, Sendable {
    /// Committed text; will not change for the rest of the session.
    var stable: String
    /// Current guess for the tail; may be revised or dropped.
    var volatile: String

    init(stable: String = "", volatile: String = "") {
        self.stable = stable
        self.volatile = volatile
    }

    var text: String { Self.join(stable, volatile) }
    var isEmpty: Bool { text.isEmpty }

    /// Concatenate two transcript fragments with exactly one space between
    /// them when neither side already provides whitespace at the seam.
    static func join(_ head: String, _ tail: String) -> String {
        let h = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.isEmpty { return t }
        if t.isEmpty { return h }
        return h + " " + t
    }
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    var id: EngineID { get }
    /// Stable identifier of engine + model for metrics, e.g. "apple:en_US".
    var metricsID: String { get }
    var capabilities: EngineCapabilities { get }
    func readiness() async -> EngineReadiness
    /// Download / install / warm. Idempotent; cheap when already ready.
    /// `progress` reports 1 once any download or install is done; warming
    /// may continue after that.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession
}

/// One recording's worth of streaming recognition.
protocol TranscriptionSession: AnyObject, Sendable {
    /// 16 kHz mono Float32. Callable from any thread, including the audio
    /// render thread; must not block on I/O.
    func append(_ samples: [Float])
    /// Snapshots of the transcript as it evolves. Finishes after `finish()`
    /// returns, `cancel()` is called, or the engine stops on its own.
    var partials: AsyncStream<TranscriptPartial> { get }
    /// Flush and return the final text, trimmed.
    func finish() async throws -> String
    /// Idempotent. A pending or later `finish()` throws `CancellationError`.
    func cancel()
}

@MainActor
protocol TranscriptionEngineProviding: AnyObject {
    var current: any TranscriptionEngine { get }
    func engine(for id: EngineID) -> any TranscriptionEngine
}
