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
        #expect(modesURL.path.hasSuffix("voxline/modes.json"))
        #expect(modesURL.lastPathComponent == "modes.json")
    }

    @Test func pathLivesUnderApplicationSupportDomain() throws {
        let url = try AppPaths.applicationSupportDirectory()
        // Whether sandboxed or not, FileManager always produces a path
        // containing "Application Support" — proves we're not falling back
        // to a hand-built path elsewhere on disk.
        #expect(url.path.contains("Application Support"))
    }
}
