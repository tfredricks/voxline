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

    // MARK: - flashToast

    @Test func flashToast_with_an_action_keeps_it_until_the_toast_clears() async {
        let state = AppState()
        let ran = LockedBox(false)
        state.flashToast("Learned: Argmax", for: .milliseconds(10), action: ToastAction(title: "Undo") { ran.write(true) })
        #expect(state.toastAction?.title == "Undo")
        state.toastAction?.perform()
        #expect(ran.read())
        #expect(await eventually { state.toastMessage == nil && state.toastAction == nil })
    }

    @Test func a_later_toast_without_an_action_drops_the_earlier_action() {
        let state = AppState()
        state.flashToast("Learned: Argmax", for: .seconds(5), action: ToastAction(title: "Undo") {})
        state.flashToast("Copied")
        #expect(state.toastMessage == "Copied")
        #expect(state.toastAction == nil)
    }

    @Test func flashToast_sets_then_clears_after_the_duration() async {
        let state = AppState()
        state.flashToast("Copied", for: .milliseconds(10))
        #expect(state.toastMessage == "Copied")
        #expect(await eventually { state.toastMessage == nil })
    }

    @Test func flashToast_leaves_a_newer_message_alone() async {
        let state = AppState()
        state.flashToast("Copied", for: .milliseconds(10))
        state.toastMessage = "Cancelled"
        try? await Task.sleep(for: .milliseconds(60))
        #expect(state.toastMessage == "Cancelled")
    }

    @Test func flashToast_again_restarts_the_timer() async {
        let state = AppState()
        state.flashToast("Copied", for: .milliseconds(10))
        state.flashToast("Copied", for: .seconds(5))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(state.toastMessage == "Copied")
    }

    @Test func new_state_has_no_recording_kind_or_activity_label() {
        let state = AppState()
        #expect(state.recordingKind == nil)
        #expect(state.activityLabel == nil)
    }

    // MARK: - Retry last dictation

    @Test(arguments: [AppStatus.idle, .error("LLM cleanup failed.")])
    func retry_is_available_with_a_transcript_when_idle_or_failed(status: AppStatus) {
        let state = AppState()
        state.retryTranscript = "hello"
        state.status = status
        #expect(state.canRetryLastDictation)
    }

    /// The menu item stays disabled wherever the pipeline would refuse the
    /// retry: busy, a model being fetched or compiled, or a permissions error.
    @Test(arguments: [AppStatus.recording, .thinking, .downloadingModel(progress: 0.4), .preparingModel, .permissionsError("Grant Accessibility.")])
    func retry_is_unavailable_while_the_pipeline_would_refuse_it(status: AppStatus) {
        let state = AppState()
        state.retryTranscript = "hello"
        state.status = status
        #expect(!state.canRetryLastDictation)
    }

    @Test func retry_is_unavailable_without_a_transcript() {
        let state = AppState()
        #expect(!state.canRetryLastDictation)
        state.status = .error("LLM cleanup failed.")
        #expect(!state.canRetryLastDictation)
    }
}
