import Testing
import Foundation
@testable import voxline

@Suite struct AppPathsTests {

    @Test func modelCacheDirectory_isUnderApplicationSupport_andExists() throws {
        let url = try AppPaths.modelCacheDirectory()
        #expect(Array(url.pathComponents.suffix(3)) == ["Application Support", "voxline", "huggingface"])
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func modesFile_isNextToTheModelCache() throws {
        let modes = try AppPaths.modesFile()
        let cache = try AppPaths.modelCacheDirectory()
        #expect(modes.deletingLastPathComponent() == cache.deletingLastPathComponent())
        #expect(modes.lastPathComponent == "modes.json")
    }

    @Test func legacyContainerDataDirectory_pointsInsideTheOldSandbox() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let url = AppPaths.legacyContainerDataDirectory(home: home)
        #expect(url.path == "/Users/example/Library/Containers/com.voxline.app/Data")
    }
}
