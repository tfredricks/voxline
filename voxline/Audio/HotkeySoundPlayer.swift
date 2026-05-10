import AppKit
import Foundation

/// Plays short system sounds when the hold-to-talk chord is pressed and released.
/// Reads `AppSettings.playHotkeySounds` on each call so toggling the setting
/// takes effect on the next chord without any signaling.
final class HotkeySoundPlayer {

    static let startSoundName = "Tink"
    static let stopSoundName = "Pop"

    private let settings: AppSettings
    private let playSound: (String) -> Void

    init(
        settings: AppSettings = AppSettings(),
        playSound: @escaping (String) -> Void = HotkeySoundPlayer.playSystemSound
    ) {
        self.settings = settings
        self.playSound = playSound
    }

    func playStart() {
        guard settings.playHotkeySounds else { return }
        playSound(Self.startSoundName)
    }

    func playStop() {
        guard settings.playHotkeySounds else { return }
        playSound(Self.stopSoundName)
    }

    private static func playSystemSound(_ name: String) {
        NSSound(named: name)?.play()
    }
}
