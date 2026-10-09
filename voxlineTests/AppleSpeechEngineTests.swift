import Testing
import Foundation
import AVFoundation
@testable import voxline

@Suite struct ApplePartialAccumulatorTests {

    @Test func volatile_results_replace_the_tail_and_finals_commit_to_stable() {
        var accumulator = ApplePartialAccumulator()

        #expect(accumulator.apply(text: "I", isFinal: false) == TranscriptPartial(stable: "", volatile: "I"))
        #expect(accumulator.apply(text: "I push", isFinal: false) == TranscriptPartial(stable: "", volatile: "I push"))
        #expect(accumulator.apply(text: "I pushed the", isFinal: true) == TranscriptPartial(stable: "I pushed the", volatile: ""))

        let tail = accumulator.apply(text: " change", isFinal: false)
        #expect(tail == TranscriptPartial(stable: "I pushed the", volatile: " change"))
        #expect(tail.text == "I pushed the change")

        let committed = accumulator.apply(text: " change to", isFinal: true)
        #expect(committed == TranscriptPartial(stable: "I pushed the change to", volatile: ""))
        #expect(accumulator.finalText == "I pushed the change to")
    }

    @Test func segments_concatenate_raw_so_unspaced_scripts_stay_unspaced() {
        var accumulator = ApplePartialAccumulator()
        _ = accumulator.apply(text: "今日は", isFinal: true)
        let committed = accumulator.apply(text: "いい天気です。", isFinal: true)
        #expect(committed.stable == "今日はいい天気です。")
        #expect(accumulator.finalText == "今日はいい天気です。")
    }

    @Test func segment_whitespace_is_kept_until_finish_trims() {
        var accumulator = ApplePartialAccumulator()
        _ = accumulator.apply(text: " Hello", isFinal: true)
        _ = accumulator.apply(text: " world. ", isFinal: true)
        #expect(accumulator.finalText == " Hello world. ")
    }

    @Test func final_text_ignores_an_uncommitted_volatile_tail() {
        var accumulator = ApplePartialAccumulator()
        _ = accumulator.apply(text: "Hello", isFinal: true)
        _ = accumulator.apply(text: "wor", isFinal: false)
        #expect(accumulator.finalText == "Hello")
    }
}

@MainActor
@Suite struct AppleSpeechEngineTests {

    @Test func identity_before_locale_resolution() {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        #expect(engine.id == .apple)
        #expect(engine.capabilities == [.streamingPartials])
        #expect(engine.metricsID == "apple:unresolved")
    }
}

@MainActor
@Suite(
    .tags(.integration),
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["VOXLINE_ENGINE_TESTS"] == "1",
        "Set VOXLINE_ENGINE_TESTS=1 to run engine integration tests."
    )
)
struct AppleSpeechEngineIntegrationTests {

    private static let phrase = "The quick brown fox jumps over the lazy dog near the river bank"
    private static let pausedPhrase = "The quick brown fox jumps over the lazy dog. [[slnc 1500]] "
        + "Then it ran across the field near the river bank. [[slnc 1500]] "
        + "Finally it slept under a tall oak tree."
    private static let chunkSize = 1_600

    private enum FixtureError: Error {
        case sayFailed(Int32)
        case unreadable
    }

    @Test(.timeLimit(.minutes(2)))
    func transcribes_synthesized_speech_with_partials() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        #expect(await engine.readiness() == .ready)
        #expect(engine.metricsID.hasPrefix("apple:en"))

        let samples = try Self.synthesize(Self.phrase)
        let session = try await engine.openSession(SessionConfig())
        let observed = LockedBox<[TranscriptPartial]>([])
        let collector = Task {
            for await partial in session.partials where !partial.isEmpty {
                observed.mutate { $0.append(partial) }
            }
        }

        try await Self.feed(samples, to: session)
        let text = try await session.finish()
        let partialsBeforeFinishReturned = observed.read().count
        await collector.value

        #expect(text.lowercased().contains("quick brown fox"), "final text: \(text)")
        #expect(text.lowercased().contains("lazy dog"), "final text: \(text)")
        #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(partialsBeforeFinishReturned > 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func multi_segment_output_keeps_apple_spacing() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let samples = try Self.synthesize(Self.pausedPhrase)
        let session = try await engine.openSession(SessionConfig())
        let stables = LockedBox<[String]>([])
        let collector = Task {
            for await partial in session.partials where !partial.stable.isEmpty {
                stables.mutate { if $0.last != partial.stable { $0.append(partial.stable) } }
            }
        }

        try await Self.feed(samples, to: session)
        let text = try await session.finish()
        await collector.value

        let lowered = text.lowercased()
        #expect(stables.read().count >= 2, "expected several final segments; saw \(stables.read())")
        #expect(!text.contains("  "), "final text: \(text)")
        #expect(lowered.contains(try Regex("lazy dog[.,]? then")), "final text: \(text)")
        #expect(lowered.contains(try Regex("bank[.,]? finally")), "final text: \(text)")
        #expect(text == text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test(.timeLimit(.minutes(2)))
    func cancel_makes_finish_throw_cancellation() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let samples = try Self.synthesize(Self.phrase)
        let session = try await engine.openSession(SessionConfig())
        let drained = Task { for await _ in session.partials {} }

        try await Self.feed(Array(samples.prefix(samples.count / 2)), to: session)
        session.cancel()
        session.cancel()
        session.append(Array(samples.suffix(samples.count / 2)))

        await #expect(throws: CancellationError.self) { try await session.finish() }
        await drained.value
    }

    @Test(.timeLimit(.minutes(2)))
    func cancelling_the_task_awaiting_finish_cancels_the_session() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let samples = try Self.synthesize(Self.phrase)
        let session = try await engine.openSession(SessionConfig(vocabularyHints: ["Voxline"]))
        let drained = Task { for await _ in session.partials {} }
        try await Self.feed(samples, to: session)

        let finishing = Task { try await session.finish() }
        finishing.cancel()

        await #expect(throws: CancellationError.self) { try await finishing.value }
        await #expect(throws: CancellationError.self) { try await session.finish() }
        await drained.value
    }

    @Test(.timeLimit(.minutes(2)))
    func cancel_while_finish_is_in_flight_throws_cancellation() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let samples = try Self.synthesize(Self.pausedPhrase)
        let session = try await engine.openSession(SessionConfig())
        let drained = Task { for await _ in session.partials {} }
        var offset = 0
        while offset < samples.count {
            let end = min(offset + Self.chunkSize, samples.count)
            session.append(Array(samples[offset..<end]))
            offset = end
        }

        let entered = LockedBox(false)
        let finishing = Task.detached {
            entered.write(true)
            return try await session.finish()
        }
        while !entered.read() { try await Task.sleep(for: .milliseconds(1)) }
        try await Task.sleep(for: .milliseconds(20))
        session.cancel()

        await #expect(throws: CancellationError.self) { try await finishing.value }
        await drained.value
    }

    private static func feed(_ samples: [Float], to session: any TranscriptionSession) async throws {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + chunkSize, samples.count)
            session.append(Array(samples[offset..<end]))
            offset = end
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxline-apple-speech-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else { throw FixtureError.sayFailed(say.terminationStatus) }

        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw FixtureError.unreadable
        }
        try file.read(into: buffer)
        guard file.processingFormat.sampleRate == 16_000,
              file.processingFormat.channelCount == 1,
              let channel = buffer.floatChannelData?[0] else {
            throw FixtureError.unreadable
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
