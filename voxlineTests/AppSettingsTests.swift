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
}
