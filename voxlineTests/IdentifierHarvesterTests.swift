import Testing
@testable import voxline

@Suite struct IdentifierHarvesterTests {

    @Test func keeps_names_typed_differently_from_speech_and_drops_plain_words() {
        let found = IdentifierHarvester.identifiers(in: [
            "Open CapturePipeline.swift and rename user_id in the feature-flags branch. Then stop",
        ])
        #expect(Set(found) == ["CapturePipeline.swift", "user_id", "feature-flags"])
    }

    @Test func nearest_the_end_of_the_first_text_comes_first_without_repeats() {
        let found = IdentifierHarvester.identifiers(in: ["fooBar baz_qux fooBar", "late_one baz_qux"])
        #expect(found == ["fooBar", "baz_qux", "late_one"])
    }

    @Test func stops_at_the_limit_and_skips_overlong_tokens() {
        let many = (0..<10).map { "name_\($0)" }.joined(separator: " ")
        #expect(IdentifierHarvester.identifiers(in: [many], limit: 3) == ["name_9", "name_8", "name_7"])
        #expect(IdentifierHarvester.identifiers(in: [String(repeating: "a_", count: 30)]).isEmpty)
    }
}
