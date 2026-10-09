import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct GeneralSettingsViewModelTests {

    private func defaults() -> UserDefaults {
        let n = "voxline-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: n)!
    }

    @Test func loads_current_values_on_init() {
        var settings = AppSettings(defaults: defaults())
        let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        settings.hotkeyChord = chord
        settings.audioInputDeviceUID = "MyMic"
        settings.whisperModel = .smallEn
        settings.playHotkeySounds = false
        settings.llmProvider = .openai

        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        #expect(vm.chord == chord)
        #expect(vm.audioInputDeviceUID == "MyMic")
        #expect(vm.whisperModel == .smallEn)
        #expect(vm.playHotkeySounds == false)
        #expect(vm.provider == .openai)
    }

    @Test func mutations_persist_and_call_applier_immediately() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(settings: settings, onApply: { recorder.record($0) })

        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        vm.chord = chord
        #expect(recorder.applied?.chord == chord)
        #expect(AppSettings(defaults: d).hotkeyChord == chord)

        vm.audioInputDeviceUID = "NewMic"
        #expect(recorder.applied?.audioInputDeviceUID == "NewMic")
        #expect(AppSettings(defaults: d).audioInputDeviceUID == "NewMic")

        vm.whisperModel = .smallEn
        #expect(recorder.applied?.whisperModel == .smallEn)
        #expect(AppSettings(defaults: d).whisperModel == .smallEn)

        vm.playHotkeySounds = false
        #expect(recorder.applied?.playHotkeySounds == false)
        #expect(AppSettings(defaults: d).playHotkeySounds == false)

        #expect(recorder.applied?.provider == .anthropic)
    }

    @Test func init_does_not_call_applier() {
        var settings = AppSettings(defaults: defaults())
        settings.hotkeyChord = HotkeyChord(modifierA: .leftCommand, modifierB: .rightOption)
        let recorder = ApplyRecorder()
        _ = GeneralSettingsViewModel(settings: settings, onApply: { recorder.record($0) })
        #expect(recorder.applied == nil)
    }

    @Test func device_rows_includes_disconnected_marker_when_saved_uid_is_absent() {
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = "GhostMic"
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: noopApply,
            deviceEnumerator: { [] }   // no devices present
        )
        let rows = vm.deviceRows
        #expect(rows.contains { $0.uid == "GhostMic" && $0.label.contains("disconnected") })
    }

    @Test func device_rows_omits_disconnected_marker_when_uid_is_present_in_device_list() {
        var settings = AppSettings(defaults: defaults())
        settings.audioInputDeviceUID = "MicA"
        let stubDevices = [AudioDevice(uid: "MicA", name: "Mic A", isDefault: false)]
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: noopApply,
            deviceEnumerator: { stubDevices }
        )
        let rows = vm.deviceRows
        #expect(rows.contains { $0.uid == "MicA" && !$0.label.contains("disconnected") })
        #expect(rows.allSatisfy { !$0.label.contains("disconnected") || $0.uid != "MicA" })
    }

    @Test func refresh_devices_picks_up_new_enumerator_output() {
        var nextDevices: [AudioDevice] = []
        let settings = AppSettings(defaults: defaults())
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: noopApply,
            deviceEnumerator: { nextDevices }
        )
        #expect(vm.devices.isEmpty)

        nextDevices = [AudioDevice(uid: "MicNew", name: "New Mic", isDefault: true)]
        vm.refreshDevices()
        #expect(vm.devices == [AudioDevice(uid: "MicNew", name: "New Mic", isDefault: true)])
    }

    @Test func reset_restores_spec_defaults_and_calls_applier_once() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.hotkeyChord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        settings.audioInputDeviceUID = "MicX"
        settings.whisperModel = .smallEn
        settings.playHotkeySounds = false
        settings.llmProvider = .openai

        let recorder = ApplyRecorder()
        // resetToDefaults() calls vocabulary.save([]). Without an explicit
        // suite-backed store here, the default CustomVocabularyStore() hits
        // UserDefaults.standard — which in the test host resolves
        // to the live com.voxline.app prefs and silently wipes the user's
        // real custom-vocabulary list.
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: { recorder.record($0) },
            loginItemService: LoginItemService(),
            vocabulary: CustomVocabularyStore(defaults: d)
        )
        vm.resetToDefaults()

        #expect(vm.chord == .default)
        #expect(vm.audioInputDeviceUID == nil)
        #expect(vm.whisperModel == .default)
        #expect(vm.playHotkeySounds == true)
        #expect(recorder.applied?.chord == .default)
        #expect(recorder.applied?.whisperModel == .default)
        #expect(recorder.applied?.playHotkeySounds == true)
        #expect(recorder.applied?.audioInputDeviceUID == nil)
        #expect(vm.provider == .anthropic)
        #expect(recorder.applied?.provider == .anthropic)
    }

    @Test func engine_loads_from_settings_on_init() {
        var settings = AppSettings(defaults: defaults())
        settings.transcriptionEngine = .apple
        let vm = GeneralSettingsViewModel(settings: settings, onApply: noopApply)
        #expect(vm.engine == .apple)
    }

    @Test func engine_change_persists_and_reaches_the_snapshot() {
        let d = defaults()
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(settings: AppSettings(defaults: d), onApply: { recorder.record($0) })

        vm.engine = .apple
        #expect(recorder.applied?.engine == .apple)
        #expect(AppSettings(defaults: d).transcriptionEngine == .apple)

        vm.engine = .openAIRealtime
        #expect(recorder.applied?.engine == .openAIRealtime)
        #expect(AppSettings(defaults: d).transcriptionEngine == .openAIRealtime)
    }

    @Test func engine_refreshes_from_writes_made_elsewhere() {
        let d = defaults()
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: d),
            onApply: noopApply,
            loginItemService: LoginItemService(),
            hasOpenAIKey: { false }
        )
        var elsewhere = AppSettings(defaults: d)
        elsewhere.transcriptionEngine = .apple
        vm.refreshFromUserDefaults()
        #expect(vm.engine == .apple)
    }

    @Test func reset_restores_the_default_engine() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.transcriptionEngine = .openAIRealtime
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(
            settings: settings,
            onApply: { recorder.record($0) },
            loginItemService: LoginItemService(),
            vocabulary: CustomVocabularyStore(defaults: d),
            hasOpenAIKey: { true }
        )
        vm.resetToDefaults()
        #expect(vm.engine == EngineID.default)
        #expect(recorder.applied?.engine == EngineID.default)
        #expect(AppSettings(defaults: d).transcriptionEngine == EngineID.default)
    }

    private func openAIEngineVM(hasOpenAIKey: @escaping () -> Bool) -> GeneralSettingsViewModel {
        var settings = AppSettings(defaults: defaults())
        settings.transcriptionEngine = .openAIRealtime
        return GeneralSettingsViewModel(
            settings: settings,
            onApply: noopApply,
            loginItemService: LoginItemService(),
            hasOpenAIKey: hasOpenAIKey
        )
    }

    @Test func openai_engine_without_a_key_shows_the_key_warning() {
        let vm = openAIEngineVM(hasOpenAIKey: { false })
        vm.refreshFromUserDefaults()
        #expect(vm.showsOpenAIKeyWarning)
    }

    @Test func openai_engine_with_a_key_hides_the_key_warning() {
        let vm = openAIEngineVM(hasOpenAIKey: { true })
        vm.refreshFromUserDefaults()
        #expect(!vm.showsOpenAIKeyWarning)
    }

    @Test func key_is_not_read_until_refreshed_and_no_warning_shows_before() {
        var keyChecks = 0
        let vm = openAIEngineVM(hasOpenAIKey: { keyChecks += 1; return false })
        #expect(!vm.showsOpenAIKeyWarning)
        #expect(keyChecks == 0)
    }

    @Test func the_key_is_read_once_per_refresh_not_per_evaluation() {
        var keyChecks = 0
        let vm = openAIEngineVM(hasOpenAIKey: { keyChecks += 1; return false })
        vm.openAIKeyDidChange()
        for _ in 0..<5 { _ = vm.showsOpenAIKeyWarning }
        #expect(keyChecks == 1)
    }

    @Test func on_device_engines_never_show_the_key_warning() {
        let vm = openAIEngineVM(hasOpenAIKey: { false })
        vm.openAIKeyDidChange()
        vm.engine = .apple
        #expect(!vm.showsOpenAIKeyWarning)
        vm.engine = .whisperKit
        #expect(!vm.showsOpenAIKeyWarning)
    }

    @Test func key_warning_follows_the_stored_key() {
        var stored = false
        let vm = openAIEngineVM(hasOpenAIKey: { stored })
        vm.openAIKeyDidChange()
        #expect(vm.showsOpenAIKeyWarning)
        stored = true
        vm.openAIKeyDidChange()
        #expect(!vm.showsOpenAIKeyWarning)
    }

    @Test func recognition_shows_the_openai_key_row_only_when_cleanup_does_not() {
        let vm = openAIEngineVM(hasOpenAIKey: { false })
        vm.provider = .anthropic
        #expect(vm.showsOpenAIKeyInRecognition)
        vm.provider = .openai
        #expect(!vm.showsOpenAIKeyInRecognition)
        vm.provider = .anthropic
        vm.engine = .whisperKit
        #expect(!vm.showsOpenAIKeyInRecognition)
    }

    @Test func missing_key_warning_points_below_when_recognition_shows_the_key_row() {
        let vm = openAIEngineVM(hasOpenAIKey: { false })
        vm.openAIKeyDidChange()
        vm.provider = .anthropic
        #expect(vm.openAIKeyWarning == "Add an OpenAI API key below to use this engine.")
        vm.provider = .openai
        #expect(vm.openAIKeyWarning == "Add an OpenAI API key to use this engine.")
    }

    @Test func no_key_warning_once_a_key_is_stored() {
        let vm = openAIEngineVM(hasOpenAIKey: { true })
        vm.openAIKeyDidChange()
        #expect(vm.openAIKeyWarning == nil)
        vm.engine = .apple
        #expect(vm.openAIKeyWarning == nil)
    }

    @Test func provider_change_persists_and_calls_applier() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        let recorder = ApplyRecorder()
        let vm = GeneralSettingsViewModel(settings: settings, onApply: { recorder.record($0) })

        vm.provider = .openai
        #expect(recorder.applied?.provider == .openai)
        #expect(AppSettings(defaults: d).llmProvider == .openai)
    }

    @Test func launch_at_login_initialized_from_login_item_status() {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == true)
        #expect(vm.loginItemStatus == .enabled)
    }

    @Test func launch_at_login_disabled_when_not_registered() {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == false)
        #expect(vm.loginItemStatus == .disabled)
    }

    @Test func toggling_launch_at_login_to_true_calls_register() throws {
        let backend = StubLoginBackend(status: .notRegistered)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        vm.launchAtLogin = true
        #expect(backend.registerCount == 1)
        #expect(vm.loginItemStatus == .enabled)
        #expect(vm.launchAtLogin == true)
    }

    @Test func toggling_launch_at_login_to_false_calls_unregister() throws {
        let backend = StubLoginBackend(status: .enabled)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        vm.launchAtLogin = false
        #expect(backend.unregisterCount == 1)
        #expect(vm.loginItemStatus == .disabled)
        #expect(vm.launchAtLogin == false)
    }

    @Test func register_yielding_requires_approval_keeps_toggle_off() {
        let backend = StubLoginBackend(status: .notRegistered)
        backend.registerYields = .requiresApproval
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        vm.launchAtLogin = true
        #expect(vm.loginItemStatus == .requiresApproval)
        #expect(vm.launchAtLogin == false)
    }

    @Test func refresh_login_item_status_picks_up_external_approval() {
        let backend = StubLoginBackend(status: .requiresApproval)
        let svc = LoginItemService(backend: backend)
        let vm = GeneralSettingsViewModel(
            settings: AppSettings(defaults: defaults()),
            onApply: noopApply,
            loginItemService: svc
        )
        #expect(vm.launchAtLogin == false)
        backend.status = .enabled
        vm.refreshLoginItemStatus()
        #expect(vm.loginItemStatus == .enabled)
        #expect(vm.launchAtLogin == true)
    }

    /// Never reads the keychain, the real audio devices, or the standard
    /// defaults' vocabulary.
    private func hermeticVM(
        _ settings: AppSettings,
        onApply: @escaping (GeneralSettingsSnapshot) -> Void = noopApply
    ) -> GeneralSettingsViewModel {
        GeneralSettingsViewModel(
            settings: settings,
            onApply: onApply,
            deviceEnumerator: { [] },
            loginItemService: LoginItemService(),
            vocabulary: CustomVocabularyStore(defaults: settings.defaults),
            hasOpenAIKey: { false }
        )
    }

    @Test func loads_command_chord_and_model_on_init() {
        var settings = AppSettings(defaults: defaults())
        let command = HotkeyChord(modifierA: .rightCommand, modifierB: .rightOption)
        settings.commandChord = command
        settings.commandModel = "claude-opus-5-5"
        let vm = hermeticVM(settings)
        #expect(vm.commandChord == command)
        #expect(vm.commandModel == "claude-opus-5-5")
        #expect(vm.commandModeEnabled)
    }

    @Test func absent_command_model_loads_as_empty_text() {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        #expect(vm.commandModel == "")
    }

    @Test func snapshot_carries_the_command_chord_and_model() {
        let d = defaults()
        let recorder = ApplyRecorder()
        let vm = hermeticVM(AppSettings(defaults: d), onApply: { recorder.record($0) })

        let command = HotkeyChord(modifierA: .rightCommand, modifierB: .rightOption)
        vm.commandChord = command
        #expect(recorder.applied?.commandChord == command)
        #expect(AppSettings(defaults: d).commandChord == command)

        vm.commandModel = "claude-opus-5-5"
        #expect(recorder.applied?.commandModel == "claude-opus-5-5")
        #expect(AppSettings(defaults: d).commandModel == "claude-opus-5-5")

        vm.commandModel = ""
        #expect(recorder.applied?.commandModel == nil)
        #expect(AppSettings(defaults: d).commandModel == nil)
    }

    @Test func command_chord_refreshes_from_writes_made_elsewhere() {
        let d = defaults()
        let vm = hermeticVM(AppSettings(defaults: d))
        var elsewhere = AppSettings(defaults: d)
        elsewhere.commandChord = nil
        elsewhere.commandModel = "gpt-5"
        vm.refreshFromUserDefaults()
        #expect(vm.commandChord == nil)
        #expect(vm.commandModel == "gpt-5")
    }

    @Test func command_recorder_rejects_the_dictation_chord() {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        #expect(vm.validateCommandChord(vm.chord) == "That's your dictation hotkey")
        let reversed = HotkeyChord(modifierA: vm.chord.modifierB, modifierB: vm.chord.modifierA)
        #expect(vm.validateCommandChord(reversed) == "That's your dictation hotkey")
    }

    @Test func dictation_recorder_rejects_the_command_chord() throws {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        let command = try #require(vm.commandChord)
        #expect(vm.validateDictationChord(command) == "That's your command hotkey")
    }

    @Test func recorders_accept_chords_that_share_only_one_key() {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        let distinct = HotkeyChord(modifierA: .leftShift, modifierB: .rightCommand)
        #expect(vm.validateCommandChord(distinct) == nil)
        #expect(vm.validateDictationChord(distinct) == nil)
    }

    @Test func dictation_recorder_accepts_anything_while_command_mode_is_off() {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        vm.commandModeEnabled = false
        #expect(vm.validateDictationChord(.defaultCommand) == nil)
        #expect(vm.validateDictationChord(.default) == nil)
    }

    @Test func turning_command_mode_off_applies_a_nil_command_chord() {
        let d = defaults()
        let recorder = ApplyRecorder()
        let vm = hermeticVM(AppSettings(defaults: d), onApply: { recorder.record($0) })
        vm.commandModeEnabled = false
        #expect(vm.commandChord == nil)
        #expect(recorder.applied?.commandChord == nil)
        #expect(recorder.applied != nil)
        #expect(d.string(forKey: AppSettings.Key.commandChord) == "off")
        #expect(AppSettings(defaults: d).commandChord == nil)
    }

    @Test func turning_command_mode_on_uses_the_default_command_chord() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.commandChord = nil
        let recorder = ApplyRecorder()
        let vm = hermeticVM(settings, onApply: { recorder.record($0) })
        vm.commandModeEnabled = true
        #expect(vm.commandChord == .defaultCommand)
        #expect(recorder.applied?.commandChord == .defaultCommand)
    }

    @Test func turning_command_mode_on_avoids_the_dictation_chord() throws {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.hotkeyChord = HotkeyChord(modifierA: .leftShift, modifierB: .leftOption)
        settings.commandChord = nil
        let vm = hermeticVM(settings)
        vm.commandModeEnabled = true
        let command = try #require(vm.commandChord)
        #expect(command.keys != vm.chord.keys)
        #expect(command == HotkeyChord(modifierA: .leftShift, modifierB: .leftControl))
        #expect(vm.validateCommandChord(command) == nil)
    }

    @Test func changing_the_provider_clears_the_command_model() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.llmProvider = .anthropic
        settings.commandModel = "claude-opus-5-5"
        let recorder = ApplyRecorder()
        let vm = hermeticVM(settings, onApply: { recorder.record($0) })
        vm.provider = .openai
        #expect(vm.commandModel == "")
        #expect(recorder.applied?.commandModel == nil)
        #expect(AppSettings(defaults: d).commandModel == nil)
    }

    @Test func unrelated_changes_keep_the_command_model() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.commandModel = "claude-opus-5-5"
        let vm = hermeticVM(settings)
        vm.playHotkeySounds = false
        #expect(AppSettings(defaults: d).commandModel == "claude-opus-5-5")
    }

    @Test func reset_restores_both_chords_and_clears_the_command_model() {
        let d = defaults()
        var settings = AppSettings(defaults: d)
        settings.hotkeyChord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        settings.commandChord = nil
        settings.commandModel = "claude-opus-5-5"
        let recorder = ApplyRecorder()
        let vm = hermeticVM(settings, onApply: { recorder.record($0) })

        vm.resetToDefaults()

        #expect(vm.chord == .default)
        #expect(vm.commandChord == .defaultCommand)
        #expect(vm.commandModel == "")
        #expect(recorder.applied?.chord == .default)
        #expect(recorder.applied?.commandChord == .defaultCommand)
        #expect(recorder.applied?.commandModel == nil)
        #expect(AppSettings(defaults: d).commandChord == .defaultCommand)
        #expect(AppSettings(defaults: d).commandModel == nil)
    }

    @Test func command_model_placeholder_is_the_cleanup_model() {
        let d = defaults()
        let vm = hermeticVM(AppSettings(defaults: d))
        #expect(vm.cleanupModelPlaceholder == LLMProvider.anthropic.defaultModel)

        vm.provider = .openai
        #expect(vm.cleanupModelPlaceholder == LLMProvider.openai.defaultModel)

        var elsewhere = AppSettings(defaults: d)
        elsewhere.llmModel = "gpt-5"
        #expect(vm.cleanupModelPlaceholder == "gpt-5")
    }

    @Test func chords_combine_the_dictation_and_command_chords() {
        let vm = hermeticVM(AppSettings(defaults: defaults()))
        #expect(vm.chords == ChordSet(dictation: vm.chord, command: vm.commandChord))
        vm.commandModeEnabled = false
        #expect(vm.chords == ChordSet(dictation: vm.chord, command: nil))
    }

    @Test func reset_leaves_presets_alone() {
        let d = defaults()
        let custom = [PresetShortcut(
            id: UUID(),
            combo: KeyCombo(keyCode: 0, modifiers: .command),
            name: "Shout",
            instruction: "Make it louder."
        )]
        PresetStore(defaults: d).save(custom)
        let vm = hermeticVM(AppSettings(defaults: d))

        vm.resetToDefaults()

        #expect(PresetStore(defaults: d).load() == custom)
    }

}

private let noopApply: (GeneralSettingsSnapshot) -> Void = { _ in }

@MainActor
private final class ApplyRecorder {
    var applied: GeneralSettingsSnapshot?
    func record(_ snapshot: GeneralSettingsSnapshot) { applied = snapshot }
}
