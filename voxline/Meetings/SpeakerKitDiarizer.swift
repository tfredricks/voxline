import Foundation
import SpeakerKit
import WhisperKit

/// SpeakerKit (pyannote) diarization aligned to WhisperKit word timings.
actor SpeakerKitDiarizer: MeetingDiarizing {

    private var kit: SpeakerKit?

    init() {}

    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText] {
        guard !transcript.results.isEmpty else { return [] }
        let kit = try await loadedKit()
        let diarization = try await kit.diarize(audioArray: samples)
        let aligned = diarization.addSpeakerInfo(to: transcript.results)
        let raw = aligned.joined().map {
            MeetingSpeechConversion.RawSpeakerSegment(
                speakerIDs: $0.speaker.speakerIds, start: $0.startTime, end: $0.endTime, text: $0.text
            )
        }
        AppLog.meetings.info("diarized \(diarization.speakerCount) speaker(s)")
        return MeetingSpeechConversion.speakerSegments(raw)
    }

    func release() {
        kit = nil
    }

    private func loadedKit() async throws -> SpeakerKit {
        if let kit { return kit }
        let loaded = try await SpeakerKit(PyannoteConfig(
            modelDownloadConfig: ModelDownloadConfig(
                downloadBase: try AppPaths.modelCacheDirectory().path,
                modelRepo: "argmaxinc/speakerkit-coreml"
            ),
            verbose: false
        ))
        kit = loaded
        return loaded
    }
}
