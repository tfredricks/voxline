import Testing
import Foundation
@testable import voxline

@Suite struct MicLevelMonitorTests {

    @Test @MainActor
    func starts_with_zero_level() {
        let monitor = MicLevelMonitor()
        #expect(monitor.level == 0)
    }

    @Test @MainActor
    func stop_resets_level_to_zero() {
        let monitor = MicLevelMonitor()
        monitor._publishLevelForTesting(0.7)
        #expect(monitor.level == 0.7)
        monitor.stop()
        #expect(monitor.level == 0)
    }

    @Test @MainActor
    func ignores_nan_and_clamps_to_unit_range() {
        let monitor = MicLevelMonitor()
        monitor._publishLevelForTesting(.nan)
        #expect(monitor.level == 0)
        monitor._publishLevelForTesting(2.5)
        #expect(monitor.level == 1.0)
        monitor._publishLevelForTesting(-0.3)
        #expect(monitor.level == 0)
    }

    @Test @MainActor
    func double_stop_is_idempotent() {
        let monitor = MicLevelMonitor()
        monitor.stop()
        monitor.stop()  // must not crash
        #expect(monitor.level == 0)
    }
}
