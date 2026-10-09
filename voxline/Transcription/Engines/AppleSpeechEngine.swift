import Foundation
import AVFoundation
import Speech

enum AppleSpeechEngineError: LocalizedError, Equatable {
    case unsupportedLocale
    case unavailable

    var message: String {
        switch self {
        case .unsupportedLocale: return "Apple Speech doesn't support this Mac's language."
        case .unavailable:       return "Apple Speech isn't available on this Mac."
        }
    }

    var errorDescription: String? { message }
}

/// On-device recognition through macOS 26's `SpeechAnalyzer` and
/// `SpeechTranscriber`. Assets are OS-managed, so readiness reports no
/// download size.
@MainActor
final class AppleSpeechEngine: TranscriptionEngine {
    let id: EngineID = .apple
    let capabilities: EngineCapabilities = [.streamingPartials]

    private static let fallbackLocale = Locale(identifier: "en-US")
    private static let progressPollInterval: Duration = .milliseconds(200)

    private let requestedLocale: Locale
    private var resolvedLocale: Locale?

    init(locale: Locale = .current) {
        self.requestedLocale = locale
    }

    var metricsID: String { "apple:" + (resolvedLocale?.identifier ?? "unresolved") }

    func readiness() async -> EngineReadiness {
        guard let locale = await resolveLocale() else {
            return .unavailable(AppleSpeechEngineError.unsupportedLocale.message)
        }
        switch await AssetInventory.status(forModules: [Self.makeTranscriber(locale)]) {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsPreparation(downloadMB: nil)
        case .unsupported:
            return .unavailable(AppleSpeechEngineError.unavailable.message)
        @unknown default:
            return .unavailable(AppleSpeechEngineError.unavailable.message)
        }
    }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let locale = await resolveLocale() else { throw AppleSpeechEngineError.unsupportedLocale }
        let transcriber = Self.makeTranscriber(locale)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .unsupported { throw AppleSpeechEngineError.unavailable }
        if status != .installed,
           let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    while !Task.isCancelled {
                        progress(request.progress.fractionCompleted)
                        try? await Task.sleep(for: Self.progressPollInterval)
                    }
                }
                try await request.downloadAndInstall()
                group.cancelAll()
            }
        }
        progress(1)
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        guard let locale = await resolveLocale() else { throw AppleSpeechEngineError.unsupportedLocale }
        let transcriber = Self.makeTranscriber(locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: .init(priority: .userInitiated, modelRetention: .processLifetime)
        )
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            if !config.vocabularyHints.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings = [.general: config.vocabularyHints]
                try await analyzer.setContext(context)
            }
            let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            guard let format = bestFormat ?? Self.fallbackAnalyzerFormat,
                  let sourceFormat = Self.sourceFormat,
                  let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw AppleSpeechEngineError.unavailable
            }
            try await analyzer.prepareToAnalyze(in: format)
            try await analyzer.start(inputSequence: inputs)
            return AppleSpeechSession(
                analyzer: analyzer,
                transcriber: transcriber,
                converter: converter,
                inputContinuation: inputContinuation
            )
        } catch {
            inputContinuation.finish()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    private func resolveLocale() async -> Locale? {
        if let resolvedLocale { return resolvedLocale }
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Self.fallbackLocale)
        }
        resolvedLocale = resolved
        return resolved
    }

    private static func makeTranscriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }

    private static var sourceFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AVAudioChannelCount(AudioFormat.whisperChannelCount),
            interleaved: false
        )
    }

    private static var fallbackAnalyzerFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AVAudioChannelCount(AudioFormat.whisperChannelCount),
            interleaved: false
        )
    }
}

/// Folds `SpeechTranscriber` results into a running transcript: a final
/// result commits its text to `stable`; a non-final result replaces
/// `volatile`, which covers only the not-yet-finalized tail. Segments are
/// concatenated raw because Apple's results carry their own spacing, and
/// scripts such as Japanese or Thai have no spaces between segments.
struct ApplePartialAccumulator {
    private var partial = TranscriptPartial()

    var finalText: String { partial.stable }

    mutating func apply(text: String, isFinal: Bool) -> TranscriptPartial {
        if isFinal {
            partial.stable += text
            partial.volatile = ""
        } else {
            partial.volatile = text
        }
        return partial
    }
}

/// One `SpeechAnalyzer` run. `append` only converts and yields under the
/// lock, so it is safe on the audio thread. Input that arrives after
/// `finish()` or `cancel()` began is dropped. A session released without
/// either tears its analyzer down.
final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    let partials: AsyncStream<TranscriptPartial>

    private let analyzer: SpeechAnalyzer
    private let converter: AVAudioConverter
    private let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    private let partialsContinuation: AsyncStream<TranscriptPartial>.Continuation
    private let resultsTask: Task<String, Error>

    private let lock = NSLock()
    private var acceptingInput = true
    private var cancelled = false
    private var settled = false

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        converter: AVAudioConverter,
        inputContinuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        self.analyzer = analyzer
        self.converter = converter
        self.inputContinuation = inputContinuation
        let (partials, partialsContinuation) = AsyncStream<TranscriptPartial>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.partials = partials
        self.partialsContinuation = partialsContinuation
        self.resultsTask = Task {
            defer { partialsContinuation.finish() }
            var accumulator = ApplePartialAccumulator()
            for try await result in transcriber.results {
                partialsContinuation.yield(
                    accumulator.apply(text: String(result.text.characters), isFinal: result.isFinal)
                )
            }
            return accumulator.finalText
        }
    }

    deinit {
        partialsContinuation.finish()
        if !settled { tearDown() }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard acceptingInput, let buffer = convert(samples) else { return }
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    func finish() async throws -> String {
        try await withTaskCancellationHandler {
            defer {
                lock.withLock { settled = true }
                partialsContinuation.finish()
            }
            try throwIfCancelled()
            lock.withLock { acceptingInput = false }
            inputContinuation.finish()
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let text = try await resultsTask.value
                try throwIfCancelled()
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                try throwIfCancelled()
                tearDown()
                throw error
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let wasCancelled = lock.withLock { () -> Bool in
            let was = cancelled
            cancelled = true
            settled = true
            acceptingInput = false
            return was
        }
        guard !wasCancelled else { return }
        partialsContinuation.finish()
        tearDown()
    }

    private func tearDown() {
        inputContinuation.finish()
        resultsTask.cancel()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }

    private func throwIfCancelled() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(samples.count)
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: frameCount),
              let channel = input.floatChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: source.count)
        }
        input.frameLength = frameCount

        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}
