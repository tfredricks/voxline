import Foundation
import WhisperKit

/// Whole-track WhisperKit transcription with word timestamps. Loads its own
/// pipeline, separate from dictation's `TranscriptionService`, so the two
/// never share a decoder.
actor WhisperMeetingTranscriber: MeetingTranscribing {

    private let model: @Sendable () -> WhisperModel
    private var kit: WhisperKit?

    init(model: @escaping @Sendable () -> WhisperModel) {
        self.model = model
    }

    func transcribe(_ samples: [Float]) async throws -> TrackTranscript {
        let kit = try await loadedKit()
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(wordTimestamps: true, chunkingStrategy: .vad)
        )
        let raw = results.flatMap(\.segments).map {
            MeetingSpeechConversion.RawSegment(start: $0.start, end: $0.end, text: $0.text)
        }
        return TrackTranscript(segments: MeetingSpeechConversion.timedSegments(raw), results: results)
    }

    func release() {
        kit = nil
    }

    private func loadedKit() async throws -> WhisperKit {
        if let kit { return kit }
        let loaded = try await WhisperKit(WhisperKitConfig(
            model: model().whisperKitIdentifier,
            downloadBase: try AppPaths.modelCacheDirectory(),
            modelRepo: "argmaxinc/whisperkit-coreml",
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        ))
        kit = loaded
        return loaded
    }
}
