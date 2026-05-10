import Foundation

/// Snapshot the General settings VM hands to the coordinator on save.
struct GeneralSettingsSnapshot: Equatable {
    let chord: HotkeyChord
    let audioInputDeviceUID: String?
    let whisperModel: WhisperModel
    let playHotkeySounds: Bool
}

/// Coordinator hook: receive a saved snapshot and apply it to running services.
@MainActor
protocol GeneralSettingsApplier {
    func apply(_ snapshot: GeneralSettingsSnapshot)
}
