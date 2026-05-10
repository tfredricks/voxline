import Foundation
import Observation

struct AudioDeviceRow: Identifiable, Equatable {
    let uid: String?
    let label: String
    var id: String { uid ?? "__system_default__" }
}

@Observable
@MainActor
final class GeneralSettingsViewModel {

    var chord: HotkeyChord { didSet { if loaded { commit() } } }
    var audioInputDeviceUID: String? { didSet { if loaded { commit() } } }
    var whisperModel: WhisperModel { didSet { if loaded { commit() } } }
    var playHotkeySounds: Bool { didSet { if loaded { commit() } } }

    private(set) var devices: [AudioDevice] = []

    private var settings: AppSettings
    private let applier: GeneralSettingsApplier
    private let deviceEnumerator: () -> [AudioDevice]
    private var deviceListener: AudioDeviceListener?
    private var loaded = false

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

    func refreshDevices() {
        devices = deviceEnumerator()
    }

    /// Restore Spec defaults: hotkey to Left Ctrl + Left Option, system-default
    /// mic, large-v3-turbo, sounds on. Performs one batched commit so the
    /// applier sees a single coherent snapshot rather than four partial ones.
    func resetToDefaults() {
        loaded = false
        chord = .default
        audioInputDeviceUID = nil
        whisperModel = .default
        playHotkeySounds = true
        loaded = true
        commit()
    }

    private func commit() {
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
