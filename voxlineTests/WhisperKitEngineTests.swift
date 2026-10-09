import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import voxline

private func seg(_ text: String, _ start: Float, _ end: Float) -> TimedText {
    TimedText(text: text, start: start, end: end)
}

@Suite struct WhisperKitEngineTests {

    @Test func split_confirms_all_but_the_last_kept_segments() {
        let segments = [seg("a", 0, 1), seg("b", 1, 2), seg("c", 2, 3), seg("d", 3, 4), seg("e", 4, 5)]
        let split = SegmentConfirmation.split(segments, keepUnconfirmed: 2, after: 0)
        #expect(split.confirmed == Array(segments[0..<3]))
        #expect(split.unconfirmed == Array(segments[3...]))
        #expect(split.newConfirmedEnd == 3)
    }

    @Test func split_with_only_kept_segments_confirms_nothing() {
        let segments = [seg("a", 2, 3), seg("b", 3, 4)]
        let split = SegmentConfirmation.split(segments, keepUnconfirmed: 2, after: 1.5)
        #expect(split.confirmed.isEmpty)
        #expect(split.unconfirmed == segments)
        #expect(split.newConfirmedEnd == 1.5)
    }

    @Test func split_drops_segments_that_end_by_the_confirmed_end() {
        let segments = [seg("old", 0, 1), seg("edge", 1, 2), seg("a", 2, 3), seg("b", 3, 4), seg("c", 4, 5)]
        let split = SegmentConfirmation.split(segments, keepUnconfirmed: 2, after: 2)
        #expect(split.confirmed == [seg("a", 2, 3)])
        #expect(split.unconfirmed == [seg("b", 3, 4), seg("c", 4, 5)])
        #expect(split.newConfirmedEnd == 3)
    }

    @Test func segment_text_strips_whisper_special_tokens() {
        let raw = "<|startoftranscript|><|en|><|transcribe|><|0.00|> The quick brown fox.<|2.40|><|endoftext|>"
        #expect(WhisperSegmentText.clean(raw) == "The quick brown fox.")
        #expect(WhisperSegmentText.clean("  plain words ") == "plain words")
    }
}

@MainActor
@Suite struct WhisperKitEngineSurfaceTests {

    @Test func identity_and_capabilities() {
        let service = TranscriptionService(model: .largeV3Turbo)
        let engine = WhisperKitEngine(service: service)
        #expect(engine.id == .whisperKit)
        #expect(engine.metricsID == "whisperkit:" + WhisperModel.largeV3Turbo.whisperKitIdentifier)
        #expect(engine.capabilities == [.streamingPartials])
        #expect(engine.service === service)
    }

    @Test func metricsID_follows_the_selected_model() {
        let service = TranscriptionService(model: .largeV3Turbo)
        let engine = WhisperKitEngine(service: service)
        service.model = .smallEn
        #expect(engine.metricsID == "whisperkit:" + WhisperModel.smallEn.whisperKitIdentifier)
    }

    @Test func readiness_maps_the_model_cache() async {
        for model in WhisperModel.allCases {
            let engine = WhisperKitEngine(service: TranscriptionService(model: model))
            let expected: EngineReadiness = TranscriptionService.isModelCached(model)
                ? .ready
                : .needsPreparation(downloadMB: model.approxSizeMB)
            #expect(await engine.readiness() == expected)
        }
    }
}

final class FakeWhisperPass: @unchecked Sendable {
    struct Call: Equatable {
        let sampleCount: Int
        let clipStart: Float
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var inFlight = 0
    private var _maxInFlight = 0
    private var _cancelledCount = 0
    private let delay: Duration
    private let respond: @Sendable (Call) throws -> [TimedText]

    init(delay: Duration = .zero, respond: @escaping @Sendable (Call) throws -> [TimedText] = { _ in [] }) {
        self.delay = delay
        self.respond = respond
    }

    var calls: [Call] { lock.withLock { _calls } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }
    var cancelledCount: Int { lock.withLock { _cancelledCount } }

