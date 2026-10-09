import Testing
@testable import voxline

@Suite struct CaptureWarmthTests {

    @Test func keep_warm_window_is_ninety_seconds() {
        #expect(CaptureWarmth.keepWarmDuration == .seconds(90))
    }

    @Test func a_stopped_capture_keeps_the_engine_running_and_schedules_the_stop() {
        var warmth = CaptureWarmth()
        #expect(warmth.handle(.captureStopped) == [.scheduleKeepWarmStop])
        #expect(warmth.keepWarmPending)
    }

    @Test func a_capture_inside_the_window_cancels_the_scheduled_stop() {
        var warmth = CaptureWarmth()
        warmth.handle(.captureStopped)
        #expect(warmth.handle(.captureStarted) == [.cancelKeepWarmStop])
        #expect(!warmth.keepWarmPending)
    }

    @Test func a_capture_with_no_window_has_nothing_to_cancel() {
        var warmth = CaptureWarmth()
        #expect(warmth.handle(.captureStarted) == [])
    }

    @Test func the_window_elapsing_stops_the_engine() {
        var warmth = CaptureWarmth()
        warmth.handle(.captureStopped)
        #expect(warmth.handle(.keepWarmElapsed) == [.stopEngine])
        #expect(!warmth.keepWarmPending)
    }

    @Test func a_cancelled_prewarm_inside_the_window_leaves_the_engine_warm() {
        var warmth = CaptureWarmth()
        warmth.handle(.captureStopped)
        #expect(warmth.handle(.prewarmCancelled) == [])
        #expect(warmth.keepWarmPending)
    }

    @Test func a_cancelled_prewarm_with_no_window_stops_the_engine() {
        var warmth = CaptureWarmth()
        #expect(warmth.handle(.prewarmCancelled) == [.stopEngine])
    }

    @Test func each_stop_opens_a_fresh_window() {
        var warmth = CaptureWarmth()
        warmth.handle(.captureStopped)
        warmth.handle(.captureStarted)
        #expect(warmth.handle(.captureStopped) == [.scheduleKeepWarmStop])
        #expect(warmth.keepWarmPending)
    }
}
