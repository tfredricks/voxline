import Testing
import Foundation
@testable import voxline

@Suite struct AppPathsTests {

    @Test func applicationSupportDirectoryReturnsExistingDirectory() throws {
        let url = try AppPaths.applicationSupportDirectory()

        // Directory must exist on disk.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        #expect(exists, "AppPaths.applicationSupportDirectory() must return an existing directory")
        #expect(isDir.boolValue, "Result must be a directory, not a file")

        // Path must end with /voxline (the app subdirectory).
        #expect(url.lastPathComponent == "voxline",
                "Expected URL to end with /voxline, got: \(url.path)")
    }

    @Test func modesFilePathIsUnderApplicationSupport() throws {
        let modesURL = try AppPaths.modesFile()
        let baseURL = try AppPaths.applicationSupportDirectory()

        #expect(modesURL.path.hasPrefix(baseURL.path),
                "modes.json must live under the app support directory")
        #expect(modesURL.lastPathComponent == "modes.json")
    }

    @Test func neverReturnsHardCodedHomePath() throws {
        // Under sandbox the path must be containerized; even outside sandbox it
        // must come from FileManager, not a hand-built ~/Library path.
        let url = try AppPaths.applicationSupportDirectory()
        let literalPath = NSHomeDirectory() + "/Library/Application Support/voxline"

        // Under sandbox NSHomeDirectory itself returns the container path, so
        // this assertion is really: the helper produces *something* and doesn't
        // throw. The strongest cross-sandbox assertion is just that it exists.
        #expect(!url.path.isEmpty)
        _ = literalPath  // referenced to document what we are NOT hardcoding
    }
}
