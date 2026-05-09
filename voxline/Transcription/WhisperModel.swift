import Foundation

/// Speech-to-text models supported by voxline. Spec §4.2 calls out
/// `large-v3-turbo` as default, `small.en` as the lightweight fallback.
enum WhisperModel: String, CaseIterable {
    case largeV3Turbo
    case smallEn

    static let `default`: WhisperModel = .largeV3Turbo

    /// Identifier WhisperKit uses to look up the Core ML model bundle in its
    /// hosted model repository. These map to argmaxinc/whisperkit-coreml
    /// repository folder names.
    var whisperKitIdentifier: String {
        switch self {
        case .largeV3Turbo: return "openai_whisper-large-v3-v20240930_turbo"
        case .smallEn:      return "openai_whisper-small.en"
        }
    }

    var displayName: String {
        switch self {
        case .largeV3Turbo: return "Whisper large-v3 turbo (recommended)"
        case .smallEn:      return "Whisper small.en (lightweight)"
        }
    }

    /// Approximate download size in megabytes; used by the first-run wizard.
    var approxSizeMB: Int {
        switch self {
        case .largeV3Turbo: return 1500
        case .smallEn:      return 466
        }
    }
}
