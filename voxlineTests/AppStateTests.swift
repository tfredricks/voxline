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
}
