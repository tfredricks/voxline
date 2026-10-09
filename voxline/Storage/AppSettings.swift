import Foundation

/// Thin wrapper around UserDefaults for non-secret user preferences.
/// Secrets live in the data-protection keychain (see `KeychainStorage`).
struct AppSettings {

    enum Key {
        static let provider = "voxline.llm.provider"
        static let model = "voxline.llm.model"
        static let hotkeyChord = "voxline.hotkey.chord"
        static let commandChord = "voxline.hotkey.commandChord"
        static let legacyCommandModifier = "voxline.hotkey.commandModifier"
        static let commandModel = "voxline.llm.commandModel"
        static let audioInputDeviceUID = "voxline.audio.inputDeviceUID"
        static let whisperModel = "voxline.whisper.model"
        static let hasCompletedFirstRun = "voxline.firstRun.completed"
        static let playHotkeySounds = "voxline.sounds.hotkey"
        static let transcriptionEngine = "voxline.transcription.engine"
        static let skipShortUtterances = "voxline.llm.skipShortUtterances"
        static let saveBakeoffClips = "voxline.debug.saveBakeoffClips"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM provider choice. Defaults to .anthropic.
    /// Changing the provider clears the model override and `commandModel` so
    /// the spec default for the new provider takes over (a model id from one
    /// provider is almost never valid for another). Re-assigning the same
    /// provider is a no-op — the overrides survive.
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
                defaults.removeObject(forKey: Key.commandModel)
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

    /// The command-mode chord, or nil when command mode is off. Stored as
    /// JSON, or the string `"off"` for nil. Absent → `.defaultCommand`,
    /// unless that is the dictation chord, then off.
    var commandChord: HotkeyChord? {
        get {
            if defaults.string(forKey: Key.commandChord) == "off" { return nil }
            if let data = defaults.data(forKey: Key.commandChord),
               let chord = try? JSONDecoder().decode(HotkeyChord.self, from: data) {
                return chord
            }
            return HotkeyChord.defaultCommand.keys == hotkeyChord.keys ? nil : .defaultCommand
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.commandChord)
            } else {
                defaults.set("off", forKey: Key.commandChord)
            }
        }
    }

    var chords: ChordSet { ChordSet(dictation: hotkeyChord, command: commandChord) }

    /// Model id for commands; nil means the cleanup model. A blank value is
    /// stored as absent.
    var commandModel: String? {
        get {
            guard let raw = defaults.string(forKey: Key.commandModel), !raw.isBlank else { return nil }
            return raw.trimmed
        }
        set {
            if let newValue, !newValue.isBlank {
                defaults.set(newValue.trimmed, forKey: Key.commandModel)
            } else {
                defaults.removeObject(forKey: Key.commandModel)
            }
        }
    }

    /// Writes `commandChord` from the legacy command modifier
    /// (`CommandChordMigration`) and removes the legacy key. Does nothing
    /// once `commandChord` is stored, so it runs at most once per install.
    mutating func migrateCommandChordIfNeeded() {
        guard defaults.object(forKey: Key.commandChord) == nil else { return }
        let stored = defaults.string(forKey: Key.legacyCommandModifier)
        let migrated = CommandChordMigration.commandChord(dictation: hotkeyChord, stored: stored)
        commandChord = migrated
        defaults.removeObject(forKey: Key.legacyCommandModifier)
        AppLog.hotkey.info("migrated command modifier \(stored ?? "(absent)", privacy: .public) → \(migrated?.displayName ?? "off", privacy: .public)")
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

    var transcriptionEngine: EngineID {
        get {
            guard
                let raw = defaults.string(forKey: Key.transcriptionEngine),
                let id = EngineID(rawValue: raw)
            else { return .default }
            return id
        }
        set { defaults.set(newValue.rawValue, forKey: Key.transcriptionEngine) }
    }

    /// Hidden switch (no Settings UI): when true, short transcripts with no
    /// filler words skip LLM cleanup. See `CleanupFastPath`.
    var skipShortUtterances: Bool {
        get { defaults.bool(forKey: Key.skipShortUtterances) }
        set { defaults.set(newValue, forKey: Key.skipShortUtterances) }
    }

    /// Hidden developer flag (no Settings UI), off when unset: when true,
    /// each successful dictation is saved to `AppPaths.bakeoffDirectory()`
    /// as a bake-off clip, its audio plus the cleaned text. This is the only
    /// code path that writes audio to disk.
    var saveBakeoffClips: Bool {
        get { defaults.bool(forKey: Key.saveBakeoffClips) }
        set { defaults.set(newValue, forKey: Key.saveBakeoffClips) }
    }
}
