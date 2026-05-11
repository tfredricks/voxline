import Testing
import Foundation
@testable import voxline

@Suite struct CaptureDeadlineTests {

    @Test func remaining_decreases_as_time_passes() async throws {
        let d = CaptureDeadline(totalMilliseconds: 200)
        let before = d.remainingMilliseconds()
        try await Task.sleep(nanoseconds: 50_000_000)   // 50ms
        let after = d.remainingMilliseconds()
        #expect(before > after)
        #expect(after <= 200)
    }

    @Test func isExpired_is_false_before_deadline_and_true_after() async throws {
        let d = CaptureDeadline(totalMilliseconds: 50)
        #expect(!d.isExpired)
        try await Task.sleep(nanoseconds: 80_000_000)   // 80ms
        #expect(d.isExpired)
    }

    @Test func remainingMilliseconds_returns_zero_when_expired() async throws {
        let d = CaptureDeadline(totalMilliseconds: 20)
        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(d.remainingMilliseconds() == 0)
    }

    @Test func elapsedMilliseconds_reflects_wall_clock() async throws {
        let d = CaptureDeadline(totalMilliseconds: 1_000)
        try await Task.sleep(nanoseconds: 30_000_000)
        let elapsed = d.elapsedMilliseconds()
        #expect(elapsed >= 25 && elapsed <= 200)  // generous upper bound for CI
    }
}
