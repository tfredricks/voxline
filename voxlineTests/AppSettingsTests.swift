import Testing
import Foundation
@testable import voxline

@Suite struct AppSettingsTests {

    /// Per-test isolated suite so we don't trample the user's real defaults.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func unset_provider_defaults_to_anthropic() {
        let s = AppSettings(defaults: makeDefaults())
        #expect(s.llmProvider == .anthropic)
    }

    @Test func set_provider_round_trips() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .openai
        #expect(AppSettings(defaults: defaults).llmProvider == .openai)
    }

    @Test func default_model_per_provider_matches_spec() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        #expect(s.llmModel == "claude-haiku-4-5")
        s.llmProvider = .openai
        #expect(s.llmModel == "gpt-4.1-nano")
    }

    @Test func explicit_model_override_persists_across_provider_switch() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        s.llmModel = "claude-3-5-sonnet-latest"
        #expect(s.llmModel == "claude-3-5-sonnet-latest")
        s.llmProvider = .openai
        // Changing provider clears the model override (spec default returns).
        #expect(s.llmModel == "gpt-4.1-nano")
    }

    @Test func reassigning_same_provider_preserves_model_override() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        s.llmModel = "claude-3-5-sonnet-latest"
        #expect(s.llmModel == "claude-3-5-sonnet-latest")

        // Re-writing the SAME provider must not clear the model override.
        // Without this guard, every unrelated settings change that flows
        // through GeneralSettingsViewModel.commit() wipes the override
        // (commit() writes every field on every change, including provider).
        s.llmProvider = .anthropic
        #expect(s.llmModel == "claude-3-5-sonnet-latest")
    }

    @Test func reassigning_same_provider_when_no_override_is_a_noop() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        // No explicit model set — llmModel returns the spec default.
        #expect(s.llmModel == LLMProvider.anthropic.defaultModel)
        s.llmProvider = .anthropic
        #expect(s.llmModel == LLMProvider.anthropic.defaultModel)
    }

    @Test func unset_hotkey_chord_returns_default() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: d).hotkeyChord == .default)
    }

    @Test func hotkey_chord_round_trips() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        var s = AppSettings(defaults: d)
        let chord = HotkeyChord(modifierA: .leftCommand, modifierB: .leftShift)
        s.hotkeyChord = chord
        #expect(AppSettings(defaults: d).hotkeyChord == chord)
    }

    @Test func unset_audio_input_device_uid_is_nil() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: d).audioInputDeviceUID == nil)
    }

    @Test func audio_input_device_uid_round_trips() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        var s = AppSettings(defaults: d)
        s.audioInputDeviceUID = "BuiltInMicrophoneDevice"
        #expect(AppSettings(defaults: d).audioInputDeviceUID == "BuiltInMicrophoneDevice")
        s.audioInputDeviceUID = nil
        #expect(AppSettings(defaults: d).audioInputDeviceUID == nil)
    }

    @Test func unset_whisper_model_returns_default() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: d).whisperModel == .default)
    }

    @Test func whisper_model_round_trips() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        var s = AppSettings(defaults: d)
        s.whisperModel = .smallEn
        #expect(AppSettings(defaults: d).whisperModel == .smallEn)
    }

    @Test func first_run_flag_defaults_false_and_round_trips() {
        let d = UserDefaults(suiteName: "voxline-test-\(UUID().uuidString)")!
        #expect(AppSettings(defaults: d).hasCompletedFirstRun == false)
        var s = AppSettings(defaults: d)
        s.hasCompletedFirstRun = true
        #expect(AppSettings(defaults: d).hasCompletedFirstRun == true)
    }

    @Test func play_hotkey_sounds_defaults_to_true_when_unset() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).playHotkeySounds == true)
    }

    @Test func play_hotkey_sounds_round_trips_true_and_false() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.playHotkeySounds = false
        #expect(AppSettings(defaults: d).playHotkeySounds == false)
        s.playHotkeySounds = true
        #expect(AppSettings(defaults: d).playHotkeySounds == true)
    }

    @Test func unset_command_chord_with_default_dictation_is_the_default_command_chord() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).commandChord == .defaultCommand)
    }

    @Test func unset_command_chord_is_off_when_dictation_uses_the_default_command_keys() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.hotkeyChord = HotkeyChord(modifierA: .leftShift, modifierB: .leftOption)
        #expect(AppSettings(defaults: d).commandChord == nil)
    }

    @Test func command_chord_round_trips() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        let chord = HotkeyChord(modifierA: .rightCommand, modifierB: .rightOption)
        s.commandChord = chord
        #expect(AppSettings(defaults: d).commandChord == chord)
    }

    @Test func command_chord_off_is_stored_as_off_and_reads_nil() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.commandChord = nil
        #expect(d.string(forKey: AppSettings.Key.commandChord) == "off")
        #expect(AppSettings(defaults: d).commandChord == nil)
    }

    @Test func command_chord_keys_match_the_spec() {
        #expect(AppSettings.Key.commandChord == "voxline.hotkey.commandChord")
        #expect(AppSettings.Key.commandModel == "voxline.llm.commandModel")
    }

    @Test func chords_pair_the_dictation_and_command_chords() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        let dictation = HotkeyChord(modifierA: .rightCommand, modifierB: .rightShift)
        let command = HotkeyChord(modifierA: .rightCommand, modifierB: .rightOption)
        s.hotkeyChord = dictation
        s.commandChord = command
        #expect(s.chords == ChordSet(dictation: dictation, command: command))
        s.commandChord = nil
        #expect(s.chords == ChordSet(dictation: dictation, command: nil))
    }

    @Test func chord_families_cover_both_chords_for_the_paste_release_gate() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.hotkeyChord = .default
        s.commandChord = HotkeyChord(modifierA: .leftShift, modifierB: .rightCommand)
        #expect(s.chords.families == [.shift, .control, .command])
        s.commandChord = nil
        #expect(s.chords.families == [.shift, .control])
    }

    @Test func command_model_is_nil_when_absent() {
        #expect(AppSettings(defaults: makeDefaults()).commandModel == nil)
    }

    @Test func blank_command_model_reads_nil_and_removes_the_key() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.commandModel = "claude-opus-5-5"
        s.commandModel = "  "
        #expect(AppSettings(defaults: d).commandModel == nil)
        #expect(d.object(forKey: AppSettings.Key.commandModel) == nil)
    }

    @Test func blank_stored_command_model_reads_nil() {
        let d = makeDefaults()
        d.set("  ", forKey: AppSettings.Key.commandModel)
        #expect(AppSettings(defaults: d).commandModel == nil)
    }

    @Test func command_model_round_trips_and_nil_removes_it() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.commandModel = "claude-opus-5-5"
        #expect(AppSettings(defaults: d).commandModel == "claude-opus-5-5")
        s.commandModel = nil
        #expect(AppSettings(defaults: d).commandModel == nil)
        #expect(d.object(forKey: AppSettings.Key.commandModel) == nil)
    }

    @Test func command_model_is_cleared_when_the_provider_changes() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.llmProvider = .anthropic
        s.commandModel = "claude-opus-5-5"
        s.llmProvider = .openai
        #expect(AppSettings(defaults: d).commandModel == nil)
    }

    @Test func command_model_survives_reassigning_the_same_provider() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.llmProvider = .anthropic
        s.commandModel = "claude-opus-5-5"
        s.llmProvider = .anthropic
        #expect(AppSettings(defaults: d).commandModel == "claude-opus-5-5")
    }

    @Test func unset_transcription_engine_defaults_to_engine_default() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).transcriptionEngine == EngineID.default)
    }

    @Test func transcription_engine_round_trips() {
        let d = makeDefaults()
        var s = AppSettings(defaults: d)
        s.transcriptionEngine = .apple
        #expect(AppSettings(defaults: d).transcriptionEngine == .apple)
        s.transcriptionEngine = .openAIRealtime
        #expect(AppSettings(defaults: d).transcriptionEngine == .openAIRealtime)
    }

    @Test func unknown_transcription_engine_raw_value_falls_back_to_default() {
        let d = makeDefaults()
        d.set("not-an-engine", forKey: AppSettings.Key.transcriptionEngine)
        #expect(AppSettings(defaults: d).transcriptionEngine == EngineID.default)
    }

    @Test func skip_short_utterances_defaults_false_and_round_trips() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).skipShortUtterances == false)
        var s = AppSettings(defaults: d)
        s.skipShortUtterances = true
        #expect(AppSettings(defaults: d).skipShortUtterances == true)
        #expect(d.bool(forKey: "voxline.llm.skipShortUtterances") == true)
    }

    @Test func save_bakeoff_clips_defaults_false_and_round_trips() {
        let d = makeDefaults()
        #expect(AppSettings(defaults: d).saveBakeoffClips == false)
        var s = AppSettings(defaults: d)
        s.saveBakeoffClips = true
        #expect(AppSettings(defaults: d).saveBakeoffClips == true)
        #expect(d.bool(forKey: "voxline.debug.saveBakeoffClips") == true)
        s.saveBakeoffClips = false
        #expect(AppSettings(defaults: d).saveBakeoffClips == false)
    }

    @Test func learning_toggles_default_on_and_persist() {
        var settings = AppSettings(defaults: makeDefaults())
        #expect(settings.learnWords)
        #expect(settings.learnStyle)
        settings.learnWords = false
        settings.learnStyle = false
        #expect(!settings.learnWords)
        #expect(!settings.learnStyle)
        #expect(settings.defaults.object(forKey: AppSettings.Key.learnWords) as? Bool == false)
    }

    @Test func show_in_dock_defaults_to_false() {
        #expect(AppSettings(defaults: makeDefaults()).showInDock == false)
    }

    @Test func show_in_dock_round_trips() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.showInDock = true
        #expect(AppSettings(defaults: defaults).showInDock == true)
        #expect(defaults.bool(forKey: "voxline.showInDock") == true)
    }
}
