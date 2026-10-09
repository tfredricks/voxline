import Testing
import Foundation
@testable import voxline

@Suite struct ModeTests {

    @Test func encodes_and_decodes_round_trip_with_all_fields() throws {
        let mode = Mode(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            prompt: "Concise, casual.",
            model: "claude-haiku-4-5",
            temperature: 0.3
        )
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == mode)
    }

    @Test func encodes_and_decodes_round_trip_with_optional_fields_nil() throws {
        let mode = Mode(
            bundleID: "*",
            displayName: "Default",
            prompt: "Strip fillers.",
            model: nil,
            temperature: nil
        )
        let data = try JSONEncoder().encode(mode)
        let decoded = try JSONDecoder().decode(Mode.self, from: data)
        #expect(decoded == mode)
    }

    @Test func decodes_json_saved_before_category_and_fieldKind_existed() throws {
        let json = #"{"bundleID":"com.example.app","displayName":"Example","prompt":"Keep it short."}"#
        let decoded = try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
        #expect(decoded.bundleID == "com.example.app")
        #expect(decoded.prompt == "Keep it short.")
        #expect(decoded.fieldKind == nil)
        #expect(decoded.category == .general)
    }

    @Test func wildcard_bundle_id_is_a_well_known_constant() {
        #expect(Mode.wildcardBundleID == "*")
    }
}
