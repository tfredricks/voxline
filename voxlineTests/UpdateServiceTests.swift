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
