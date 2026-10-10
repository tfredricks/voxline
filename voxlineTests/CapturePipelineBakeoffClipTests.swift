import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct CapturePipelineBakeoffClipTests {

    typealias FakeCapture = CapturePipelineTests.FakeCapture
    typealias FakeLLM = CapturePipelineTests.FakeLLM
    typealias FakeSelectionSnapshot = CapturePipelineTests.FakeSelectionSnapshot
    typealias LockedFrontmost = CapturePipelineStreamingTests.LockedFrontmost
    typealias LockedFieldInspector = CapturePipelineStreamingTests.LockedFieldInspector

    struct Clip: Equatable {
        let samples: [Float]
        let reference: String
    }

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let capture: FakeCapture
        let engine: FakeTranscriptionEngine
        let llm: FakeLLM
        let inserter: FakeTextInserter
        let inspector: LockedFieldInspector
        let selection: FakeSelectionSnapshot
        let flag: LockedBox<Bool>
        let clips: LockedBox<[Clip]>
    }

    private func makeHarness(saveClips: Bool, focusedField: FocusedField? = nil) -> Harness {
        let state = AppState()
        let capture = FakeCapture()
        capture.pendingSamples = (0..<8_000).map { 0.05 + Float($0 % 89) / 1_000 }
        let engine = FakeTranscriptionEngine()
        let llm = FakeLLM()
        let inserter = FakeTextInserter()
        let frontmost = LockedFrontmost("com.example.editor")
        let inspector = LockedFieldInspector(focusedField)
        let selection = FakeSelectionSnapshot()
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let flag = LockedBox(saveClips)
        let clips = LockedBox<[Clip]>([])
        let pipe = CapturePipeline(
            state: state,
            capture: capture,
            engines: FakeEngineProvider(engine),
            llm: llm,
            modes: ModeRouter(modes: [
                Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil)
            ]),
            frontmost: frontmost,
            fieldInspector: inspector,
            inserter: inserter,
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(frontmost: frontmost, inspector: inspector),
            selectionSnapshot: selection,
            editContextReader: FakeEditContextReader.needingCopy(),
            llmModelID: { "test-model" },
            commandModelID: { nil },
            vocabulary: { [] },
            skipShortUtterances: { false },
            chords: { .default },
            releaseGate: .released,
            saveBakeoffClips: { flag.read() },
            bakeoffClipSink: { samples, reference in clips.mutate { $0.append(Clip(samples: samples, reference: reference)) } }
        )
        pipe.transcriptFallback = { _ in }
        return Harness(
            pipe: pipe, state: state, capture: capture, engine: engine, llm: llm,
            inserter: inserter, inspector: inspector, selection: selection, flag: flag, clips: clips
        )
    }

    private func dictate(_ h: Harness, kind: CaptureKind = .dictation) async {
        h.pipe.startRecording(kind: kind)
        await h.pipe.finalizeRecording()
    }

    @Test func flag_on_saves_one_clip_after_a_successful_dictation() async {
        let h = makeHarness(saveClips: true)
        h.llm.nextResult = .success("Ship it on Friday.")
        await dictate(h)

        #expect(h.inserter.calls.map(\.text) == ["Ship it on Friday."])
        #expect(h.clips.read() == [Clip(samples: h.capture.pendingSamples, reference: "Ship it on Friday.")])
    }

    @Test func flag_off_saves_nothing() async {
        let h = makeHarness(saveClips: false)
        await dictate(h)

        #expect(h.inserter.calls.map(\.text) == ["cleaned"])
        #expect(h.clips.read().isEmpty)
    }

    @Test func the_flag_is_read_when_recording_starts() async {
        let h = makeHarness(saveClips: true)
        h.pipe.startRecording()
        h.flag.write(false)
        await h.pipe.finalizeRecording()
        #expect(h.clips.read().count == 1)

        h.pipe.startRecording()
        h.flag.write(true)
        await h.pipe.finalizeRecording()
        #expect(h.clips.read().count == 1)
    }

    @Test func commands_save_no_clip() async {
        let h = makeHarness(saveClips: true)
        h.selection.selection = "original text"
        await dictate(h, kind: .command)

        #expect(h.inserter.calls.map(\.text) == ["transformed"])
        #expect(h.clips.read().isEmpty)
    }

    @Test func a_copied_dictation_saves_no_clip() async {
        let h = makeHarness(saveClips: true, focusedField: FocusedField(role: "AXButton", subrole: nil))
        await dictate(h)

        #expect(h.state.toastMessage == "No text field focused — copied")
        #expect(h.clips.read().isEmpty)
    }

    @Test func a_failed_insert_saves_no_clip() async {
        let h = makeHarness(saveClips: true)
        h.inserter.outcomes = [.failed(.accessibilityNotGranted)]
        await dictate(h)

        #expect(h.clips.read().isEmpty)
    }

    @Test func a_retry_saves_no_clip() async {
        let h = makeHarness(saveClips: true)
        await dictate(h)
        #expect(h.clips.read().count == 1)

        await h.pipe.retryLastDictation()
        #expect(h.inserter.calls.map(\.text) == ["cleaned", "cleaned"])
        #expect(h.clips.read().count == 1)
    }

    @Test(arguments: [
        (savesClip: false, cloud: false, retains: false),
        (savesClip: true, cloud: false, retains: true),
        (savesClip: false, cloud: true, retains: true),
        (savesClip: true, cloud: true, retains: true),
    ])
    func router_retains_audio_only_for_a_clip_or_a_cloud_engine(savesClip: Bool, cloud: Bool, retains: Bool) {
        let engine = FakeTranscriptionEngine(capabilities: cloud ? [.streamingPartials, .sendsAudioOffDevice] : [.streamingPartials])
        let live = CapturePipeline.LiveSession(engine: engine, config: SessionConfig(), savesBakeoffClip: savesClip)
        #expect(live.router.retainsAudio == retains)
        #expect(live.savesBakeoffClip == savesClip)
    }
}
