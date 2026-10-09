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
}
