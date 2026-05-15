import Testing
import Foundation
@testable import voxline

@Suite struct CategoryLogTests {

    private static func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "cl-\(UUID().uuidString).log")
    }

    @Test func debugDoesNotWriteToFile() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = RollingFileLog(fileURL: url)
        let cat = CategoryLog(category: "pipeline", file: file)

        cat.debug("verbose detail")

        // No info/notice/error/fault was called, so the file should not
        // have been written at all.
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func infoWritesViaShim() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let file = RollingFileLog(fileURL: url)
        let cat = CategoryLog(category: "pipeline", file: file)

        cat.info("through the shim")

        let body = try String(contentsOf: url, encoding: .utf8)
        #expect(body.contains("[INFO] [pipeline] through the shim"))
    }
}
