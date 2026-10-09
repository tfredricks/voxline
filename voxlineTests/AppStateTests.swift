import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct AppStateTests {

    @Test func newStateStartsIdle() {
        let state = AppState()
        #expect(state.status == .idle)
    }

    @Test func canTransitionThroughStatusEnum() {
        let state = AppState()
        state.status = .recording
        #expect(state.status == .recording)
        state.status = .thinking
        #expect(state.status == .thinking)
        state.status = .error("mic unavailable")
        #expect(state.status == .error("mic unavailable"))
        state.status = .idle
        #expect(state.status == .idle)
    }

    @Test func newStateHasZeroAudioLevel() {
        #expect(AppState().audioLevel == 0)
    }

    @Test func newStateHasNoTranscript() {
        #expect(AppState().lastTranscript == nil)
    }

    @Test func newStateHasNoRecordingStartedAt() {
        #expect(AppState().recordingStartedAt == nil)
    }

    @Test func canSetDownloadingModelStatus() {
        let state = AppState()
        state.status = .downloadingModel(progress: 0.42)
        #expect(state.status == .downloadingModel(progress: 0.42))
    }

    @Test func downloadingModelDistinctByProgress() {
        #expect(AppStatus.downloadingModel(progress: 0.1) != AppStatus.downloadingModel(progress: 0.2))
    }

    @Test func canSetPreparingModelStatus() {
        let state = AppState()
        state.status = .preparingModel
        #expect(state.status == .preparingModel)
    }

    @Test func blocksRecordingDuringDownloadAndPrepare() {
        #expect(AppStatus.downloadingModel(progress: 0.5).blocksRecording)
        #expect(AppStatus.preparingModel.blocksRecording)
        #expect(!AppStatus.idle.blocksRecording)
        #expect(!AppStatus.recording.blocksRecording)
        #expect(!AppStatus.thinking.blocksRecording)
        #expect(!AppStatus.error("oops").blocksRecording)
        #expect(!AppStatus.permissionsError("oops").blocksRecording)
    }

    @Test func shortcut_capture_depth_starts_at_zero() {
        #expect(AppState().shortcutCaptureDepth == 0)
    }

    @Test func shortcut_capture_depth_counts_nested_captures() {
        let state = AppState()
        state.beginShortcutCapture()
        state.beginShortcutCapture()
        #expect(state.shortcutCaptureDepth == 2)
        state.endShortcutCapture()
        #expect(state.shortcutCaptureDepth == 1)
        state.endShortcutCapture()
        #expect(state.shortcutCaptureDepth == 0)
    }

    @Test func ending_a_capture_never_drops_the_depth_below_zero() {
        let state = AppState()
        state.endShortcutCapture()
        #expect(state.shortcutCaptureDepth == 0)
        state.beginShortcutCapture()
        state.endShortcutCapture()
        state.endShortcutCapture()
        #expect(state.shortcutCaptureDepth == 0)
    }

    @Test func a_recorder_holds_one_level_of_capture() {
        let state = AppState()
        let a = UUID()
        state.beginShortcutCapture(recorder: a)
        state.beginShortcutCapture(recorder: a)
        #expect(state.shortcutCaptureDepth == 1)
        #expect(state.activeShortcutRecorder == a)
        state.endShortcutCapture(recorder: a)
        #expect(state.shortcutCaptureDepth == 0)
        #expect(state.activeShortcutRecorder == nil)
    }

    @Test func starting_another_recorder_takes_the_capture_over() {
        let state = AppState()
        let a = UUID(), b = UUID()
        state.beginShortcutCapture(recorder: a)
        state.beginShortcutCapture(recorder: b)
        #expect(state.shortcutCaptureDepth == 1)
        #expect(state.activeShortcutRecorder == b)

        state.endShortcutCapture(recorder: a)
        #expect(state.shortcutCaptureDepth == 1)
        #expect(state.activeShortcutRecorder == b)

        state.endShortcutCapture(recorder: b)
        #expect(state.shortcutCaptureDepth == 0)
    }

    @Test func stopping_a_recorder_twice_lowers_the_depth_once() {
        let state = AppState()
        let a = UUID()
        state.beginShortcutCapture()
        state.beginShortcutCapture(recorder: a)
        #expect(state.shortcutCaptureDepth == 2)
        state.endShortcutCapture(recorder: a)
        state.endShortcutCapture(recorder: a)
        #expect(state.shortcutCaptureDepth == 1)
    }
}
