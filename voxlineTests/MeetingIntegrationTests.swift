import AVFoundation
import Foundation
import Testing
@testable import voxline

/// Real WhisperKit + SpeakerKit over a two-voice fixture as the system track.
/// `scripts/make-meeting-fixture.sh /tmp/voxline-meeting 12`
/// `TEST_RUNNER_VOXLINE_MEETING_FIXTURE_DIR=/tmp/voxline-meeting xcodebuild test ... -only-testing:voxlineTests/MeetingIntegrationTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_MEETING_FIXTURE_DIR"] != nil))
@MainActor
struct MeetingIntegrationTests {

    @Test(.timeLimit(.minutes(10))) func two_voice_call_yields_two_speakers_in_order() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXLINE_MEETING_FIXTURE_DIR"]))
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = MeetingStore(root: root.appending(path: "meetings"))
        var meta = try store.create(startedAt: .now, systemTapStarted: true)
        meta.state = .recorded
        try store.save(meta)

        let writer = try PCMTrackWriter(url: store.directory(for: meta.id).systemPCM)
        let files = try FileManager.default.contentsOfDirectory(at: fixture, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let audio = try AVAudioFile(forReading: file)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let channel = try #require(buffer.floatChannelData?[0])
            writer.append(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
            writer.append([Float](repeating: 0, count: 8_000))
        }
        writer.close()

        let notes = FakeNotesGenerator()
        let pipeline = MeetingPipeline(
            store: store,
            transcriber: WhisperMeetingTranscriber(model: { .smallEn }),
            diarizer: SpeakerKitDiarizer(),
            notes: notes,
            transcoder: FakeTranscoder(),
            settings: {
                MeetingPipelineSettings(notesFolder: root.appending(path: "notes"), notesModel: "m", vocabulary: [], retention: .days14, modelsNeedDownload: false)
            }
        )
        let outcome = await pipeline.process(meta.id)
        guard case .written = outcome else {
            Issue.record("expected notes, got \(outcome)")
            return
        }
        let utterances = try #require(notes.requests.first?.utterances)
        let speakers = Set(utterances.map(\.speaker))
        #expect(speakers.count >= 2, "speakers: \(speakers)")
        #expect(!speakers.contains("Me"))
        let text = utterances.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("revised quote"))
        #expect(utterances.map(\.start) == utterances.map(\.start).sorted())
    }
}
