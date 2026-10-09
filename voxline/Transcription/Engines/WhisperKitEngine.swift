import Foundation
import WhisperKit

struct TimedText: Equatable, Sendable {
    let text: String
    let start: Float
    let end: Float
}

/// Rolling-window confirmation, modeled on WhisperKit's `AudioStreamTranscriber`:
/// segments ending at or before `confirmedEnd` were confirmed by an earlier
/// pass; of the rest, all but the last `keepUnconfirmed` become confirmed.
enum SegmentConfirmation {
    static func split(
        _ segments: [TimedText],
        keepUnconfirmed: Int,
        after confirmedEnd: Float
    ) -> (confirmed: [TimedText], unconfirmed: [TimedText], newConfirmedEnd: Float) {
        let pending = segments.filter { $0.end > confirmedEnd }
        let confirmCount = max(0, pending.count - keepUnconfirmed)
        let confirmed = Array(pending.prefix(confirmCount))
        let unconfirmed = Array(pending.dropFirst(confirmCount))
        return (confirmed, unconfirmed, confirmed.last?.end ?? confirmedEnd)
    }
}

enum WhisperSegmentText {
    static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Streams on-device Whisper transcription through `TranscriptionService`'s
/// loaded pipeline. Vocabulary hints are ignored: WhisperKit 1.0's
/// `TextDecoder` applies its stop checks while forcing prompt tokens, so a
/// prompted decode returns empty text. LLM cleanup applies the vocabulary
/// instead.
@MainActor
final class WhisperKitEngine: TranscriptionEngine {
    let service: TranscriptionService
    let id: EngineID = .whisperKit
    let capabilities: EngineCapabilities = [.streamingPartials]

    init(service: TranscriptionService) {
        self.service = service
    }

    var metricsID: String { service.engineID }

    func readiness() async -> EngineReadiness {
        TranscriptionService.isModelCached(service.model)
            ? .ready
            : .needsPreparation(downloadMB: service.model.approxSizeMB)
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await service.prepareModel(progressHandler: progress)
        try await service.prewarm()
    }

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        let kit = try await service.loadedKit()
        return WhisperKitStreamingSession(kit: kit, options: DecodingOptions())
    }
}

/// Rolling re-transcription of the whole recording. A background loop runs a
/// pass each time at least a second of new audio has arrived, starting from
/// the end of the last confirmed segment. Only one pass is in flight at a
/// time; `finish()` stops the loop, waits for its pass, then runs one final
/// pass over the complete buffer.
final class WhisperKitStreamingSession: TranscriptionSession, @unchecked Sendable {
    typealias Transcribe = @Sendable (_ samples: [Float], _ clipStart: Float) async throws -> [TimedText]

    static let samplesPerPass = 16_000
    static let pollInterval: Duration = .milliseconds(100)
    static let keepUnconfirmed = 2

    let partials: AsyncStream<TranscriptPartial>
    private let continuation: AsyncStream<TranscriptPartial>.Continuation
    private let transcribe: Transcribe
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var lastPassSampleCount = 0
    private var confirmed: [TimedText] = []
    private var confirmedEnd: Float = 0
    private var finishing = false
    private var cancelled = false
    private var loopTask: Task<Void, Never>?
    private var finalPassTask: Task<[TimedText], Error>?

    convenience init(kit: WhisperKit, options: DecodingOptions) {
        let handle = WhisperKitHandle(kit: kit)
        self.init { samples, clipStart in
            var passOptions = options
            passOptions.clipTimestamps = [clipStart]
            let results = try await handle.kit.transcribe(audioArray: samples, decodeOptions: passOptions)
            return results.flatMap(\.segments).map {
                TimedText(text: WhisperSegmentText.clean($0.text), start: $0.start, end: $0.end)
            }
        }
    }

    init(transcribe: @escaping Transcribe) {
        self.transcribe = transcribe
        (partials, continuation) = AsyncStream.makeStream(of: TranscriptPartial.self)
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self else { return }
                await self.passIfDue()
            }
        }
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    func append(_ samples: [Float]) {
        lock.withLock {
            guard !cancelled else { return }
            buffer.append(contentsOf: samples)
        }
    }

    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try await finishPasses()
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let (loop, finalPass) = lock.withLock {
            cancelled = true
            return (loopTask, finalPassTask)
        }
        loop?.cancel()
        finalPass?.cancel()
        continuation.finish()
    }

    private func finishPasses() async throws -> String {
        defer { continuation.finish() }
        let loop = lock.withLock {
            finishing = true
            return loopTask
        }
        loop?.cancel()
        await loop?.value

        let (samples, clipStart, stable) = try lock.withLock {
            if cancelled { throw CancellationError() }
            return (copyOfBuffer(), confirmedEnd, Self.joined(confirmed))
        }
        guard !samples.isEmpty else { return "" }

        let finalPass = Task { [transcribe] in try await transcribe(samples, clipStart) }
        let cancelledMeanwhile = lock.withLock {
            finalPassTask = finalPass
            return cancelled
        }
        if cancelledMeanwhile { finalPass.cancel() }
        let tail = try await finalPass.value
        try lock.withLock {
            if cancelled { throw CancellationError() }
        }
        return TranscriptPartial.join(stable, Self.joined(tail.filter { $0.end > clipStart }))
    }

    private func passIfDue() async {
        let due: (samples: [Float], clipStart: Float)? = lock.withLock {
            guard !finishing, !cancelled, buffer.count - lastPassSampleCount >= Self.samplesPerPass else { return nil }
            lastPassSampleCount = buffer.count
            return (copyOfBuffer(), confirmedEnd)
        }
        guard let due else { return }

        let segments: [TimedText]
        do {
            segments = try await transcribe(due.samples, due.clipStart)
        } catch {
            if !Task.isCancelled {
                AppLog.whisper.error("streaming pass failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let partial: TranscriptPartial? = lock.withLock {
            guard !cancelled else { return nil }
            let split = SegmentConfirmation.split(segments, keepUnconfirmed: Self.keepUnconfirmed, after: confirmedEnd)
            confirmed.append(contentsOf: split.confirmed)
            confirmedEnd = split.newConfirmedEnd
            return TranscriptPartial(stable: Self.joined(confirmed), volatile: Self.joined(split.unconfirmed))
        }
        if let partial { continuation.yield(partial) }
    }

    /// Must be called with `lock` held. A real copy, so the audio thread's
    /// next `append` never pays for a copy-on-write of the whole buffer.
    private func copyOfBuffer() -> [Float] {
        buffer.withUnsafeBufferPointer { Array($0) }
    }

    private static func joined(_ segments: [TimedText]) -> String {
        segments.reduce("") { TranscriptPartial.join($0, $1.text) }
    }
}

private final class WhisperKitHandle: @unchecked Sendable {
    let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
}
