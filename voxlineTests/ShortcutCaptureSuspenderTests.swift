import Testing
@testable import voxline

@Suite @MainActor struct ShortcutCaptureSuspenderTests {

    @MainActor
    final class Calls {
        var log: [String] = []
    }

    private func make(_ state: AppState, _ calls: Calls) -> ShortcutCaptureSuspender {
        ShortcutCaptureSuspender(
            state: state,
            suspend: { calls.log.append("suspend") },
            resume: { calls.log.append("resume") }
        )
    }

    private func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() {
            await Task.yield()
        }
    }

    @Test func idle_depth_calls_nothing() {
        let state = AppState()
        let calls = Calls()
        let suspender = make(state, calls)
        #expect(calls.log.isEmpty)
        #expect(!suspender.isSuspended)
    }

    @Test func starting_a_capture_suspends_and_ending_it_resumes() async {
        let state = AppState()
        let calls = Calls()
        let suspender = make(state, calls)

        state.beginShortcutCapture()
        await settle { calls.log == ["suspend"] }
        #expect(calls.log == ["suspend"])
        #expect(suspender.isSuspended)

        state.endShortcutCapture()
        await settle { calls.log == ["suspend", "resume"] }
        #expect(calls.log == ["suspend", "resume"])
        #expect(!suspender.isSuspended)
    }

    @Test func nested_captures_suspend_once_and_resume_at_zero() {
        let state = AppState()
        let calls = Calls()
        let suspender = make(state, calls)

        state.beginShortcutCapture()
        suspender.sync()
        state.beginShortcutCapture()
        suspender.sync()
        state.endShortcutCapture()
        suspender.sync()
        #expect(calls.log == ["suspend"])

        state.endShortcutCapture()
        suspender.sync()
        #expect(calls.log == ["suspend", "resume"])
    }

    @Test func a_capture_already_open_suspends_at_creation() {
        let state = AppState()
        state.beginShortcutCapture()
        let calls = Calls()
        let suspender = make(state, calls)
        #expect(calls.log == ["suspend"])
        #expect(suspender.isSuspended)
    }

    @Test func a_real_monitor_is_suspended_while_capturing() async {
        let state = AppState()
        let monitor = HotkeyMonitor(heldNow: { [] }, tapFactory: { _, _ in nil })
        let suspender = ShortcutCaptureSuspender(
            state: state,
            suspend: { monitor.suspend() },
            resume: { monitor.resume() }
        )

        state.beginShortcutCapture()
        await settle { monitor.isSuspended }
        #expect(monitor.isSuspended)

        state.endShortcutCapture()
        await settle { !monitor.isSuspended }
        #expect(!monitor.isSuspended)
        withExtendedLifetime(suspender) {}
    }
}
