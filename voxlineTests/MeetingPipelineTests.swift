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
    private(set) var prepared = false
    var onPrepare: (() -> Void)?
    func prepare() async throws { prepared = true; onPrepare?() }
    func transcribe(_ samples: [Float]) async throws -> TrackTranscript {
        calls += 1
        return try responses.removeFirst().get()
    }
    func release() async { released = true }
}

final class FakeDiarizer: MeetingDiarizing, @unchecked Sendable {
    var response: Result<[SpeakerSegmentText], Error> = .success([])
    private(set) var receivedSegments: [TimedSegment]?
    private(set) var receivedSampleCount: Int?
    private(set) var prepareCount = 0
    func prepare() async throws { prepareCount += 1 }
    func diarize(_ samples: [Float], transcript: TrackTranscript) async throws -> [SpeakerSegmentText] {
        receivedSegments = transcript.segments
        receivedSampleCount = samples.count
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
    var onTranscode: ((URL) -> Void)?
    func transcode(pcm: URL, to m4a: URL) throws {
        calls.append(pcm)
        onTranscode?(pcm)
    }
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
    private let chime: [Float] = [Float](repeating: 0.5, count: 800)
    private let callLine = "Thanks for joining everyone, today we need to settle the pricing for the fourth quarter and agree who sends the revised quote."

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
        transcriber.responses = [.success(transcript("I can do eight.", at: 5)), .success(transcript(callLine))]
        diarizer.response = .success([SpeakerSegmentText(speakerID: 4, start: 0, end: 1, text: callLine)])
        let pipeline = makePipeline()
        var stages: [MeetingStage] = []
        pipeline.onStage = { stages.append($0) }

        let text = try written(await pipeline.process(id))

        #expect(text.hasPrefix("# Pricing sync\n"))
        #expect(text.contains("**Speaker 1** [00:00:00] \(callLine)"))
        #expect(text.contains("**Me** [00:00:05] I can do eight."))
        #expect(stages == [.transcribing(track: 1, of: 2), .transcribing(track: 2, of: 2), .identifyingSpeakers, .writingNotes])
        #expect(diarizer.receivedSegments == transcript(callLine).segments)
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

    @Test func empty_in_person_transcript_skips_diarization() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(TrackTranscript(segments: []))]
        let outcome = await makePipeline().process(id)
        #expect(outcome == .nothingRecorded)
        #expect(diarizer.prepareCount == 0)
        #expect(diarizer.receivedSampleCount == nil)
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
        transcriber.responses = [.success(transcript(callLine))]
        diarizer.response = .failure(Boom())
        let text = try written(await makePipeline().process(id))
        #expect(text.contains("**Them** [00:00:00] \(callLine)"))
        #expect(text.contains(MeetingPipeline.speakersWarning("boom.")))
    }

    @Test func system_transcription_failure_keeps_mic_and_processes_in_person() async throws {
        let id = try meeting(mic: speech, system: speech)
        transcriber.responses = [.success(transcript("Mine.")), .failure(Boom())]
        let text = try written(await makePipeline().process(id))
        #expect(text.contains("**Speaker** [00:00:00] Mine."))
        #expect(!text.contains("**Me**"))
        #expect(diarizer.receivedSampleCount == speech.count)
        #expect(text.contains(MeetingPipeline.systemMissingWarning("boom.")))
    }

    @Test func notification_sound_on_the_system_track_keeps_in_person_speakers() async throws {
        let id = try meeting(mic: speech, system: chime)
        transcriber.responses = [
            .success(TrackTranscript(segments: [
                TimedSegment(start: 0, end: 1, text: "Hello everyone."),
                TimedSegment(start: 4, end: 5, text: "Morning."),
            ])),
            .success(transcript("Ding.")),
        ]
        diarizer.response = .success([
            SpeakerSegmentText(speakerID: 0, start: 0, end: 1, text: "Hello everyone."),
            SpeakerSegmentText(speakerID: 1, start: 4, end: 5, text: "Morning."),
        ])

        let text = try written(await makePipeline().process(id))

        #expect(transcriber.calls == 2)
        #expect(diarizer.receivedSampleCount == speech.count)
        #expect(diarizer.receivedSegments?.map(\.text) == ["Hello everyone.", "Morning."])
        #expect(text.contains("**Speaker 1** [00:00:00] Hello everyone."))
        #expect(text.contains("**Speaker 2** [00:00:04] Morning."))
        #expect(!text.contains("**Me**"))
        #expect(!text.contains("Ding."))
        #expect(!text.contains(MeetingPipeline.silentSystemWarning))
    }

    @Test func saved_transcript_is_reused_without_transcribing() async throws {
        let id = try meeting(mic: nil, system: nil)
        let saved = MeetingTranscriptFile(
            utterances: [MeetingUtterance(speaker: "Speaker 1", start: 3, end: 4, text: "Saved line.")],
            warnings: ["Saved warning."]
        )
        try JSONEncoder().encode(saved).write(to: store.directory(for: id).transcript)
        let pipeline = makePipeline()
        var stages: [MeetingStage] = []
        pipeline.onStage = { stages.append($0) }

        let text = try written(await pipeline.process(id))

        #expect(transcriber.calls == 0)
        #expect(stages == [.writingNotes])
        #expect(text.contains("**Speaker 1** [00:00:03] Saved line."))
        #expect(text.contains("> Saved warning."))
        #expect(try store.load(id).state == .done)
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

    @Test func meeting_is_done_before_its_audio_is_transcoded() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        let store = store
        let seen = LockedBox<[MeetingMeta]>([])
        transcoder.onTranscode = { _ in
            if let meta = try? store.load(id) { seen.mutate { $0.append(meta) } }
        }

        _ = await makePipeline().process(id)

        let meta = try #require(seen.read().first)
        #expect(meta.state == .done)
        #expect(meta.title == "Pricing sync")
        #expect(meta.notesPath?.hasSuffix("Pricing sync.md") == true)
        #expect(transcoder.calls.count == 1)
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
        var stageAtPrepare: MeetingStage?
        transcriber.onPrepare = { stageAtPrepare = stages.last }
        _ = await pipeline.process(id)
        #expect(stages.first == .downloadingModels)
        #expect(stageAtPrepare == .downloadingModels)
        #expect(transcriber.prepared)
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

    @Test func one_track_failing_and_the_other_empty_marks_failed_and_keeps_audio() async throws {
        let id = try meeting(mic: speech, system: speech)
        transcriber.responses = [.success(TrackTranscript(segments: [])), .failure(Boom())]
        let outcome = await makePipeline().process(id)
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(try store.load(id).state == .failed)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: id).systemPCM.path))
    }

    @Test func regenerate_after_a_failed_notes_write_marks_the_meeting_done() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: notesFolder)
        let pipeline = makePipeline()
        guard case .failed = await pipeline.process(id) else {
            Issue.record("expected the notes write to fail")
            return
        }
        #expect(try store.load(id).state == .failed)
        try FileManager.default.removeItem(at: notesFolder)

        guard case .written(let url) = await pipeline.regenerateNotes(id) else {
            Issue.record("regenerate failed")
            return
        }
        let meta = try store.load(id)
        #expect(meta.state == .done)
        #expect(meta.failureReason == nil)
        #expect(meta.notesPath == url.path)
    }

    @Test func regenerate_with_notes_failure_returns_failed_and_changes_nothing() async throws {
        let id = try meeting(mic: speech, system: nil, tap: false)
        transcriber.responses = [.success(transcript("Hello."))]
        let pipeline = makePipeline()
        guard case .written(let first) = await pipeline.process(id) else {
            Issue.record("first pass failed")
            return
        }
        notes.response = .failure(Boom(message: "No API key configured."))
        let outcome = await pipeline.regenerateNotes(id)
        #expect(outcome == .failed("No API key configured."))
        #expect(try store.load(id).notesPath == first.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: notesFolder.path)
        #expect(files.count == 1)
    }
}
