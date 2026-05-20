import XCTest
@testable import voxline

@MainActor
final class UpdateServiceTests: XCTestCase {

    /// Sanity: the wrapper can be constructed and exposes the documented
    /// public surface. (We don't drive Sparkle itself in unit tests —
    /// it's exercised end-to-end manually per the spec's testing section.)
    func test_construction_andPublicSurface() {
        let monitor = DictationActivityMonitor()
        let service = UpdateService(dictationActivity: monitor)

        // Toggleable through the wrapper, persists via Sparkle's UserDefaults.
        let original = service.automaticallyChecksForUpdates
        service.automaticallyChecksForUpdates = !original
        XCTAssertEqual(service.automaticallyChecksForUpdates, !original)
        service.automaticallyChecksForUpdates = original // restore

        // hasPendingUpdate defaults to false.
        XCTAssertFalse(service.hasPendingUpdate)

        // checkForUpdates() exists and is callable (does not crash).
        // We don't assert on Sparkle's network behavior here.
        service.checkForUpdates()
    }
}

extension UpdateServiceTests {

    func test_shouldHandleScheduledUpdate_returnsFalse_alwaysGentle() {
        let monitor = DictationActivityMonitor()
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.shouldSparkleHandleScheduledUpdateUI())
    }

    func test_canSurfaceGentleReminder_falseWhileDictating() {
        let monitor = DictationActivityMonitor()
        monitor.observe(status: .recording, at: .now)
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.canSurfaceGentleReminder(now: .now))
    }

    func test_canSurfaceGentleReminder_falseWithinIdleWindow() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertFalse(service.canSurfaceGentleReminder(now: t0.addingTimeInterval(60)))
    }

    func test_canSurfaceGentleReminder_trueAfterIdleWindow() {
        let monitor = DictationActivityMonitor()
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
        monitor.observe(status: .recording, at: t0)
        monitor.observe(status: .idle, at: t0.addingTimeInterval(1))
        let service = UpdateService(dictationActivity: monitor)
        XCTAssertTrue(service.canSurfaceGentleReminder(now: t0.addingTimeInterval(1 + 121)))
    }
}
