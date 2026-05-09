import Testing
@testable import voxline

@Suite struct AppStateTests {

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
        if case .error(let msg) = state.status {
            #expect(msg == "mic unavailable")
        } else {
            Issue.record("expected .error case, got \(state.status)")
        }
        state.status = .idle
        #expect(state.status == .idle)
    }
}
