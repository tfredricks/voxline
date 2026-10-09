import Foundation
import Testing
@testable import voxline

@Suite struct MeetingFileNamerTests {

    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_791_554_520) // 2026-10-09 14:02 UTC

    @Test func file_name_has_date_time_prefix_and_md_extension() {
        let name = MeetingFileNamer.fileName(startedAt: start, title: "Q4 pricing review", timeZone: utc)
        #expect(name == "2026-10-09 1402 Q4 pricing review.md")
    }

    @Test func suffix_goes_before_the_extension() {
        let name = MeetingFileNamer.fileName(startedAt: start, title: "Sync", suffix: "regenerated", timeZone: utc)
        #expect(name == "2026-10-09 1402 Sync (regenerated).md")
    }

    @Test func sanitize_replaces_path_and_control_characters() {
        #expect(MeetingFileNamer.sanitize("A/B: plan\u{0007}\n") == "A-B- plan")
    }

    @Test func sanitize_trims_to_80_characters() {
        let long = String(repeating: "x", count: 120)
        #expect(MeetingFileNamer.sanitize(long).count == 80)
    }

    @Test func blank_title_becomes_meeting() {
        #expect(MeetingFileNamer.sanitize("  /  ") == "Meeting")
    }

    @Test func unique_url_appends_counter_on_collision() {
        let folder = URL(fileURLWithPath: "/tmp/notes")
        let taken: Set<String> = ["a.md", "a (2).md"]
        let url = MeetingFileNamer.uniqueURL(in: folder, fileName: "a.md") { taken.contains($0.lastPathComponent) }
        #expect(url.lastPathComponent == "a (3).md")
    }
}
