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
        #expect(MenuBarIcon.symbolName(for: .error("anything")) == "mic.slash")
    }
}
