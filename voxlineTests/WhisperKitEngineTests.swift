import Testing
import Foundation
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

    @Test func final_pass_keeps_every_confirmed_segment_when_enough_audio_follows() {
        let confirmed = [seg("a", 0, 1), seg("b", 1, 2)]
        let split = SegmentConfirmation.splitForFinalPass(confirmed, audioDuration: 4, minimumSpan: 1.5)
        #expect(split.kept == confirmed)
        #expect(split.released.isEmpty)
    }

    @Test func final_pass_releases_trailing_segments_until_the_minimum_span_follows() {
        let confirmed = [seg("a", 0, 0.5), seg("b", 0.5, 1.0), seg("c", 1.0, 1.6)]
        let split = SegmentConfirmation.splitForFinalPass(confirmed, audioDuration: 2, minimumSpan: 1.5)
        #expect(split.kept == [seg("a", 0, 0.5)])
        #expect(split.released == [seg("b", 0.5, 1.0), seg("c", 1.0, 1.6)])
    }

    @Test func final_pass_can_release_every_confirmed_segment() {
        let confirmed = [seg("a", 0, 0.4), seg("b", 0.4, 0.8)]
        let split = SegmentConfirmation.splitForFinalPass(confirmed, audioDuration: 1.2, minimumSpan: 1.5)
        #expect(split.kept.isEmpty)
        #expect(split.released == confirmed)
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

private final class FakeWhisperPass: @unchecked Sendable {
    struct Call: Equatable {
        let sampleCount: Int
        let clipStart: Float
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var inFlight = 0
    private var _maxInFlight = 0
    private var _cancelledCount = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private let delay: Duration
    private let gated: Bool
    private let cancellationError: (any Error)?
    private let respond: @Sendable (Call) throws -> [TimedText]

    /// `gated` passes ignore cancellation and wait for `release()`.
    /// `cancellationError` replaces the `CancellationError` a cancelled delay throws.
    init(
        delay: Duration = .zero,
        gated: Bool = false,
        cancellationError: (any Error)? = nil,
        respond: @escaping @Sendable (Call) throws -> [TimedText] = { _ in [] }
    ) {
        self.delay = delay
        self.gated = gated
        self.cancellationError = cancellationError
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
        if gated {
            await waitForRelease()
        } else {
            do {
                try await Task.sleep(for: delay)
            } catch {
                lock.withLock { _cancelledCount += 1 }
                throw cancellationError ?? error
            }
        }
        return try respond(call)
    }

    func release() {
        let waiters = lock.withLock {
            released = true
            defer { releaseWaiters.removeAll() }
            return releaseWaiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func session(silencePeak: Float? = nil) -> WhisperKitStreamingSession {
        let transcribe: WhisperKitStreamingSession.Transcribe = { try await self.run($0, $1) }
        guard let silencePeak else { return WhisperKitStreamingSession(transcribe: transcribe) }
        return WhisperKitStreamingSession(silencePeak: silencePeak, transcribe: transcribe)
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock {
                if released { return true }
                releaseWaiters.append(waiter)
                return false
            }
            if resumeNow { waiter.resume() }
        }
    }
}

/// Mimics WhisperKit over a fixed timeline: no decode window starts when
/// 1.0 s or less of audio follows the clip start (`windowClipTime`).
private func whisperLike(_ timeline: [TimedText]) -> @Sendable (FakeWhisperPass.Call) -> [TimedText] {
    { call in
        let duration = Float(call.sampleCount) / 16_000
        guard duration - call.clipStart > 1.0 else { return [] }
        return timeline.filter { $0.end > call.clipStart && $0.start < duration }
    }
}

private let tailTimeline = [
    seg(" one", 0, 0.5), seg(" two", 0.5, 1.0), seg(" three", 1.0, 1.6), seg(" four", 1.6, 1.8), seg(" five", 1.8, 2.0),
]

private func silence(_ count: Int) -> [Float] {
    [Float](repeating: 0, count: count)
}

private func speech(_ count: Int, amplitude: Float = 0.5) -> [Float] {
    (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
}

private let threeWords = [seg(" one", 0, 0.6), seg(" two", 0.6, 1.3), seg(" three", 1.3, 2.0)]
private let fourWords = threeWords + [seg(" four", 2.0, 2.5)]

/// The rolling pass over the first two seconds hears three words; any later
/// pass also hears a fourth.
private let threeThenFour: @Sendable (FakeWhisperPass.Call) -> [TimedText] = { call in
    call.sampleCount == 32_000 ? threeWords : fourWords
}

/// Two seconds of speech, one completed rolling pass over it, then `tail`
/// and `finish()`.
private func finishAfterOnePass(
    then tail: [Float],
    speechAmplitude: Float = 0.5,
    silencePeak: Float? = nil,
    respond: @escaping @Sendable (FakeWhisperPass.Call) throws -> [TimedText] = threeThenFour
) async throws -> (text: String, calls: [FakeWhisperPass.Call]) {
    let fake = FakeWhisperPass(respond: respond)
    let session = fake.session(silencePeak: silencePeak)
    var partials = session.partials.makeAsyncIterator()
    session.append(speech(32_000, amplitude: speechAmplitude))
    _ = await partials.next()
    session.append(tail)
    let text = try await session.finish()
    return (text, fake.calls)
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
        session.append(speech(15_999))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fake.calls.isEmpty)
        session.append(speech(1))
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
        session.append(speech(48_000))
        let first = await partials.next()
        #expect(first == TranscriptPartial(stable: "one", volatile: "two three"))

        session.append(speech(1_600))
        let text = try await session.finish()
        #expect(text == "one two three four")
        #expect(fake.calls == [
            .init(sampleCount: 48_000, clipStart: 0),
            .init(sampleCount: 49_600, clipStart: 0.3),
        ])
        #expect(await partials.next() == nil)
    }

    @Test func passes_never_overlap_and_the_final_pass_covers_the_whole_buffer() async throws {
        let fake = FakeWhisperPass(delay: .milliseconds(250)) { call in
            [seg("x", call.clipStart, call.clipStart + 0.1)]
        }
        let session = fake.session()
        for _ in 0..<12 {
            session.append(speech(16_000))
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

    @Test func cancelled_finish_throws_cancellation_whatever_the_final_pass_throws() async throws {
        let fake = FakeWhisperPass(delay: .seconds(30), cancellationError: PassFailed())
        let session = fake.session()
        session.append(silence(8_000))
        let finishing = Task { try await session.finish() }
        #expect(await eventually { fake.calls.count == 1 })
        session.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
    }

    @Test func cancel_during_a_rolling_pass_ends_partials_and_stops_passes() async throws {
        let fake = FakeWhisperPass(delay: .seconds(30))
        let session = fake.session()
        session.append(silence(16_000))
        #expect(await eventually { fake.calls.count == 1 })
        session.cancel()
        for await _ in session.partials {}
        #expect(await eventually { fake.cancelledCount == 1 })
        session.append(silence(32_000))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.calls.count == 1)
    }

    @Test func cancel_while_finish_waits_on_a_rolling_pass_skips_the_final_pass() async throws {
        let fake = FakeWhisperPass(gated: true) { _ in [seg("late", 0, 0.5)] }
        let session = fake.session()
        session.append(silence(16_000))
        #expect(await eventually { fake.calls.count == 1 })
        let finishing = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(100))
        session.cancel()
        fake.release()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(fake.calls.count == 1)
        for await _ in session.partials {}
    }

    @Test func final_pass_reaches_back_when_little_audio_follows_the_confirmed_end() async throws {
        let fake = FakeWhisperPass(respond: whisperLike(tailTimeline))
        let session = fake.session()
        var partials = session.partials.makeAsyncIterator()
        session.append(speech(32_000))
        let first = await partials.next()
        #expect(first == TranscriptPartial(stable: "one two three", volatile: "four five"))

        session.append(speech(1_600))
        let text = try await session.finish()
        #expect(text.hasSuffix("three four five"))
        #expect(fake.calls.count == 2)
        let finalClipStart = try #require(fake.calls.last?.clipStart)
        #expect(2.1 - finalClipStart > 1.0)
    }

    @Test func re_transcribed_segments_are_not_duplicated_at_the_seam() async throws {
        let fake = FakeWhisperPass(respond: whisperLike(tailTimeline))
        let session = fake.session()
        var partials = session.partials.makeAsyncIterator()
        session.append(speech(32_000))
        _ = await partials.next()

        session.append(speech(1_600))
        let text = try await session.finish()
        #expect(text == "one two three four five")
        for word in ["one", "two", "three", "four", "five"] {
            #expect(text.split(separator: " ").filter { $0 == word }.count == 1)
        }
    }

    @Test func an_empty_final_pass_keeps_the_last_rolling_text() async throws {
        let rolling = whisperLike(tailTimeline)
        let fake = FakeWhisperPass { call in call.clipStart == 0 ? rolling(call) : [] }
        let session = fake.session()
        var partials = session.partials.makeAsyncIterator()
        session.append(speech(32_000))
        _ = await partials.next()

        session.append(speech(1_600))
        let text = try await session.finish()
        #expect(text == "one two three four five")
        #expect(fake.calls.count == 2)
    }

    @Test func early_finalize_skips_final_pass_when_tail_is_silent() async throws {
        let run = try await finishAfterOnePass(then: silence(8_000))
        #expect(run.text == "one two three")
        #expect(run.calls == [.init(sampleCount: 32_000, clipStart: 0)])
    }

    @Test func early_finalize_when_the_pass_covered_the_whole_buffer() async throws {
        let run = try await finishAfterOnePass(then: [])
        #expect(run.text == "one two three")
        #expect(run.calls.count == 1)
    }

    @Test func final_pass_runs_when_tail_has_speech() async throws {
        let run = try await finishAfterOnePass(then: speech(8_000))
        #expect(run.text == "one two three four")
        #expect(run.calls == [
            .init(sampleCount: 32_000, clipStart: 0),
            .init(sampleCount: 40_000, clipStart: 0.6),
        ])
    }

    @Test(arguments: [[TimedText](), [seg(" ", 0, 2.0)]])
    func early_finalize_requires_a_nonempty_pass(rollingSegments: [TimedText]) async throws {
        let run = try await finishAfterOnePass(then: silence(8_000)) { call in
            call.sampleCount == 32_000 ? rollingSegments : fourWords
        }
        #expect(run.text == "one two three four")
        #expect(run.calls == [
            .init(sampleCount: 32_000, clipStart: 0),
            .init(sampleCount: 40_000, clipStart: 0),
        ])
    }

    @Test func tail_is_silent_only_below_the_silence_peak() async throws {
        let quiet = try await finishAfterOnePass(then: speech(8_000, amplitude: 0.0199))
        #expect(quiet.calls.count == 1)
        let atPeak = try await finishAfterOnePass(then: speech(8_000, amplitude: 0.02))
        #expect(atPeak.calls.count == 2)
    }

    @Test func silence_peak_is_injectable() async throws {
        let tail = speech(8_000, amplitude: 0.04)
        let injected = try await finishAfterOnePass(then: tail, speechAmplitude: 0.9, silencePeak: 0.05)
        #expect(injected.text == "one two three")
        #expect(injected.calls.count == 1)
        let byDefault = try await finishAfterOnePass(then: tail, speechAmplitude: 0.9)
        #expect(byDefault.calls.count == 2)
    }

    @Test func quiet_speaker_keeps_a_soft_trailing_word() async throws {
        let run = try await finishAfterOnePass(then: speech(8_000, amplitude: 0.01), speechAmplitude: 0.05)
        #expect(run.text == "one two three four")
        #expect(run.calls.count == 2)
    }

    @Test func quiet_speaker_still_finishes_early_after_silence() async throws {
        let run = try await finishAfterOnePass(then: silence(8_000), speechAmplitude: 0.05)
        #expect(run.text == "one two three")
        #expect(run.calls.count == 1)
    }

    @Test func a_session_never_louder_than_the_silence_peak_never_finishes_early() async throws {
        let run = try await finishAfterOnePass(then: silence(8_000), speechAmplitude: 0.015)
        #expect(run.text == "one two three four")
        #expect(run.calls.count == 2)
    }

    @Test func a_soft_pause_is_not_silence_for_a_quiet_speaker() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(9_600, amplitude: 0.05))
        session.append(speech(5_600, amplitude: 0.01))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fake.calls.isEmpty)
        session.cancel()
    }

    @Test func a_quiet_speakers_real_pause_triggers_a_pass() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(9_600, amplitude: 0.05))
        session.append(silence(5_600))
        #expect(await eventually { fake.calls.count == 1 })
        #expect(fake.calls == [.init(sampleCount: 15_200, clipStart: 0)])
        session.cancel()
    }

    @Test func an_awaited_in_flight_pass_without_segments_falls_back_to_the_final_pass() async throws {
        let fake = FakeWhisperPass(delay: .milliseconds(400)) { call in call.sampleCount == 32_000 ? [] : fourWords }
        let session = fake.session()
        session.append(speech(32_000))
        #expect(await eventually { fake.calls.count == 1 })
        session.append(silence(8_000))
        #expect(try await session.finish() == "one two three four")
        #expect(fake.cancelledCount == 0)
        #expect(fake.calls == [
            .init(sampleCount: 32_000, clipStart: 0),
            .init(sampleCount: 40_000, clipStart: 0),
        ])
    }

    @Test func an_empty_pass_keeps_the_previous_volatile_words() async throws {
        let fake = FakeWhisperPass { call in call.sampleCount == 32_000 ? threeWords : [] }
        let session = fake.session()
        var partials = session.partials.makeAsyncIterator()
        session.append(speech(32_000))
        #expect(await partials.next() == TranscriptPartial(stable: "one", volatile: "two three"))
        session.append(speech(16_000))
        #expect(await partials.next() == TranscriptPartial(stable: "one", volatile: "two three"))

        session.append(speech(1_600))
        #expect(try await session.finish() == "one two three")
        #expect(fake.calls == [
            .init(sampleCount: 32_000, clipStart: 0),
            .init(sampleCount: 48_000, clipStart: 0.6),
            .init(sampleCount: 49_600, clipStart: 0.6),
        ])
    }

    @Test func pause_triggers_a_pass_before_one_second_of_new_audio() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(9_600))
        session.append(silence(5_600))
        #expect(await eventually { fake.calls.count == 1 })
        #expect(fake.calls == [.init(sampleCount: 15_200, clipStart: 0)])
        session.cancel()
    }

    @Test func a_pause_needs_enough_speech_since_the_last_pass() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(480))
        session.append(silence(8_000))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fake.calls.isEmpty)
        session.cancel()
    }

    @Test func a_pause_after_a_twentieth_of_a_second_of_speech_triggers_a_pass() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(800))
        session.append(silence(5_600))
        #expect(await eventually { fake.calls.count == 1 })
        #expect(fake.calls == [.init(sampleCount: 6_400, clipStart: 0)])
        session.cancel()
    }

    @Test func silence_after_a_pause_pass_starts_no_new_pass() async throws {
        let fake = FakeWhisperPass()
        let session = fake.session()
        session.append(speech(9_600))
        session.append(silence(5_600))
        #expect(await eventually { fake.calls.count == 1 })
        session.append(silence(8_000))
        try await Task.sleep(for: .milliseconds(350))
        #expect(fake.calls.count == 1)
        session.cancel()
    }

    @Test func in_flight_pass_covering_speech_is_reused() async throws {
        let fake = FakeWhisperPass(gated: true) { _ in threeWords }
        let session = fake.session()
        session.append(speech(32_000))
        #expect(await eventually { fake.calls.count == 1 })
        session.append(silence(8_000))
        let finishing = Task { try await session.finish() }
        try await Task.sleep(for: .milliseconds(100))
        fake.release()
        #expect(try await finishing.value == "one two three")
        #expect(fake.calls.count == 1)
    }

    @Test func a_reused_in_flight_pass_is_not_cancelled() async throws {
        let fake = FakeWhisperPass(delay: .milliseconds(400)) { _ in threeWords }
        let session = fake.session()
        session.append(speech(32_000))
        #expect(await eventually { fake.calls.count == 1 })
        session.append(silence(8_000))
        #expect(try await session.finish() == "one two three")
        #expect(fake.cancelledCount == 0)
        #expect(fake.calls.count == 1)
    }

    @Test func an_in_flight_pass_followed_by_speech_is_cancelled_for_the_final_pass() async throws {
        let fake = FakeWhisperPass(delay: .milliseconds(400), respond: threeThenFour)
        let session = fake.session()
        session.append(speech(32_000))
        #expect(await eventually { fake.calls.count == 1 })
        session.append(speech(8_000))
        #expect(try await session.finish() == "one two three four")
        #expect(fake.cancelledCount == 1)
        #expect(fake.calls == [
            .init(sampleCount: 32_000, clipStart: 0),
            .init(sampleCount: 40_000, clipStart: 0),
        ])
    }
}

private enum SpokenClip {
    static let sentence = "The quick brown fox jumps over the lazy dog near the river bank"

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
        let samples = try SpeechClipFixture.synthesize(SpokenClip.sentence)
        let session = try await Self.readyEngine().openSession(SessionConfig())
        try await SpokenClip.feed(samples, to: session, realtime: true)
        let start = ContinuousClock.now
        let text = try await session.finish()
        print("[engine] whisperkit audio=\(Double(samples.count) / 16_000)s finish=\(start.duration(to: .now)) text=\(text)")
        #expect(text.lowercased().contains("quick brown fox"))
    }

    @Test func streams_partials_during_a_long_clip() async throws {
        let samples = try SpeechClipFixture.synthesize(Array(repeating: SpokenClip.sentence, count: 3).joined(separator: ". "))
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
        let samples = try SpeechClipFixture.synthesize(SpokenClip.sentence)
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
