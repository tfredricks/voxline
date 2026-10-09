import Testing
@testable import voxline

@Suite struct MenuBarIconTests {

    @Test func permissionsError_hasDistinctWarningBadge() {
        // A permissions problem is user-fixable and must be visually distinct
        // from a generic mic/pipeline error so the user knows to act.
        let permissions = MenuBarIcon.symbolName(for: .permissionsError("nope"))
        let genericError = MenuBarIcon.symbolName(for: .error("boom"))
        #expect(permissions == "exclamationmark.triangle.fill")
        #expect(genericError == "mic.slash")
        #expect(permissions != genericError)
    }

    @Test func statusSymbols_mapAsExpected() {
        #expect(MenuBarIcon.symbolName(for: .recording) == "mic.fill")
        #expect(MenuBarIcon.symbolName(for: .thinking) == "ellipsis.circle")
        #expect(MenuBarIcon.symbolName(for: .idle) == "mic")
        #expect(MenuBarIcon.symbolName(for: .idle, paused: true) == "pause.circle")
    }

    @Test func idle_with_meeting_recording_shows_record_symbol() {
        #expect(MenuBarIcon.symbolName(for: .idle, meetingRecording: true) == "record.circle")
        #expect(MenuBarIcon.symbolName(for: .recording, meetingRecording: true) == "mic.fill")
        #expect(MenuBarIcon.symbolName(for: .idle, paused: true, meetingRecording: true) == "record.circle")
    }
}
