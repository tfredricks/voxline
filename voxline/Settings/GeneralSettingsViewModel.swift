import Foundation
import Observation

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord
    var audioInputDeviceUID: String?
    var whisperModel: WhisperModel
    var playHotkeySounds: Bool
    var lastError: String?

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier

    init(settings: AppSettings = AppSettings(), applier: GeneralSettingsApplier) {
        self.settings = settings
        self.applier = applier
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
    }

    func save() throws {
        var s = settings
        s.hotkeyChord = chord
        s.audioInputDeviceUID = audioInputDeviceUID
        s.whisperModel = whisperModel
        s.playHotkeySounds = playHotkeySounds
        settings = s
        applier.apply(GeneralSettingsSnapshot(
            chord: chord,
            audioInputDeviceUID: audioInputDeviceUID,
            whisperModel: whisperModel,
            playHotkeySounds: playHotkeySounds
        ))
    }
}
