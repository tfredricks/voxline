import Foundation
import Observation

/// Derives the Settings status strip's chip data and overall readiness from
/// the existing settings view models. Pure derived state — no IO.
@Observable
@MainActor
final class SettingsStatusViewModel {

    private let general: GeneralSettingsViewModel
    private let keys: APIKeysSettingsViewModel
    private let isModelCached: (WhisperModel) -> Bool

    init(
        general: GeneralSettingsViewModel,
        keys: APIKeysSettingsViewModel,
        isModelCached: ((WhisperModel) -> Bool)? = nil
    ) {
        self.general = general
        self.keys = keys
        self.isModelCached = isModelCached ?? { TranscriptionService.isModelCached($0) }
    }

    var isReady: Bool {
        providerKeySaved && modelCached && micPresent
    }

    var modelChipShowsCheck: Bool { modelCached }
    var providerChipShowsCheck: Bool { providerKeySaved }

    var micChipText: String {
        guard let row = general.deviceRows.first(where: { $0.uid == general.audioInputDeviceUID }) else {
            return "System default mic"
        }
        return row.label
    }

    var modelChipText: String {
        general.whisperModel.displayName
    }

    var providerChipText: String {
        general.provider.displayName
    }

    private var providerKeySaved: Bool {
        let live: String
        switch general.provider {
        case .anthropic: live = keys.anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .openai:    live = keys.openaiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return !live.isEmpty && keys.isPersisted(general.provider)
    }

    private var modelCached: Bool {
        isModelCached(general.whisperModel)
    }

    private var micPresent: Bool {
        !general.devices.isEmpty || general.audioInputDeviceUID == nil
    }
}
