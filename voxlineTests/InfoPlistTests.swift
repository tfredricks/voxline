import Foundation
import Testing
@testable import voxline

@Suite struct InfoPlistTests {

    /// The text macOS shows in the microphone permission prompt. The OpenAI
    /// engine sends audio off the Mac, so the prompt can't promise it never does.
    @Test func microphone_prompt_names_the_cloud_engine_exception() throws {
        let text = try #require(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        #expect(text == "Voxline records audio while you hold the dictation hotkey and discards it after transcription. Audio stays on this Mac unless you choose the OpenAI cloud engine.")
    }
}
