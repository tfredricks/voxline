import Testing
@testable import voxline

@Suite struct WhisperModelTests {

    @Test func defaultIsLargeV3Turbo() {
        #expect(WhisperModel.default == .largeV3Turbo)
    }

    @Test func largeV3Turbo_identifierMatchesWhisperKitConvention() {
        #expect(WhisperModel.largeV3Turbo.whisperKitIdentifier == "openai_whisper-large-v3-v20240930_turbo")
    }

    @Test func smallEn_identifierMatchesWhisperKitConvention() {
        #expect(WhisperModel.smallEn.whisperKitIdentifier == "openai_whisper-small.en")
    }

    @Test func displayNamesAreNonEmpty() {
        #expect(!WhisperModel.largeV3Turbo.displayName.isEmpty)
        #expect(!WhisperModel.smallEn.displayName.isEmpty)
    }
}
