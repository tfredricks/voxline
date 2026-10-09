import Accelerate
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

    /// The confirmed segments a final pass keeps verbatim. Trailing segments
    /// are released until at least `minimumSpan` seconds of audio follow the
    /// last kept one; the final pass re-transcribes the released segments
    /// from that point, so each stretch of audio is transcribed exactly once.
    static func splitForFinalPass(
        _ confirmed: [TimedText],
        audioDuration: Float,
        minimumSpan: Float
    ) -> (kept: [TimedText], released: [TimedText]) {
        var keptCount = confirmed.count
        while keptCount > 0, audioDuration - confirmed[keptCount - 1].end < minimumSpan {
            keptCount -= 1
        }
        return (Array(confirmed.prefix(keptCount)), Array(confirmed.dropFirst(keptCount)))
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
        try Task.checkCancellation()
        progress(1)
        try await service.prewarm()
    }

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        let kit = try await service.loadedKit()
        return WhisperKitStreamingSession(kit: kit, options: DecodingOptions())
    }
}

/// Rolling re-transcription of the whole recording. A background loop runs a
/// pass each time at least a second of new audio has arrived, or when speech
/// pauses, starting from the end of the last confirmed segment. Only one pass
/// is in flight at a time. `finish()` stops the loop; when only silence
/// follows the audio the last pass covered, that pass's text is final.
/// Otherwise it runs one final pass over the complete buffer.
///
/// Audio is silent where its peak absolute amplitude is below `silencePeak`
/// (default 0.02, about −34 dBFS) or `relativeSilence` of the loudest audio
/// so far, whichever is lower, so a quiet speaker's soft words are not taken
/// for silence. A session never as loud as `silencePeak` never finishes early.
final class WhisperKitStreamingSession: TranscriptionSession, @unchecked Sendable {
    typealias Transcribe = @Sendable (_ samples: [Float], _ clipStart: Float) async throws -> [TimedText]

    static let samplesPerPass = 16_000
    /// A pause: this much trailing silence after at least
    /// `minimumSpeechSamples` of non-silent audio since the last pass. The
    /// speech minimum only rules out a single noise blip, so a pause just
    /// after a rolling pass still gets a pass of its own.
    static let pauseSamples = 4_800
    static let minimumSpeechSamples = 800
    /// Non-silent audio is counted in frames of this many samples (10 ms).
    static let peakFrameSamples = 160
    static let relativeSilence: Float = 0.1
    static let pollInterval: Duration = .milliseconds(100)
    static let keepUnconfirmed = 2
    /// WhisperKit starts no decode window when `windowClipTime` (1.0 s) or
    /// less of audio follows the clip start, so the final pass always starts
    /// at least this many seconds before the end of the audio.
    static let minimumFinalSpan: Float = 1.5

    let partials: AsyncStream<TranscriptPartial>
    private let continuation: AsyncStream<TranscriptPartial>.Continuation
    private let transcribe: Transcribe
    private let silencePeak: Float
    private let lock = NSLock()
    private var buffer: [Float] = []
    private var lastPassSampleCount = 0
    private var inFlightSampleCount: Int?
    private var coveredSampleCount = 0
    private var coveredHasText = false
    private var sessionPeak: Float = 0
    private var confirmed: [TimedText] = []
    private var confirmedEnd: Float = 0
    private var lastUnconfirmed: [TimedText] = []
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

