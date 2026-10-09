import Foundation
import Testing
@testable import voxline

private struct Boom: LocalizedError {
    var message = "boom."
    var errorDescription: String? { message }
}

final class FakeTranscriber: MeetingTranscribing, @unchecked Sendable {
    var responses: [Result<TrackTranscript, Error>] = []
    private(set) var calls = 0
    private(set) var released = false
    func transcribe(_ samples: [Float]) async throws -> TrackTranscript {
        calls += 1
        return try responses.removeFirst().get()
    }
    func release() async { released = true }
}

final class FakeDiarizer: MeetingDiarizing, @unchecked Sendable {
    var response: Result<[SpeakerSegmentText], Error> = .success([])
    private(set) var receivedSegments: [TimedSegment]?
    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText] {
        receivedSegments = transcript.segments
        return try response.get()
    }
    func release() async {}
}

final class FakeNotesGenerator: MeetingNotesGenerating, @unchecked Sendable {
    var response: Result<MeetingNotes, Error> = .success(MeetingNotes(
        title: "Pricing sync", summary: "S.", keyPoints: [], decisions: [], actionItems: [], openQuestions: [], speakerNames: []
    ))
    private(set) var requests: [MeetingNotesRequest] = []
    func meetingNotes(_ request: MeetingNotesRequest) async throws -> MeetingNotes {
        requests.append(request)
        return try response.get()
    }
}

final class FakeTranscoder: MeetingAudioTranscoding, @unchecked Sendable {
    private(set) var calls: [URL] = []
    func transcode(pcm: URL, to m4a: URL) throws { calls.append(pcm) }
}

@MainActor
@Suite struct MeetingPipelineTests {

    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    private var store: MeetingStore { MeetingStore(root: root.appending(path: "meetings")) }
    private var notesFolder: URL { root.appending(path: "notes") }
    private let transcriber = FakeTranscriber()
    private let diarizer = FakeDiarizer()
    private let notes = FakeNotesGenerator()
    private let transcoder = FakeTranscoder()
    private let speech: [Float] = [Float](repeating: 0.3, count: 16_000)
    private let silence: [Float] = [Float](repeating: 0, count: 16_000)

    private func makePipeline(retention: MeetingAudioRetention = .days14, download: Bool = false) -> MeetingPipeline {
        let folder = notesFolder
        return MeetingPipeline(
            store: store, transcriber: transcriber, diarizer: diarizer, notes: notes, transcoder: transcoder,
            settings: { MeetingPipelineSettings(notesFolder: folder, notesModel: "m", vocabulary: ["Acme"], retention: retention, modelsNeedDownload: download) },
            timeZone: TimeZone(identifier: "UTC")!
        )
    }

    private func meeting(mic: [Float]?, system: [Float]?, tap: Bool = true) throws -> UUID {
        var meta = try store.create(startedAt: Date(timeIntervalSince1970: 1_791_554_520), systemTapStarted: tap)
        meta.state = .recorded
        meta.durationSeconds = 120
        try store.save(meta)
        let dir = store.directory(for: meta.id)
        if let mic { let w = try PCMTrackWriter(url: dir.micPCM); w.append(mic); w.close() }
        if let system { let w = try PCMTrackWriter(url: dir.systemPCM); w.append(system); w.close() }
        return meta.id
    }

    private func transcript(_ text: String, at start: Double = 0) -> TrackTranscript {
        TrackTranscript(segments: [TimedSegment(start: start, end: start + 1, text: text)])
    }