    func run(_ samples: [Float], _ clipStart: Float) async throws -> [TimedText] {
        let call = Call(sampleCount: samples.count, clipStart: clipStart)
        lock.withLock {
            _calls.append(call)
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        defer { lock.withLock { inFlight -= 1 } }
        do {
            try await Task.sleep(for: delay)
        } catch {
            lock.withLock { _cancelledCount += 1 }
            throw error
        }
        return try respond(call)
    }

    func session() -> WhisperKitStreamingSession {
        WhisperKitStreamingSession(transcribe: { try await self.run($0, $1) })
    }
}

private func silence(_ count: Int) -> [Float] {
    [Float](repeating: 0, count: count)
}

private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private struct PassFailed: Error {}

@Suite(.timeLimit(.minutes(1)))
struct WhisperKitStreamingSessionTests {

    @Test func finish_on_an_empty_buffer_returns_empty_without_a_pass() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        #expect(try await session.finish() == "")
        #expect(fake.calls.isEmpty)
        for await _ in session.partials {}
    }

    @Test func no_pass_runs_before_a_second_of_new_audio() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(silence(15_999))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fake.calls.isEmpty)
        session.append(silence(1))
        #expect(await eventually { fake.calls.count == 1 })
        #expect(fake.calls == [.init(sampleCount: 16_000, clipStart: 0)])
        session.cancel()
    }

    @Test func rolling_pass_confirms_all_but_the_last_two_segments_and_finish_resumes_after_them() async throws {
        let fake = FakeWhisperPass { call in
            call.clipStart == 0
                ? [seg(" one", 0, 0.3), seg(" two", 0.3, 0.6), seg(" three", 0.6, 0.9)]
                : [seg(" two", 0.3, 0.6), seg(" three", 0.6, 0.9), seg(" four", 0.9, 1.0)]
        }
        let session = fake.session()
        var partials = session.partials.makeAsyncIterator()
        session.append(silence(16_000))
        let first = await partials.next()
        #expect(first == TranscriptPartial(stable: "one", volatile: "two three"))

        let text = try await session.finish()
        #expect(text == "one two three four")
        #expect(fake.calls == [
            .init(sampleCount: 16_000, clipStart: 0),
            .init(sampleCount: 16_000, clipStart: 0.3),
        ])
        #expect(await partials.next() == nil)
    }

    @Test func passes_never_overlap_and_the_final_pass_covers_the_whole_buffer() async throws {
        let fake = FakeWhisperPass(delay: .milliseconds(250)) { call in
            [seg("x", call.clipStart, call.clipStart + 0.1)]
        }
        let session = fake.session()
        for _ in 0..<12 {
            session.append(silence(16_000))
            try await Task.sleep(for: .milliseconds(60))
        }
        let text = try await session.finish()
        #expect(text == "x")
        #expect(fake.calls.count >= 2)
        #expect(fake.maxInFlight == 1)
        #expect(fake.calls.last?.sampleCount == 12 * 16_000)
    }

    @Test func cancel_makes_finish_throw_and_ends_partials() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(silence(8_000))
        session.cancel()
        session.cancel()
        await #expect(throws: CancellationError.self) { try await session.finish() }
        #expect(fake.calls.isEmpty)
        for await _ in session.partials {}
    }

    @Test func cancel_during_the_final_pass_cancels_it() async throws {
        let fake = FakeWhisperPass(delay: .seconds(30))
        let session = fake.session()
        session.append(silence(8_000))
        let finishing = Task { try await session.finish() }
        #expect(await eventually { fake.calls.count == 1 })
        session.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(await eventually { fake.cancelledCount == 1 })
        for await _ in session.partials {}
    }

    @Test func cancelling_the_finishing_task_cancels_the_session() async throws {
        let fake = FakeWhisperPass(delay: .seconds(30))
        let session = fake.session()
        session.append(silence(8_000))
        let finishing = Task { try await session.finish() }
        #expect(await eventually { fake.calls.count == 1 })
        finishing.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(await eventually { fake.cancelledCount == 1 })
        for await _ in session.partials {}
    }

    @Test func final_pass_error_propagates_and_ends_partials() async throws {
        let fake = FakeWhisperPass { _ in throw PassFailed() }
        let session = fake.session()
        session.append(silence(8_000))
        await #expect(throws: PassFailed.self) { try await session.finish() }
        for await _ in session.partials {}
    }
}