    init(silencePeak: Float = 0.02, transcribe: @escaping Transcribe) {
        self.silencePeak = silencePeak
        self.transcribe = transcribe
        (partials, continuation) = AsyncStream.makeStream(of: TranscriptPartial.self)
        loopTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, await self.passIfDue() else { return }
            }
        }
    }

    deinit {
        loopTask?.cancel()
        continuation.finish()
    }

    func append(_ samples: [Float]) {
        let peak = samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples)
        lock.withLock {
            guard !cancelled else { return }
            buffer.append(contentsOf: samples)
            sessionPeak = max(sessionPeak, peak)
        }
    }

    /// When the last completed rolling pass heard words and only silence
    /// follows the audio it covered, its confirmed and unconfirmed text is
    /// final. A pass still in flight with only silence after its audio is
    /// awaited rather than cancelled, so it can be that pass.
    ///
    /// Otherwise final text = kept confirmed text, then the final pass's
    /// segments. When the final pass finds nothing past its clip start, the
    /// released segments and the unconfirmed segments of the last rolling
    /// pass that heard words stand in, so words already shown as partials are
    /// never dropped.
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
        let (loop, awaitsInFlightPass) = lock.withLock {
            finishing = true
            return (loopTask, inFlightSampleCount.map(onlySilenceFollows) ?? false)
        }
        if !awaitsInFlightPass { loop?.cancel() }
        await loop?.value

        let lastPassText = try lock.withLock {
            if cancelled { throw CancellationError() }
            return lastPassTextIfFinal()
        }
        if let lastPassText { return lastPassText }

        let input = try lock.withLock {
            if cancelled { throw CancellationError() }
            let samples = copyOfBuffer()
            let split = SegmentConfirmation.splitForFinalPass(
                confirmed,
                audioDuration: Float(samples.count) / Float(AudioFormat.whisperSampleRate),
                minimumSpan: Self.minimumFinalSpan
            )
            return (
                samples: samples,
                clipStart: split.kept.last?.end ?? 0,
                keptText: Self.joined(split.kept),
                fallbackText: Self.joined(split.released + lastUnconfirmed)
            )
        }
        guard !input.samples.isEmpty else { return "" }

        let finalPass = Task { [transcribe] in try await transcribe(input.samples, input.clipStart) }
        let cancelledMeanwhile = lock.withLock {
            finalPassTask = finalPass
            return cancelled
        }
        if cancelledMeanwhile { finalPass.cancel() }
        let tail: [TimedText]
        do {
            tail = try await finalPass.value
        } catch {
            try throwIfCancelled()
            throw error
        }
        try throwIfCancelled()
        let tailText = Self.joined(tail.filter { $0.end > input.clipStart })
        return TranscriptPartial.join(input.keptText, tailText.isEmpty ? input.fallbackText : tailText)
    }

    private func throwIfCancelled() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
        }
    }

    private enum Poll {
        case stop
        case idle
        case pass(samples: [Float], clipStart: Float)
    }

    /// Runs a pass when one is due. Returns false once the session is
    /// finishing or cancelled, which ends the loop.
    private func passIfDue() async -> Bool {
        let poll: Poll = lock.withLock {
            if finishing || cancelled { return .stop }
            guard isPassDue() else { return .idle }
            lastPassSampleCount = buffer.count
            inFlightSampleCount = buffer.count
            return .pass(samples: copyOfBuffer(), clipStart: confirmedEnd)
        }
        switch poll {
        case .stop:
            return false
        case .idle:
            return true
        case .pass(let samples, let clipStart):
            await runPass(samples, clipStart: clipStart)
            return lock.withLock { !finishing && !cancelled }
        }
    }

    private func runPass(_ samples: [Float], clipStart: Float) async {
        let segments: [TimedText]
        do {
            segments = try await transcribe(samples, clipStart)
        } catch {
            lock.withLock { inFlightSampleCount = nil }
            if !Task.isCancelled {
                AppLog.whisper.error("streaming pass failed: \(error.localizedDescription, privacy: .public)")
            }
            return
        }

        let partial: TranscriptPartial? = lock.withLock {
            inFlightSampleCount = nil
            guard !cancelled else { return nil }
            let split = SegmentConfirmation.split(segments, keepUnconfirmed: Self.keepUnconfirmed, after: confirmedEnd)
            coveredSampleCount = samples.count
            coveredHasText = (split.confirmed + split.unconfirmed).contains {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if coveredHasText {
                confirmed.append(contentsOf: split.confirmed)
                confirmedEnd = split.newConfirmedEnd
                lastUnconfirmed = split.unconfirmed
            }
            return TranscriptPartial(stable: Self.joined(confirmed), volatile: Self.joined(lastUnconfirmed))
        }
        if let partial { continuation.yield(partial) }
    }

    /// Must be called with `lock` held.
    private func isPassDue() -> Bool {
        let fresh = buffer.count - lastPassSampleCount
        if fresh >= Self.samplesPerPass { return true }
        guard buffer.count >= Self.pauseSamples, fresh >= Self.minimumSpeechSamples else { return false }
        return buffer.withUnsafeBufferPointer { all in
            isSilent(UnsafeBufferPointer(rebasing: all[(all.count - Self.pauseSamples)...]))
                && nonSilentSampleCount(UnsafeBufferPointer(rebasing: all[lastPassSampleCount...])) >= Self.minimumSpeechSamples
        }
    }

    /// Must be called with `lock` held.
    private func lastPassTextIfFinal() -> String? {
        guard coveredSampleCount > 0, coveredHasText, onlySilenceFollows(coveredSampleCount) else { return nil }
        return Self.joined(confirmed + lastUnconfirmed)
    }

    /// Must be called with `lock` held. Scans the buffer in place.
    private func isSilent(from start: Int) -> Bool {
        buffer.withUnsafeBufferPointer { isSilent(UnsafeBufferPointer(rebasing: $0[start...])) }
    }

    /// Must be called with `lock` held. False until the session has been
    /// at least as loud as `silencePeak`, so a quiet session never ends early.
    private func onlySilenceFollows(_ start: Int) -> Bool {
        sessionPeak >= silencePeak && isSilent(from: start)
    }

    /// Must be called with `lock` held.
    private func isSilent(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        samples.isEmpty || vDSP.maximumMagnitude(samples) < min(silencePeak, Self.relativeSilence * sessionPeak)
    }

    /// Must be called with `lock` held.
    private func nonSilentSampleCount(_ samples: UnsafeBufferPointer<Float>) -> Int {
        stride(from: 0, to: samples.count, by: Self.peakFrameSamples).reduce(0) { count, start in
            let frame = UnsafeBufferPointer(rebasing: samples[start..<min(start + Self.peakFrameSamples, samples.count)])
            return isSilent(frame) ? count : count + frame.count
        }
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

/// One transcribe at a time per kit: a session's passes never overlap, and
/// across sessions this relies on the pipeline running one dictation at a
/// time.
private final class WhisperKitHandle: @unchecked Sendable {
    let kit: WhisperKit
    init(kit: WhisperKit) { self.kit = kit }
}
