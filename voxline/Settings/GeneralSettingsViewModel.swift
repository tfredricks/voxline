import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?       // nil = system default
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord
    var audioInputDeviceUID: String?
    var whisperModel: WhisperModel
    var playHotkeySounds: Bool
    var lastError: String?

    var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]

    init(
        settings: AppSettings = AppSettings(),
        applier: GeneralSettingsApplier,
        deviceEnumerator: @escaping () -> [AudioDevice] = AudioDeviceEnumerator.inputDevices
    ) {
        self.settings = settings
        self.applier = applier
        self.deviceEnumerator = deviceEnumerator
        self.chord = settings.hotkeyChord
        self.audioInputDeviceUID = settings.audioInputDeviceUID
        self.whisperModel = settings.whisperModel
        self.playHotkeySounds = settings.playHotkeySounds
        self.devices = deviceEnumerator()
    }

    /// Picker rows including a synthetic "(disconnected)" entry when the
    /// saved UID is not currently enumerable. Keeps the Picker selection
    /// stable instead of going blank when a USB mic is unplugged.
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

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    func save() {
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
