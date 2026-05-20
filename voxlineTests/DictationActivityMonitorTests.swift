import XCTest
@testable import voxline

@MainActor
final class DictationActivityMonitorTests: XCTestCase {

    func test_idleStatus_isNotActive_andDoesNotDefer() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .idle, at: now)
        XCTAssertFalse(monitor.isActive)
        XCTAssertNil(monitor.lastActivityAt)
        XCTAssertFalse(monitor.isWithinDeferralWindow(now: now))
    }

    func test_recordingStatus_isActive() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: now)
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.isWithinDeferralWindow(now: now))
    }

    func test_thinkingStatus_isActive() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .thinking, at: now)
        XCTAssertTrue(monitor.isActive)
        XCTAssertTrue(monitor.isWithinDeferralWindow(now: now))
    }

    func test_recordingThenIdle_setsLastActivityAt() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let t1 = t0.addingTimeInterval(5)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t1)
        XCTAssertFalse(monitor.isActive)
        XCTAssertEqual(monitor.lastActivityAt, t1)
    }

    func test_deferralWindowBoundaries() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))

        // 119s after the .idle transition: still deferring.
        XCTAssertTrue(monitor.isWithinDeferralWindow(
            now: t0.addingTimeInterval(1 + 119)
        ))
        // Exactly 120s: predicate is strict-less-than, so the window has just closed.
        XCTAssertFalse(monitor.isWithinDeferralWindow(
            now: t0.addingTimeInterval(1 + 120)
        ))
        // 121s: still outside.
        XCTAssertFalse(monitor.isWithinDeferralWindow(
            now: t0.addingTimeInterval(1 + 121)
        ))
    }

    func test_deferralWindow_with_nilLastActivity_isFalse() {
        let monitor = DictationActivityMonitor()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        XCTAssertFalse(monitor.isWithinDeferralWindow(now: now))
    }
}
