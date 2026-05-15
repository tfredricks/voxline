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

    @Test func respects250Cap() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )

        for i in 0..<260 {
            log.info("entry \(i)", category: "pipeline")
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        #expect(lines.count == 250)
        // First 10 entries (0..<10) must have been evicted; oldest
        // surviving entry is "entry 10".
        #expect(lines.first?.hasSuffix("entry 10") == true)
        #expect(lines.last?.hasSuffix("entry 259") == true)
    }

    @Test func survivesRestart() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let logA = RollingFileLog(
                fileURL: url,
                clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
            )
            for i in 0..<200 {
                logA.info("entry \(i)", category: "pipeline")
            }
        } // logA released here

        let logB = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:57.000Z")
        )
        for i in 200..<205 {
            logB.info("entry \(i)", category: "pipeline")
        }

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        #expect(lines.count == 205)
        #expect(lines.first?.hasSuffix("entry 0") == true)
        #expect(lines.last?.hasSuffix("entry 204") == true)
    }

    @Test func parsesExistingFileOnFirstAppend() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // Pre-seed the file with 300 lines (more than the cap).
        let seed = (0..<300).map { "[seeded] entry \($0)" }.joined(separator: "\n") + "\n"
        try seed.write(to: url, atomically: true, encoding: .utf8)

        let log = RollingFileLog(
            fileURL: url,
            clock: Self.fixedClock("2026-05-14T12:34:56.789Z")
        )
        log.info("fresh entry", category: "pipeline")

        let body = try String(contentsOf: url, encoding: .utf8)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }

        // 300 seeded → trimmed to 250 on first append, then 1 added,
        // then re-trimmed back to 250.
        #expect(lines.count == 250)
        #expect(lines.last?.hasSuffix("fresh entry") == true)
        // Oldest survivor of the 300 seeded was index 51 (0..<300 minus
        // the oldest 50, then minus 1 more when "fresh entry" pushed
        // index 50 out).
        #expect(lines.first?.contains("entry 51") == true)
    }
}
