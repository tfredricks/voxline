import Foundation

/// The app's engine registry. `current` re-reads the user's choice on every
/// access, so a Settings change applies to the next dictation.
@MainActor
final class TranscriptionEngines: TranscriptionEngineProviding {
    private let settings: AppSettings
    private let apple: AppleSpeechEngine
    let whisperKit: WhisperKitEngine

    init(settings: AppSettings, apple: AppleSpeechEngine, whisperKit: WhisperKitEngine) {
        self.settings = settings
        self.apple = apple
        self.whisperKit = whisperKit
    }

    var current: any TranscriptionEngine { engine(for: settings.transcriptionEngine) }

    func engine(for id: EngineID) -> any TranscriptionEngine {
        switch id {
        case .apple:          return apple
        case .whisperKit:     return whisperKit
        case .openAIRealtime: return engine(for: .onDeviceDefault)
        }
    }
}
