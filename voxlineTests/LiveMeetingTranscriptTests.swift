// voxlineTests/LiveMeetingTranscriptTests.swift
import Foundation
import Testing
@testable import voxline

@MainActor
@Suite struct LiveMeetingTranscriptTests {

    private let engine = FakeTranscriptionEngine(id: .apple, metricsID: "apple:test")

    private func settle() async { for _ in 0..<10 { await Task.yield() } }

    private func started(_ tracks: Set<MeetingRecorder.Track> = [.mic, .system]) async -> LiveMeetingTranscript {
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: tracks)
        await live.startTask?.value
        return live
    }

    @Test func opens_one_session_per_track_with_no_hints() async {
        let live = await started()
        #expect(engine.sessions.count == 2)
        #expect(engine.openedConfigs == [SessionConfig(), SessionConfig()])
        #expect(live.availability == .listening)
        #expect(live.showsLabels)
    }

    @Test func mic_only_hides_labels() async {
        let live = await started([.mic])
        #expect(engine.sessions.count == 1)
        #expect(!live.showsLabels)
    }

    @Test func samples_reach_the_matching_session() async {
        let live = await started()
        live.samples([0.1, 0.2], track: .mic)
        live.samples([0.3], track: .system)
        #expect(engine.sessions[0].appended == [[0.1, 0.2]])
        #expect(engine.sessions[1].appended == [[0.3]])
    }

    @Test func samples_before_open_are_dropped() async {
        engine.holdsOpen = true
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: [.mic])
        live.samples([0.5], track: .mic)
        engine.releaseOpen()
        await live.startTask?.value
        #expect(engine.sessions[0].appended.isEmpty)
    }

    @Test func partials_update_the_transcript() async {
        let live = await started()
        engine.sessions[0].emit(TranscriptPartial(stable: "Hello.", volatile: ""))
        await settle()
        engine.sessions[1].emit(TranscriptPartial(stable: "", volatile: "Hi th"))
        await settle()
        #expect(live.transcript.lines == [LiveLine(id: 0, track: .mic, text: "Hello.")])
        #expect(live.transcript.volatile == [.system: "Hi th"])
    }

    @Test func lost_track_cancels_only_its_session() async {
        let live = await started()
        live.trackLost(.system)
        await settle()
        #expect(engine.sessions[1].cancelCount == 1)
        #expect(engine.sessions[0].cancelCount == 0)
        #expect(live.availability == .listening)
        live.samples([0.1], track: .system)
        #expect(engine.sessions[1].appended.isEmpty)
    }

    @Test func stop_cancels_every_session_and_keeps_the_transcript() async {
        let live = await started()
        engine.sessions[0].emit(TranscriptPartial(stable: "Keep me."))
        await settle()
        live.stop()
        await settle()
        #expect(engine.sessions.map(\.cancelCount) == [1, 1])
        #expect(live.transcript.lines.map(\.text) == ["Keep me."])
        live.samples([0.1], track: .mic)
        #expect(engine.sessions[0].appended.isEmpty)
    }

    @Test func stop_during_open_cancels_the_late_session() async {
        engine.holdsOpen = true
        let live = LiveMeetingTranscript(engine: engine)
        live.start(tracks: [.mic])
        live.stop()
        engine.releaseOpen()
        await live.startTask?.value
        #expect(engine.sessions.count == 1)
        #expect(engine.sessions[0].cancelCount == 1)
        #expect(live.availability == .preparing)
    }

    @Test func unavailable_engine_is_reported() async {
        engine.readinessValue = .unavailable("No English assets")
        let live = await started()
        #expect(live.availability == .unavailable("No English assets"))
        #expect(engine.sessions.isEmpty)
    }

    @Test func open_failure_is_reported() async {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        engine.openError = Boom()
        let live = await started()
        #expect(live.availability == .unavailable("boom"))
    }

    @Test func needs_preparation_prepares_first() async {
        engine.readinessValue = .needsPreparation(downloadMB: nil)
        let live = await started([.mic])
        #expect(engine.prepareCount == 1)
        #expect(live.availability == .listening)
    }

    @Test func last_session_ending_on_its_own_is_unavailable() async {
        let live = await started([.mic])
        engine.sessions[0].cancel()
        await settle()
        #expect(live.availability == .unavailable("Apple Speech stopped"))
    }

    @Test func start_is_idempotent() async {
        let live = await started([.mic])
        live.start(tracks: [.mic, .system])
        await live.startTask?.value
        #expect(engine.sessions.count == 1)
    }
}
