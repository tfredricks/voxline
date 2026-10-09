import Testing
@testable import voxline

@Suite struct HomeStatusTests {
    @Test func idle_reads_ready_or_paused() {
        #expect(HomeStatus.text(for: .idle, paused: false, meetingRecording: false) == "Ready")
        #expect(HomeStatus.text(for: .idle, paused: true, meetingRecording: false) == "Paused")
    }

    @Test func meeting_recording_while_idle() {
        #expect(HomeStatus.text(for: .idle, paused: false, meetingRecording: true) == "Recording a meeting")
    }

    @Test func active_states() {
        #expect(HomeStatus.text(for: .recording, paused: false, meetingRecording: false) == "Recording")
        #expect(HomeStatus.text(for: .thinking, paused: false, meetingRecording: false) == "Processing")
        #expect(HomeStatus.text(for: .downloadingModel(progress: 0.42), paused: false, meetingRecording: false) == "Downloading model — 42%")
        #expect(HomeStatus.text(for: .preparingModel, paused: false, meetingRecording: false) == "Preparing model…")
    }

    @Test func errors_show_their_message() {
        #expect(HomeStatus.text(for: .error("Mic unplugged"), paused: false, meetingRecording: false) == "Mic unplugged")
        #expect(HomeStatus.text(for: .permissionsError("Needs Accessibility"), paused: true, meetingRecording: false) == "Needs Accessibility")
    }
}
