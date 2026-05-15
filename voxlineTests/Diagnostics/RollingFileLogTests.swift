import Testing
import Foundation
@testable import voxline

@Suite struct RollingFileLogTests {

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "rfl-\(UUID().uuidString).log")
    }

    private static func fixedClock(_ iso: String) -> () -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: iso)!
        return { d }
    }

    @Test func appendsFormattedLine() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        log.info("Dictation finished", category: "pipeline")

        let body = try String(contentsOf: url, encoding: .utf8)
        // Format: [yyyy-MM-dd HH:mm:ss.SSS] [INFO] [pipeline] message
        // Timestamp is rendered in local time, so we assert structure
        // around the level/category/message fields rather than the exact
        // wall-clock string (which depends on the test machine's TZ).
        #expect(body.hasSuffix("[INFO] [pipeline] Dictation finished\n"))
        #expect(body.split(separator: "\n").count == 1)
    }
}