    private func written(_ outcome: MeetingOutcome) throws -> String {
        guard case .written(let url) = outcome else {
            Issue.record("expected .written, got \(outcome)")
            return ""
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func call_meeting_writes_notes_with_me_and_diarized_speakers() async throws {
        let id = try meeting(mic: speech, system: speech)
        transcriber.responses = [.success(transcript("I can do eight.", at: 5)), .success(transcript("Thanks for joining."))]
        diarizer.response = .success([SpeakerSegmentText(speakerID: 4, start: 0, end: 1, text: "Thanks for joining.")])
        let pipeline = makePipeline()
        var stages: [MeetingStage] = []
        pipeline.onStage = { stages.append($0) }

        let text = try written(await pipeline.process(id))

        #expect(text.hasPrefix("# Pricing sync\n"))
        #expect(text.contains("**Speaker 1** [00:00:00] Thanks for joining."))
        #expect(text.contains("**Me** [00:00:05] I can do eight."))
        #expect(stages == [.transcribing(track: 1, of: 2), .transcribing(track: 2, of: 2), .identifyingSpeakers, .writingNotes])
        #expect(diarizer.receivedSegments == transcript("Thanks for joining.").segments)
        #expect(notes.requests.first?.vocabulary == ["Acme"])
        #expect(transcriber.released)
        let meta = try store.load(id)
        #expect(meta.state == .done)
        #expect(meta.title == "Pricing sync")
        #expect(meta.notesPath?.hasSuffix("2026-10-09 1402 Pricing sync.md") == true)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: id).transcript.path))
        #expect(transcoder.calls.count == 2)
    }

    @Test func silent_system_track_with_tap_processes_mic_only_and_warns() async throws {
        let id = try meeting(mic: speech, system: silence, tap: true)
        transcriber.responses = [.success(transcript("Hello everyone."))]
        diarizer.response = .success([SpeakerSegmentText(speakerID: 0, start: 0, end: 1, text: "Hello everyone.")])

        let text = try written(await makePipeline().process(id))

        #expect(transcriber.calls == 1)
        #expect(diarizer.receivedSegments == transcript("Hello everyone.").segments)
        #expect(text.contains("**Speaker 1** [00:00:00] Hello everyone."))
        #expect(text.contains(MeetingPipeline.silentSystemWarning))
    }

    @Test func no_tap_means_no_silent_system_warning() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        let text = try written(await makePipeline().process(id))
        #expect(!text.contains(MeetingPipeline.silentSystemWarning))
    }

    @Test func nothing_recorded_deletes_the_meeting() async throws {
        let id = try meeting(mic: silence, system: silence)
        let outcome = await makePipeline().process(id)
        #expect(outcome == .nothingRecorded)
        #expect(transcriber.calls == 0)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: id).url.path))
    }

    @Test func notes_failure_still_writes_transcript() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        notes.response = .failure(Boom(message: "No API key configured."))
        let text = try written(await makePipeline().process(id))
        #expect(text.hasPrefix("# Meeting\n"))
        #expect(text.contains("> Notes not generated: No API key configured. Use Regenerate Notes in the menu."))
        #expect(try store.load(id).state == .done)
    }

    @Test func diarization_failure_labels_call_audio_them() async throws {
        let id = try meeting(mic: nil, system: speech)
        transcriber.responses = [.success(transcript("Hi from the call."))]
        diarizer.response = .failure(Boom())
        let text = try written(await makePipeline().process(id))
        #expect(text.contains("**Them** [00:00:00] Hi from the call."))
        #expect(text.contains(MeetingPipeline.speakersWarning("boom.")))
    }

    @Test func system_transcription_failure_keeps_mic() async throws {
        let id = try meeting(mic: speech, system: speech)
        transcriber.responses = [.success(transcript("Mine.")), .failure(Boom())]
        let text = try written(await makePipeline().process(id))
        #expect(text.contains("**Me** [00:00:00] Mine."))
        #expect(text.contains(MeetingPipeline.systemMissingWarning("boom.")))
    }

    @Test func all_transcription_failing_marks_failed() async throws {
        let id = try meeting(mic: speech, system: speech)
        transcriber.responses = [.failure(Boom()), .failure(Boom())]
        let outcome = await makePipeline().process(id)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        let meta = try store.load(id)
        #expect(meta.state == .failed)
        #expect(meta.failureReason != nil)
    }

    @Test func dont_keep_deletes_audio_without_transcoding() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        _ = await makePipeline(retention: .dontKeep).process(id)
        #expect(transcoder.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: id).micPCM.path))
        #expect(FileManager.default.fileExists(atPath: store.directory(for: id).transcript.path))
    }

    @Test func model_download_stage_comes_first() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        let pipeline = makePipeline(download: true)
        var stages: [MeetingStage] = []
        pipeline.onStage = { stages.append($0) }
        _ = await pipeline.process(id)
        #expect(stages.first == .downloadingModels)
    }

    @Test func regenerate_writes_a_new_file_and_keeps_the_old_one() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        let pipeline = makePipeline()
        guard case .written(let first) = await pipeline.process(id) else {
            Issue.record("first pass failed")
            return
        }
        notes.response = .success(MeetingNotes(
            title: "Better title", summary: "S2.", keyPoints: [], decisions: [], actionItems: [], openQuestions: [], speakerNames: []
        ))
        guard case .written(let second) = await pipeline.regenerateNotes(id) else {
            Issue.record("regenerate failed")
            return
        }
        #expect(second.lastPathComponent == "2026-10-09 1402 Better title (regenerated).md")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(try store.load(id).notesPath == second.path)
    }
}
