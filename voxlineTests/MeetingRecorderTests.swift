import Foundation
import Testing
@testable import voxline

final class FakeMeetingSource: MeetingAudioSource {
    var startErrors: [MeetingAudioSourceError] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var onFailure: (@Sendable (MeetingAudioSourceError) -> Void)?

    func start(onSamples: @escaping @Sendable ([Float]) -> Void, onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void) throws {
        startCount += 1
        if !startErrors.isEmpty { throw startErrors.removeFirst() }
        self.onSamples = onSamples
        self.onFailure = onFailure
    }

    func stop() { stopCount += 1 }
    func emit(_ samples: [Float]) { onSamples?(samples) }
    func fail() { onFailure?(.configurationChanged) }
}

@MainActor
@Suite struct MeetingRecorderTests {

    private let clock = ManualClock()
    private let mic = FakeMeetingSource()
    private let system = FakeMeetingSource()
    private let directory: MeetingDirectory

    init() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = MeetingDirectory(url: url)
    }

    /// Lets main-actor tasks spawned by the last call run (and register
    /// their sleeps) before the clock moves.
    private func settle() async { await clock.advance(by: .zero) }

    private func makeRecorder(cap: Duration = MeetingRecorder.defaultCap, system: FakeMeetingSource? = nil) -> MeetingRecorder {
        let clock = clock
        return MeetingRecorder(
            mic: mic, system: system ?? self.system, directory: directory, cap: cap,
            sleep: { @MainActor in try await clock.sleep($0) },
            clock: { clock.now }
        )
    }

    @Test func writes_both_tracks_and_stops_sources() async throws {
        let recorder = makeRecorder()
        var stopped: [MeetingStopReason] = []
        recorder.onStopped = { stopped.append($0) }
        try recorder.start()
        #expect(recorder.systemTapStarted)
        mic.emit([0.5, 0.5])
        system.emit([0.25])
        recorder.stop()
        recorder.stop()
        #expect(stopped == [.user])
        #expect(mic.stopCount >= 1 && system.stopCount >= 1)
        #expect(PCMTrackReader.sampleCount(at: directory.micPCM) == 2)
        #expect(PCMTrackReader.sampleCount(at: directory.systemPCM) == 1)
    }

    @Test func system_start_failure_records_mic_only() throws {
        system.startErrors = [.unavailable("no tap")]
        let recorder = makeRecorder()
        try recorder.start()
        #expect(!recorder.systemTapStarted)
        recorder.stop()
    }

    @Test func mic_start_failure_throws() {
        mic.startErrors = [.unavailable("no mic")]
        let recorder = makeRecorder()
        #expect(throws: MeetingAudioSourceError.self) { try recorder.start() }
    }

    @Test func warns_five_minutes_before_the_cap_then_stops_at_it() async throws {
        let recorder = makeRecorder()
        var warned = 0
        var stopped: [MeetingStopReason] = []
        recorder.onWarning = { warned += 1 }
        recorder.onStopped = { stopped.append($0) }
        try recorder.start()
        await settle()
        await clock.advance(by: .seconds(3_299))
        #expect(warned == 0)
        await clock.advance(by: .seconds(1))
        #expect(warned == 1)
        #expect(stopped.isEmpty)
        await clock.advance(by: .seconds(300))
        #expect(stopped == [.cap])
    }

    @Test func short_cap_warns_at_half() {
        #expect(MeetingRecorder.warningLead(forCap: .seconds(120)) == .seconds(60))
        #expect(MeetingRecorder.warningLead(forCap: .seconds(3_600)) == .seconds(300))
    }

    @Test func failure_restarts_source_with_silence_padding() async throws {
        let recorder = makeRecorder()
        try recorder.start()
        await settle()
        mic.emit([Float](repeating: 0.1, count: 16_000))
        await clock.advance(by: .seconds(2))
        mic.fail()
        await settle()
        await clock.advance(by: .milliseconds(500))
        #expect(mic.startCount == 2)
        recorder.stop()
        #expect(PCMTrackReader.sampleCount(at: directory.micPCM) == 40_000)
    }

    @Test func fourth_consecutive_failure_stops_recording() async throws {
        let recorder = makeRecorder()
        var stopped: [MeetingStopReason] = []
        recorder.onStopped = { stopped.append($0) }
        try recorder.start()
        await settle()
        for _ in 0..<3 {
            mic.fail()
            await settle()
            await clock.advance(by: .seconds(1))
        }
        #expect(stopped.isEmpty)
        mic.fail()
        await settle()
        guard case .failed = stopped.first else {
            Issue.record("expected .failed, got \(stopped)")
            return
        }
    }

    @Test func failures_far_apart_do_not_accumulate() async throws {
        let recorder = makeRecorder()
        var stopped: [MeetingStopReason] = []
        recorder.onStopped = { stopped.append($0) }
        try recorder.start()
        await settle()
        for _ in 0..<6 {
            mic.fail()
            await settle()
            await clock.advance(by: .seconds(31))
        }
        #expect(stopped.isEmpty)
        recorder.stop()
    }

    @Test func restart_that_throws_counts_as_a_failure() async throws {
        let recorder = makeRecorder()
        var stopped: [MeetingStopReason] = []
        recorder.onStopped = { stopped.append($0) }
        try recorder.start()
        await settle()
        mic.startErrors = [.unavailable("x"), .unavailable("x"), .unavailable("x")]
        mic.fail()
        await settle()
        await clock.advance(by: .seconds(5))
        guard case .failed = stopped.first else {
            Issue.record("expected .failed, got \(stopped)")
            return
        }
    }

    @Test func late_system_batch_is_aligned_to_wall_clock() async throws {
        let recorder = makeRecorder()
        try recorder.start()
        await settle()
        await clock.advance(by: .seconds(3))
        system.emit([Float](repeating: 0.1, count: 1_600))
        recorder.stop()
        #expect(PCMTrackReader.sampleCount(at: directory.systemPCM) == 48_000)
    }

    @Test func small_lag_is_not_padded() async throws {
        let recorder = makeRecorder()
        try recorder.start()
        await settle()
        await clock.advance(by: .milliseconds(300))
        system.emit([Float](repeating: 0.1, count: 100))
        recorder.stop()
        #expect(PCMTrackReader.sampleCount(at: directory.systemPCM) == 100)
    }
}
