import Foundation
import Testing
@testable import voxline

@MainActor
final class FakeLearning: LearningObserving {
    private(set) var captureStarts = 0
    private(set) var inserted: [InsertedDictation] = []

    func captureWillStart() { captureStarts += 1 }
    func didInsert(_ dictation: InsertedDictation) { inserted.append(dictation) }
}

@Suite(.timeLimit(.minutes(1))) @MainActor struct CapturePipelineLearningTests {

    static let slack = "com.tinyspeck.slackmacgap"

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let engine: FakeTranscriptionEngine
        let llm: CapturePipelineTests.FakeLLM
        let inserter: FakeTextInserter
        let learning: FakeLearning
    }

    private func makeHarness(vocabulary: LockedBox<[String]> = LockedBox([])) -> Harness {
        let state = AppState()
        let engine = FakeTranscriptionEngine()
        let llm = CapturePipelineTests.FakeLLM()
        let inserter = FakeTextInserter()
        let learning = FakeLearning()
        let frontmost = CapturePipelineTests.FakeFrontmost()
        frontmost.bundleID = Self.slack
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let pipe = CapturePipeline(
            state: state,
            capture: CapturePipelineTests.FakeCapture(),
            engines: FakeEngineProvider(engine),
            llm: llm,
            modes: ModeRouter(modes: [
                Mode(bundleID: Self.slack, displayName: "Slack", prompt: "slack-prompt", model: nil, temperature: nil, category: .chat),
                Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general),
            ]),
            frontmost: frontmost,
            fieldInspector: CapturePipelineTests.FakeFieldInspector(),
            inserter: inserter,
            historyStore: DictationHistoryStore(defaults: defaults),
            contextCapture: FakeContextCapture(),
            selectionSnapshot: CapturePipelineTests.FakeSelectionSnapshot(),
            editContextReader: FakeEditContextReader(.success(EditContext(
                isEditable: true, element: nil, field: nil, selection: nil, cursor: nil, needsCopyFallback: false
            ))),
            llmModelID: { "test-model" },
            vocabulary: { vocabulary.read() },
            skipShortUtterances: { false },
            chords: { .default },
            releaseGate: .released,
            learning: learning
        )
        pipe.transcriptFallback = { _ in }
        return Harness(pipe: pipe, state: state, engine: engine, llm: llm, inserter: inserter, learning: learning)
    }

    private func dictate(_ h: Harness, transcript: String = "hello world") async {
        let session = FakeTranscriptionSession()
        session.finishResult = .success(transcript)
        h.engine.nextSessions = [session]
        h.pipe.startRecording()
        await h.pipe.finalizeRecording()
    }

    @Test func an_inserted_dictation_is_handed_to_learning() async {
        let h = makeHarness()
        await dictate(h)
        #expect(h.learning.captureStarts == 1)
        #expect(h.learning.inserted == [InsertedDictation(text: "cleaned", bundleID: Self.slack, category: .chat)])
    }

    @Test func nothing_is_handed_over_when_the_text_did_not_land() async {
        let notInserted = makeHarness()
        notInserted.inserter.outcomes = [.notInserted(.focusMoved)]
        await dictate(notInserted)
        #expect(notInserted.learning.inserted.isEmpty)

        let failedCleanup = makeHarness()
        failedCleanup.llm.nextResult = .failure(LLMError.rateLimited)
        await dictate(failedCleanup)
        #expect(failedCleanup.learning.inserted.isEmpty)
    }

    @Test func retries_and_presets_end_the_open_window_but_presets_are_not_observed() async {
        let h = makeHarness()
        _ = h.pipe.beginRun()
        #expect(h.learning.captureStarts == 1)
        await h.pipe.runPreset(PresetShortcut.defaults[0])
        #expect(h.learning.captureStarts == 2)
        #expect(h.learning.inserted.isEmpty)
    }

    @Test func a_retried_dictation_is_handed_to_learning_too() async {
        let h = makeHarness()
        await dictate(h)
        await h.pipe.retryLastDictation()
        #expect(h.learning.captureStarts == 2)
        #expect(h.learning.inserted.count == 2)
        #expect(h.learning.inserted.last == InsertedDictation(text: "cleaned", bundleID: Self.slack, category: .chat))
    }

    @Test func a_command_recording_is_not_observed() async {
        let h = makeHarness()
        h.llm.commandResults = [.success(CommandResult(action: .insert, text: "drafted"))]
        let session = FakeTranscriptionSession()
        session.finishResult = .success("draft a reply")
        h.engine.nextSessions = [session]
        h.pipe.startRecording(kind: .command)
        await h.pipe.finalizeRecording()
        #expect(h.llm.commandRequests.count == 1)
        #expect(h.learning.captureStarts == 1)
        #expect(h.learning.inserted.isEmpty)
    }

    @Test func cleanup_sees_the_vocabulary_as_it_is_at_cleanup_time() async {
        let vocabulary = LockedBox<[String]>([])
        let h = makeHarness(vocabulary: vocabulary)
        let session = FakeTranscriptionSession()
        session.finishResult = .success("ask Cooper Nettis")
        h.engine.nextSessions = [session]
        h.pipe.startRecording()
        vocabulary.write(["Kubernetes"])
        await h.pipe.finalizeRecording()
        #expect(h.llm.calls.first?.context.customVocabulary == ["Kubernetes"])
    }
}
