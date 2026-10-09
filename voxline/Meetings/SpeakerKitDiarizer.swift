import Foundation
import SpeakerKit
import WhisperKit

/// SpeakerKit (pyannote) diarization aligned to WhisperKit word timings.
actor SpeakerKitDiarizer: MeetingDiarizing {

    private var kit: SpeakerKit?
    private var loading: Task<SpeakerKit, Error>?

    init() {}

    func prepare() async throws { _ = try await loadedKit() }

    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText] {
        guard !transcript.segments.isEmpty else { return [] }
        let wordCount = transcript.results.reduce(0) { total, result in
            total + result.segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
        }
        try MeetingSpeechConversion.requireWordTimings(wordCount: wordCount)
        let kit = try await loadedKit()
        let diarization = try await kit.diarize(audioArray: samples)
        let aligned = diarization.addSpeakerInfo(to: transcript.results)
        let raw = aligned.joined().map {
            MeetingSpeechConversion.RawSpeakerSegment(
                speakerIDs: $0.speaker.speakerIds, start: $0.startTime, end: $0.endTime, text: $0.text
            )
        }
        let segments = MeetingSpeechConversion.speakerSegments(raw)
        if segments.isEmpty {
            AppLog.meetings.error("diarization produced no speaker segments for a non-empty transcript")
        }
        try MeetingSpeechConversion.requireMatched(
            transcriptSegments: transcript.segments.count, speakerSegments: segments.count
        )
        AppLog.meetings.info("diarized \(diarization.speakerCount) speaker(s)")
        return segments
    }

    func release() {
        loading?.cancel()
        loading = nil
        kit = nil
    }

    private func loadedKit() async throws -> SpeakerKit {
        if let kit { return kit }
        if let loading { return try await loading.value }
        let downloadBase = try AppPaths.modelCacheDirectory().path
        let task = Task {
            try await SpeakerKit(PyannoteConfig(
                modelDownloadConfig: ModelDownloadConfig(
                    downloadBase: downloadBase,
                    modelRepo: "argmaxinc/speakerkit-coreml"
                ),
                verbose: false
            ))
        }
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
