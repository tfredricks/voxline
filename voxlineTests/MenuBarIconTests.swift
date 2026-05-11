import Testing
@testable import voxline

@Suite struct MenuBarIconTests {

    @Test func iconForIdle() {
        #expect(MenuBarIcon.symbolName(for: .idle) == "mic")
    }

    @Test func iconForRecording() {
        #expect(MenuBarIcon.symbolName(for: .recording) == "mic.fill")
    }

    @Test func iconForThinking() {
        #expect(MenuBarIcon.symbolName(for: .thinking) == "ellipsis.circle")
    }

    @Test func iconForError() {
        #expect(MenuBarIcon.symbolName(for: .error(category: .pipeline, message: "anything")) == "mic.slash")
    }

    @Test func iconForDownloadingModel() {
        #expect(MenuBarIcon.symbolName(for: .downloadingModel(progress: 0.0)) == "arrow.down.circle")
        #expect(MenuBarIcon.symbolName(for: .downloadingModel(progress: 0.5)) == "arrow.down.circle")
    }

    @Test func iconForPreparingModel() {
        #expect(MenuBarIcon.symbolName(for: .preparingModel) == "gearshape.circle")
    }

    @Test func iconForIdlePaused() {
        #expect(MenuBarIcon.symbolName(for: .idle, paused: true) == "pause.circle")
    }

    @Test func pausedDoesNotOverrideActiveStatus() {
        #expect(MenuBarIcon.symbolName(for: .recording, paused: true) == "mic.fill")
        #expect(MenuBarIcon.symbolName(for: .error(category: .pipeline, message: "x"), paused: true) == "mic.slash")
    }
}
