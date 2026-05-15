import Foundation

/// Thin wrapper around UserDefaults for non-secret user preferences.
/// Secrets live in the data-protection keychain (see `KeychainStorage`).
struct AppSettings {

    enum Key {
        static let provider = "voxline.llm.provider"
        static let model = "voxline.llm.model"
        static let hotkeyChord = "voxline.hotkey.chord"
        static let audioInputDeviceUID = "voxline.audio.inputDeviceUID"
        static let whisperModel = "voxline.whisper.model"
        static let hasCompletedFirstRun = "voxline.firstRun.completed"
        static let playHotkeySounds = "voxline.sounds.hotkey"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM provider choice. Defaults to .anthropic.
    /// Changing the provider clears any model override so the spec default
    /// for the new provider takes over (a model id from one provider is
    /// almost never valid for another). Re-assigning the same provider is
    /// a no-op — the override survives.
    var llmProvider: LLMProvider {
        get {
            guard
                let raw = defaults.string(forKey: Key.provider),
                let p = LLMProvider(rawValue: raw)
            else { return .anthropic }
            return p
        }
        set {
            // Read the previous value off disk so we can detect no-op writes.
            // The model-override clear is intentional on a real provider change
            // but must NOT fire when the same provider is re-assigned —
            // GeneralSettingsViewModel.commit() rebuilds the whole snapshot on
            // every unrelated settings change, and an unconditional clear here
            // would wipe Key.model on every mic / chord / sound toggle.
            let previous = defaults.string(forKey: Key.provider).flatMap(LLMProvider.init(rawValue:))
            defaults.set(newValue.rawValue, forKey: Key.provider)
            if previous != newValue {
                AppLog.llm.info("provider changed: \(previous?.rawValue ?? "(none)") → \(newValue.rawValue)")
                defaults.removeObject(forKey: Key.model)
            }
        }
    }

    /// Active LLM model id. Falls back to the spec default for the current
    /// provider when no override is set.
    var llmModel: String {
        get { defaults.string(forKey: Key.model) ?? llmProvider.defaultModel }
        set { defaults.set(newValue, forKey: Key.model) }
    }

    var hotkeyChord: HotkeyChord {
        get {
            guard
                let data = defaults.data(forKey: Key.hotkeyChord),
                let chord = try? JSONDecoder().decode(HotkeyChord.self, from: data)
            else { return .default }
            return chord
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            defaults.set(data, forKey: Key.hotkeyChord)
        }
    }

    var audioInputDeviceUID: String? {
        get { defaults.string(forKey: Key.audioInputDeviceUID) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.audioInputDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.audioInputDeviceUID)
            }
        }
    }

    var whisperModel: WhisperModel {
        get {
            guard
                let raw = defaults.string(forKey: Key.whisperModel),
                let m = WhisperModel(rawValue: raw)
            else { return .default }
            return m
        }
        set { defaults.set(newValue.rawValue, forKey: Key.whisperModel) }
    }

    var hasCompletedFirstRun: Bool {
        get { defaults.bool(forKey: Key.hasCompletedFirstRun) }
        set { defaults.set(newValue, forKey: Key.hasCompletedFirstRun) }
    }

    /// Audible feedback on hotkey press/release. Defaults to true when unset
    /// so existing users get sounds on next launch without an explicit migration.
    var playHotkeySounds: Bool {
        get {
            guard defaults.object(forKey: Key.playHotkeySounds) != nil else { return true }
            return defaults.bool(forKey: Key.playHotkeySounds)
        }
        set { defaults.set(newValue, forKey: Key.playHotkeySounds) }
    }

}
