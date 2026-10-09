import Foundation

/// Thin wrapper around UserDefaults for non-secret user preferences.
/// Secrets live in the data-protection keychain (see `KeychainStorage`).
/// `@unchecked Sendable`: its only state is a `UserDefaults`, which is documented thread-safe.
struct AppSettings: @unchecked Sendable {

    enum Key {
        static let provider = "voxline.llm.provider"
        static let model = "voxline.llm.model"
        static let hotkeyChord = "voxline.hotkey.chord"
        static let commandChord = "voxline.hotkey.commandChord"
        static let commandModel = "voxline.llm.commandModel"
        static let audioInputDeviceUID = "voxline.audio.inputDeviceUID"
        static let whisperModel = "voxline.whisper.model"
        static let hasCompletedFirstRun = "voxline.firstRun.completed"
        static let playHotkeySounds = "voxline.sounds.hotkey"
        static let transcriptionEngine = "voxline.transcription.engine"
        static let skipShortUtterances = "voxline.llm.skipShortUtterances"
        static let saveBakeoffClips = "voxline.debug.saveBakeoffClips"
        static let meetingNotesFolder = "voxline.meetings.notesFolder"
        static let meetingShortcut = "voxline.meetings.shortcut"
        static let meetingNotesModel = "voxline.meetings.notesModel"
        static let meetingAudioRetention = "voxline.meetings.audioRetention"
        static let meetingShowTimer = "voxline.meetings.showTimer"
        static let meetingLiveTranscript = "voxline.meetings.liveTranscript"
        static let meetingLivePanelExpanded = "voxline.meetings.livePanelExpanded"
        static let meetingConsentNoticeShown = "voxline.meetings.consentNoticeShown"
        static let meetingSilentSystemNoticeShown = "voxline.meetings.silentSystemNoticeShown"
        static let meetingCapSeconds = "voxline.debug.meetingCapSeconds"
        static let learnWords = "voxline.learning.words"
        static let learnStyle = "voxline.learning.style"
        static let showInDock = "voxline.showInDock"
    }

    /// Stored under `Key.commandChord` for "command mode off".
    static let commandChordOff = "off"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// LLM provider choice. Defaults to .anthropic.
    /// Changing the provider clears the model override, `commandModel` and `meetingNotesModel` so
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
                defaults.removeObject(forKey: Key.meetingNotesModel)
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
    /// JSON, or `commandChordOff` for nil. Absent → `.defaultCommand`,
    /// unless that is the dictation chord, then off.
    var commandChord: HotkeyChord? {
        get {
            if defaults.string(forKey: Key.commandChord) == Self.commandChordOff { return nil }
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
                defaults.set(Self.commandChordOff, forKey: Key.commandChord)
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

    /// Settings → Vocabulary (Learning): add words the user fixes after a dictation to
    /// the custom vocabulary. Absent reads as on.
    var learnWords: Bool {
        get { defaults.object(forKey: Key.learnWords) == nil ? true : defaults.bool(forKey: Key.learnWords) }
        set { defaults.set(newValue, forKey: Key.learnWords) }
    }

    /// When true the app stays a regular Dock app; when false the Dock icon
    /// shows only while a main-level window is open.
    var showInDock: Bool {
        get { defaults.bool(forKey: Key.showInDock) }
        set { defaults.set(newValue, forKey: Key.showInDock) }
    }

    /// Settings → Vocabulary (Learning): keep recent dictations and edits per category
    /// and send a learned style note with cleanup. Absent reads as on.
    var learnStyle: Bool {
        get { defaults.object(forKey: Key.learnStyle) == nil ? true : defaults.bool(forKey: Key.learnStyle) }
        set { defaults.set(newValue, forKey: Key.learnStyle) }
    }

    /// Where meeting notes files are written.
    var meetingNotesFolder: URL {
        get {
            if let path = defaults.string(forKey: Key.meetingNotesFolder), !path.isBlank {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Documents")
            return documents.appending(path: "voxline Meetings", directoryHint: .isDirectory)
        }
        set { defaults.set(newValue.path, forKey: Key.meetingNotesFolder) }
    }

    /// Start/stop shortcut for meeting recording; nil when not set.
    var meetingShortcut: KeyCombo? {
        get {
            guard let data = defaults.data(forKey: Key.meetingShortcut) else { return nil }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.meetingShortcut)
            } else {
                defaults.removeObject(forKey: Key.meetingShortcut)
            }
        }
    }

    /// Model id for meeting notes; nil means the command model, then the
    /// cleanup model. A blank value is stored as absent.
    var meetingNotesModel: String? {
        get {
            guard let raw = defaults.string(forKey: Key.meetingNotesModel), !raw.isBlank else { return nil }
            return raw.trimmed
        }
        set {
            if let newValue, !newValue.isBlank {
                defaults.set(newValue.trimmed, forKey: Key.meetingNotesModel)
            } else {
                defaults.removeObject(forKey: Key.meetingNotesModel)
            }
        }
    }

    var resolvedMeetingNotesModel: String { meetingNotesModel ?? commandModel ?? llmModel }

    var meetingAudioRetention: MeetingAudioRetention {
        get { defaults.string(forKey: Key.meetingAudioRetention).flatMap(MeetingAudioRetention.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.meetingAudioRetention) }
    }

    var showMeetingTimer: Bool {
        get {
            guard defaults.object(forKey: Key.meetingShowTimer) != nil else { return true }
            return defaults.bool(forKey: Key.meetingShowTimer)
        }
        set { defaults.set(newValue, forKey: Key.meetingShowTimer) }
    }

    /// Settings → Meetings → Live transcript. Absent reads as on.
    var meetingLiveTranscript: Bool {
        get {
            guard defaults.object(forKey: Key.meetingLiveTranscript) != nil else { return true }
            return defaults.bool(forKey: Key.meetingLiveTranscript)
        }
        set { defaults.set(newValue, forKey: Key.meetingLiveTranscript) }
    }

    /// Live sessions run only when there is a timer chip to show them in.
    var liveTranscriptEnabled: Bool { showMeetingTimer && meetingLiveTranscript }

    /// Whether the timer chip was last left expanded to the live transcript.
    var meetingLivePanelExpanded: Bool {
        get { defaults.bool(forKey: Key.meetingLivePanelExpanded) }
        set { defaults.set(newValue, forKey: Key.meetingLivePanelExpanded) }
    }

    var meetingConsentNoticeShown: Bool {
        get { defaults.bool(forKey: Key.meetingConsentNoticeShown) }
        set { defaults.set(newValue, forKey: Key.meetingConsentNoticeShown) }
    }

    var meetingSilentSystemNoticeShown: Bool {
        get { defaults.bool(forKey: Key.meetingSilentSystemNoticeShown) }
        set { defaults.set(newValue, forKey: Key.meetingSilentSystemNoticeShown) }
    }

    /// Hidden developer override (no Settings UI) of the 60-minute meeting
    /// cap, in seconds, for manual tests. Nil when unset or not positive.
    var meetingCapSeconds: Int? {
        let value = defaults.integer(forKey: Key.meetingCapSeconds)
        return value > 0 ? value : nil
    }
}
