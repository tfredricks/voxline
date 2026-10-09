import Testing
import Foundation
@testable import voxline

@Suite struct TranscriptionEngineTypesTests {

    @Test(arguments: [
        ("", "a", "a"),
        ("a", "", "a"),
        ("a ", " b", "a b"),
        ("Hello,", "world", "Hello, world"),
    ])
    func join_places_exactly_one_space_at_the_seam(head: String, tail: String, expected: String) {
        #expect(TranscriptPartial.join(head, tail) == expected)
    }

    @Test func partial_text_joins_stable_and_volatile() {
        #expect(TranscriptPartial(stable: "Hello,", volatile: "world").text == "Hello, world")
        #expect(TranscriptPartial().isEmpty)
        #expect(!TranscriptPartial(volatile: "hi").isEmpty)
    }

    @Test func engine_raw_values_are_stable() {
        #expect(EngineID.apple.rawValue == "apple")
        #expect(EngineID.whisperKit.rawValue == "whisperkit")
        #expect(EngineID.openAIRealtime.rawValue == "openai-realtime")
    }

    @Test func default_engine_is_on_device() {
        #expect(EngineID.default.isOnDevice)
        #expect(EngineID.onDeviceDefault.isOnDevice)
    }

    @Test func display_names_match_the_settings_picker_copy() {
        #expect(EngineID.apple.displayName == "Apple Speech — on-device, fastest")
        #expect(EngineID.whisperKit.displayName == "Whisper — on-device")
        #expect(EngineID.openAIRealtime.displayName == "OpenAI — cloud, audio leaves your Mac")
    }

    @Test func short_names_are_the_bare_engine_names() {
        #expect(EngineID.apple.shortName == "Apple Speech")
        #expect(EngineID.whisperKit.shortName == "Whisper")
        #expect(EngineID.openAIRealtime.shortName == "OpenAI")
    }
}