private enum SpokenClip {
    static let sentence = "The quick brown fox jumps over the lazy dog near the river bank"

    static func samples(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "voxline-whisperkit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: url)
        try #require(file.processingFormat.sampleRate == 16_000)
        try #require(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    static func feed(_ samples: [Float], to session: any TranscriptionSession, realtime: Bool) async throws {
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            session.append(Array(samples[start..<min(start + 1_600, samples.count)]))
            if realtime { try await Task.sleep(for: .milliseconds(100)) }
        }
    }
}

@MainActor
@Suite(
    .enabled(
        if: ProcessInfo.processInfo.environment["VOXLINE_ENGINE_TESTS"] == "1",
        "Set VOXLINE_ENGINE_TESTS=1 to run engine integration tests."
    ),
    .enabled("Needs the large-v3 turbo model in the local cache.") {
        await TranscriptionService.isModelCached(.largeV3Turbo)
    },
    .serialized,
    .timeLimit(.minutes(5))
)
struct WhisperKitEngineIntegrationTests {
    private static let engine = WhisperKitEngine(service: TranscriptionService(model: .largeV3Turbo))

    private static func readyEngine() async throws -> WhisperKitEngine {
        let start = ContinuousClock.now
        try await engine.prepare { _ in }
        print("[engine] whisperkit prepare took \(start.duration(to: .now))")
        return engine
    }

    @Test func transcribes_a_spoken_sentence() async throws {
        let samples = try SpokenClip.samples(SpokenClip.sentence)
        let session = try await Self.readyEngine().openSession(SessionConfig())
        try await SpokenClip.feed(samples, to: session, realtime: true)
        let start = ContinuousClock.now
        let text = try await session.finish()
        print("[engine] whisperkit audio=\(Double(samples.count) / 16_000)s finish=\(start.duration(to: .now)) text=\(text)")
        #expect(text.lowercased().contains("quick brown fox"))
    }

    @Test func streams_partials_during_a_long_clip() async throws {
        let samples = try SpokenClip.samples(Array(repeating: SpokenClip.sentence, count: 3).joined(separator: ". "))
        let session = try await Self.readyEngine().openSession(SessionConfig())
        let collector = Task {
            var seen: [TranscriptPartial] = []
            for await partial in session.partials { seen.append(partial) }
            return seen
        }
        try await SpokenClip.feed(samples, to: session, realtime: true)
        let start = ContinuousClock.now
        let text = try await session.finish()
        let finishDuration = start.duration(to: .now)
        let partials = await collector.value
        print("[engine] whisperkit audio=\(Double(samples.count) / 16_000)s finish=\(finishDuration) partials=\(partials.count) last=\(partials.last?.text ?? "-") text=\(text)")
        #expect(!partials.isEmpty)
        #expect(text.lowercased().contains("quick brown fox"))
    }

    @Test func vocabulary_hints_are_ignored() async throws {
        let samples = try SpokenClip.samples(SpokenClip.sentence)
        let engine = try await Self.readyEngine()

        let plain = try await engine.openSession(SessionConfig())
        try await SpokenClip.feed(samples, to: plain, realtime: false)
        let plainText = try await plain.finish()

        let hinted = try await engine.openSession(SessionConfig(vocabularyHints: ["Voxline", "LangGraph", "Argmax"]))
        try await SpokenClip.feed(samples, to: hinted, realtime: false)
        let start = ContinuousClock.now
        let hintedText = try await hinted.finish()
        print("[engine] whisperkit hints audio=\(Double(samples.count) / 16_000)s finish=\(start.duration(to: .now)) text=\(hintedText)")

        #expect(hintedText.lowercased().contains("quick brown fox"))
        #expect(hintedText == plainText)
    }
}
