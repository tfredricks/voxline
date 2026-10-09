import Foundation
import Observation

/// Derives the settings setup issues from the settings view models and the
/// selected engine's readiness, which `refreshEngineReadiness()` fetches
/// through the injected check.
@Observable
@MainActor
final class SettingsStatusViewModel {

    /// What a readiness result was checked for; a result only counts while
    /// it still matches the selection.
    struct ReadinessKey: Equatable {
        let engine: EngineID
        let whisperModel: WhisperModel
        /// Whether an OpenAI key is saved; tracked only for the OpenAI
        /// engine, whose readiness depends on it.
        let openAIKeySaved: Bool?
    }

    private let general: GeneralSettingsViewModel
    private let keys: APIKeysSettingsViewModel
    /// Readiness of the engine that runs for an `EngineID`; nil when it
    /// can't be checked yet (services not built).
    private let engineReadiness: @MainActor (EngineID) async -> EngineReadiness?
    private var checked: (key: ReadinessKey, readiness: EngineReadiness?)?
    @ObservationIgnored private var checkGeneration = 0

    init(
        general: GeneralSettingsViewModel,
        keys: APIKeysSettingsViewModel,
        engineReadiness: @escaping @MainActor (EngineID) async -> EngineReadiness?
    ) {
        self.general = general
        self.keys = keys
        self.engineReadiness = engineReadiness
    }

    var readinessKey: ReadinessKey {
        ReadinessKey(
            engine: general.engine,
            whisperModel: general.whisperModel,
            openAIKeySaved: general.engine == .openAIRealtime ? keys.hasSavedKey(.openai) : nil
        )
    }

    /// Checks the selected engine. A check that finishes after a newer one
    /// started is dropped.
    func refreshEngineReadiness() async {
        checkGeneration &+= 1
        let generation = checkGeneration
        let key = readinessKey
        let readiness = await engineReadiness(key.engine)
        guard generation == checkGeneration else { return }
        checked = (key, readiness)
    }

    /// Unchecked readiness (nil) is not an issue, so opening the window
    /// doesn't flash a warning before the check finishes.
    var issues: [SetupIssue] {
        var result: [SetupIssue] = []
        if !micPresent {
            result.append(SetupIssue(text: "Microphone not found", page: .dictation))
        }
        switch currentReadiness {
        case .unavailable(let reason):
            result.append(SetupIssue(text: reason, page: .dictation))
        case .needsPreparation(let downloadMB):
            let name = general.engine == .whisperKit ? "The Whisper model" : general.engine.shortName
            let size = downloadMB.map { " (\($0) MB)" } ?? ""
            result.append(SetupIssue(text: "\(name) needs a one-time download\(size)", page: .dictation))
        case .ready, nil:
            break
        }
        if !providerKeySaved {
            result.append(SetupIssue(text: "No \(general.provider.displayName) API key", page: .aiProvider))
        }
        return result
    }

    func needsSetup(_ page: MainWindowPage) -> Bool {
        issues.contains { $0.page == page }
    }

    private var currentReadiness: EngineReadiness? {
        guard let checked, checked.key == readinessKey else { return nil }
        return checked.readiness
    }

    private var providerKeySaved: Bool {
        let live: String
        switch general.provider {
        case .anthropic: live = keys.anthropicKey.trimmed
        case .openai:    live = keys.openaiKey.trimmed
        }
        // isPersisted returns true when both live and saved are empty (empty == empty),
        // so the !live.isEmpty guard is needed to distinguish "key not set" from "key saved".
        return !live.isEmpty && keys.isPersisted(general.provider)
    }

    private var micPresent: Bool {
        if let uid = general.audioInputDeviceUID {
            return general.devices.contains(where: { $0.uid == uid })
        }
        return !general.devices.isEmpty
    }
}
