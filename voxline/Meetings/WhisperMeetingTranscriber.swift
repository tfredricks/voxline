import Foundation
import WhisperKit

/// Whole-track WhisperKit transcription with word timestamps. Loads its own
/// pipeline, separate from dictation's `TranscriptionService`, so the two
/// never share a decoder.
actor WhisperMeetingTranscriber: MeetingTranscribing {

    private let model: @Sendable () -> WhisperModel
    private var kit: WhisperKit?
    private var loading: Task<WhisperKit, Error>?

    init(model: @escaping @Sendable () -> WhisperModel) {
        self.model = model
    }

    func prepare() async throws { _ = try await loadedKit() }

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
        loading?.cancel()
        loading = nil
        kit = nil
    }

    private func loadedKit() async throws -> WhisperKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let config = WhisperModelCache.config(
            variant: model().whisperKitIdentifier,
            downloadBase: try AppPaths.modelCacheDirectory(),
            prewarm: false
        )
        let task = Task { try await WhisperKit(config) }
        loading = task
        do {
            let loaded = try await task.value
            if loading == task { kit = loaded; loading = nil }
            return loaded
        } catch {
            if loading == task { loading = nil }
            throw error
        }
    }
}
