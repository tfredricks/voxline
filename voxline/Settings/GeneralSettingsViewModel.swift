import Foundation
import Observation

/// Snapshot the General settings VM hands to the coordinator on save.
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let commandChord: HotkeyChord?
    let commandModel: String?
    let audioInputDeviceUID: String?
    let engine: EngineID
    let whisperModel: WhisperModel
    let playHotkeySounds: Bool
    let provider: LLMProvider
}

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord { didSet { if loaded { commit() } } }
    var commandChord: HotkeyChord? { didSet { if loaded { commit() } } }
    /// Command model id as typed; `""` means the cleanup model.
    var commandModel: String { didSet { if loaded { commit() } } }
    var audioInputDeviceUID: String? { didSet { if loaded { commit() } } }
    var engine: EngineID { didSet { if loaded { commit() } } }
    var whisperModel: WhisperModel { didSet { if loaded { commit() } } }
    var playHotkeySounds: Bool { didSet { if loaded { commit() } } }
    /// A real provider change also clears `commandModel`, as `AppSettings` does.
    var provider: LLMProvider {
        didSet {
            guard loaded else { return }
            if provider != oldValue { withoutCommitting { commandModel = "" } }
            commit()
        }
    }

    var launchAtLogin: Bool {
        didSet {
            guard loaded, oldValue != launchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    var showInDock: Bool {
        didSet {
            guard loaded, oldValue != showInDock else { return }
            settings.showInDock = showInDock
        }
    }
    private(set) var loginItemStatus: LoginItemService.Status

    private(set) var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let onApply: (GeneralSettingsSnapshot) -> Void
    private let deviceEnumerator: () -> [AudioDevice]
    private var deviceListener: AudioDeviceListener?
    private let loginItemService: LoginItemService
    private let hasOpenAIKey: () -> Bool
    /// Last keychain answer from `hasOpenAIKey`; nil until first refreshed,
    /// so init never touches the keychain.
    private var openAIKeyStored: Bool?
    private var loaded = false

    /// Convenience init that constructs the default `LoginItemService` at call
    /// time. Default-argument expressions for `@MainActor`-isolated types are
    /// evaluated outside the function's isolation context, so we build it in
    /// the body instead.
    convenience init(
        settings: AppSettings = AppSettings(),
        onApply: @escaping (GeneralSettingsSnapshot) -> Void,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices
    ) {
        self.init(
            settings: settings,
            onApply: onApply,
            deviceEnumerator: deviceEnumerator,
            loginItemService: LoginItemService()
        )
    }

    init(
        settings: AppSettings = AppSettings(),
        onApply: @escaping (GeneralSettingsSnapshot) -> Void,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices,
        loginItemService: LoginItemService,
        hasOpenAIKey: @escaping () -> Bool = GeneralSettingsViewModel.storedOpenAIKeyExists
    ) {
        self.settings = settings
        self.onApply = onApply
        self.deviceEnumerator = deviceEnumerator
        self.loginItemService = loginItemService
        self.hasOpenAIKey = hasOpenAIKey
        self.chord = settings.hotkeyChord
        self.commandChord = settings.commandChord
        self.commandModel = settings.commandModel ?? ""
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.engine = settings.transcriptionEngine
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.provider = settings.llmProvider
        let initialStatus = loginItemService.status
        self.loginItemStatus = initialStatus
        self.launchAtLogin = (initialStatus == .enabled)
        self.showInDock = settings.showInDock
        self.devices = deviceEnumerator()
        self.loaded = true
        self.deviceListener = AudioDeviceListener { [weak self] in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    var deviceRows: [AudioDeviceRow] {
        var rows: [AudioDeviceRow] = [AudioDeviceRow(uid: nil, label: "System default")]
        for d in devices {
            let suffix = d.isDefault ? " (default)" : ""
            rows.append(AudioDeviceRow(uid: d.uid, label: d.name + suffix))
        }
        if let uid = audioInputDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            rows.append(AudioDeviceRow(uid: uid, label: "(disconnected) previously selected"))
        }
        return rows
    }

    /// True when the OpenAI engine is selected and the last keychain check
    /// found no OpenAI key. False until the key has been checked.
    var showsOpenAIKeyWarning: Bool {
        engine == .openAIRealtime && openAIKeyStored == false
    }

    /// True when OpenAI transcribes but another provider cleans up, so the
    /// AI Provider page shows no OpenAI key row and Recognition shows one.
    var showsOpenAIKeyInRecognition: Bool {
        engine == .openAIRealtime && provider != .openai
    }

    /// Recognition's missing-key warning for the OpenAI engine, or nil.
    var openAIKeyWarning: String? {
        guard showsOpenAIKeyWarning else { return nil }
        return showsOpenAIKeyInRecognition
            ? "Add an OpenAI API key below to use this engine."
            : "Add an OpenAI API key to use this engine."
    }

    /// Re-reads whether an OpenAI key is stored. Call after the stored key
    /// may have changed; `refreshFromUserDefaults()` calls it too.
    func openAIKeyDidChange() {
        openAIKeyStored = hasOpenAIKey()
    }

    /// Production `hasOpenAIKey`: a non-blank OpenAI key is in the keychain.
    /// A keychain read error counts as no key.
    nonisolated static func storedOpenAIKeyExists() -> Bool {
        guard let key = try? DataProtectionKeychain().string(forKey: KeychainAccount.openai) else { return false }
        return !key.isBlank
    }

    /// The model commands use when `commandModel` is empty.
    var cleanupModelPlaceholder: String { settings.llmModel }

    var chords: ChordSet { ChordSet(dictation: chord, command: commandChord) }

    var commandModeEnabled: Bool {
        get { commandChord != nil }
        set {
            guard newValue != commandModeEnabled else { return }
            commandChord = newValue ? defaultCommandChordAvoidingCollision() : nil
        }
    }

    /// Rejection for a dictation chord that is the command chord, or nil.
    func validateDictationChord(_ chord: HotkeyChord) -> String? {
        commandChord?.keys == chord.keys ? "That's your command hotkey" : nil
    }

    /// Rejection for a command chord that is the dictation chord, or nil.
    func validateCommandChord(_ chord: HotkeyChord) -> String? {
        chord.keys == self.chord.keys ? "That's your dictation hotkey" : nil
    }

    private func defaultCommandChordAvoidingCollision() -> HotkeyChord {
        guard HotkeyChord.defaultCommand.keys == chord.keys else { return .defaultCommand }
        let spare = HotkeyChord.Modifier.allCases.first { !chord.keys.contains($0) }!
        return HotkeyChord(modifierA: chord.modifierA, modifierB: spare)
    }

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    /// Re-reads `LoginItemService.status` and reconciles `launchAtLogin` to it.
    /// Called after every toggle, when the main window is built, and each time
    /// the General page appears, so approval or revocation in System Settings →
    /// Login Items shows up there.
    func refreshLoginItemStatus() {
        let status = loginItemService.status
        loginItemStatus = status
        let actual = (status == .enabled)
        if launchAtLogin != actual {
            withoutCommitting { launchAtLogin = actual }
        }
    }

    /// Re-reads UserDefaults-backed settings, and whether an OpenAI key is
    /// stored, so the Settings UI reflects writes made elsewhere in the app
    /// (e.g., the wizard's `advance()` persisting `selectedProvider` and the
    /// keys). The view model otherwise caches the value from init and would
    /// show stale state on subsequent window opens. Called via `.task` when the
    /// main window is built, together with `refreshLoginItemStatus()`.
    func refreshFromUserDefaults() {
        withoutCommitting {
            chord = settings.hotkeyChord
            commandChord = settings.commandChord
            commandModel = settings.commandModel ?? ""
            audioInputDeviceUID = settings.audioInputDeviceUID
            engine = settings.transcriptionEngine
            whisperModel = settings.whisperModel
            playHotkeySounds = settings.playHotkeySounds
            provider = settings.llmProvider
            showInDock = settings.showInDock
        }
        openAIKeyDidChange()
    }

    /// Restore Spec defaults: hotkey to Left Shift + Left Control, command
    /// chord to Left Shift + Left Option, the cleanup model for commands,
    /// system-default mic, the default engine, large-v3-turbo, sounds on.
    /// Performs one batched commit so the applier sees a single coherent
    /// snapshot rather than several partial ones.
    /// Launch-at-Login, Show in Dock, the presets (`PresetStore`), the custom vocabulary, and
    /// everything in Settings → Vocabulary (Learning) are intentionally left untouched —
    /// Reset is for pipeline settings, not user data or OS-level integration.
    func resetToDefaults() {
        withoutCommitting {
            chord = .default
            commandChord = .defaultCommand
            commandModel = ""
            audioInputDeviceUID = nil
            engine = .default
            whisperModel = .default
            playHotkeySounds = true
            provider = .anthropic
        }
        commit()
    }

    private func applyLaunchAtLogin() {
        // The setter throws on signing/Tcc issues. Reconcile state to actual
        // backend status either way so the UI doesn't lie.
        try? loginItemService.setEnabled(launchAtLogin)
        refreshLoginItemStatus()
    }

    private func commit() {
        var s = settings
        s.hotkeyChord = chord
        s.commandChord = commandChord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.transcriptionEngine = engine
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        s.llmProvider = provider
        s.commandModel = commandModel
        settings = s
        onApply(GeneralSettingsSnapshot(
            chord: chord,
            commandChord: commandChord,
            commandModel: s.commandModel,
            audioInputDeviceUID: audioInputDeviceUID,
            engine: engine,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds,
            provider: provider
        ))
    }

    /// Run `mutations` with `loaded == false` so the `didSet` → `commit()`
    /// chain on `chord`, `audioInputDeviceUID`, etc. does not fire. Use this
    /// when batch-syncing the view model to a backing store (UserDefaults,
    /// `LoginItemService.status`, the Reset-to-defaults path) where the
    /// changes already represent ground truth and committing them back would
    /// be redundant at best, recursive at worst.
    private func withoutCommitting(_ mutations: () -> Void) {
        loaded = false
        mutations()
        loaded = true
    }
}
