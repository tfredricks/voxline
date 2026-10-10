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

    @Test func modelCacheDirectoryIfPresent_isNil_andCreatesNothing_whenMissing() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "voxline-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        #expect(AppPaths.modelCacheDirectoryIfPresent(base: base) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test func modelCacheDirectoryIfPresent_isNil_whenTheBaseItselfIsMissing() {
        let base = FileManager.default.temporaryDirectory.appending(path: "voxline-paths-\(UUID().uuidString)", directoryHint: .isDirectory)

        #expect(AppPaths.modelCacheDirectoryIfPresent(base: base) == nil)
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test func modelCacheDirectoryIfPresent_returnsTheCache_whenItExists() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "voxline-paths-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: base) }
        let cache = base.appending(path: "voxline/huggingface", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let found = try #require(AppPaths.modelCacheDirectoryIfPresent(base: base))
        #expect(found.standardizedFileURL.path == cache.standardizedFileURL.path)
    }

    @Test func modelCacheDirectoryIfPresent_matchesTheCreatingVariant() throws {
        let created = try AppPaths.modelCacheDirectory()
        let found = try #require(AppPaths.modelCacheDirectoryIfPresent())
        #expect(found.standardizedFileURL.path == created.standardizedFileURL.path)
    }

    /// Never touches the real bake-off folder, where the developer's own
    /// clips live.
    @Test func bakeoffDirectory_isInsideTheAppDirectory_andCreatesNothing() {
        let appDirectory = FileManager.default.temporaryDirectory.appending(path: "voxline-paths-\(UUID().uuidString)", directoryHint: .isDirectory)

        let url = AppPaths.bakeoffDirectory(inAppDirectory: appDirectory)

        #expect(url.standardizedFileURL.path == appDirectory.appending(path: "bakeoff").standardizedFileURL.path)
        #expect(!FileManager.default.fileExists(atPath: appDirectory.path))
    }

    @Test func bakeoffDirectory_isWhereTheBakeoffReadsFixtures() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = AppPaths.bakeoffDirectory(inAppDirectory: support.appending(path: "voxline", directoryHint: .isDirectory))
        #expect(url.standardizedFileURL.path == BakeoffFixtures.directory(environment: [:]).standardizedFileURL.path)
    }

    @Test func default_meeting_notes_folder_is_voxline_meetings_in_documents() {
        let url = AppPaths.defaultMeetingNotesFolder()
        #expect(Array(url.pathComponents.suffix(2)) == ["Documents", "voxline Meetings"])
        #expect(url.hasDirectoryPath)
    }

    @Test func learning_file_lives_in_the_app_directory() {
        let dir = URL(filePath: "/tmp/voxline-paths-test", directoryHint: .isDirectory)
        #expect(AppPaths.learningFile(inAppDirectory: dir).path == "/tmp/voxline-paths-test/learning.json")
    }
}
