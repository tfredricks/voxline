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
    private let primeSound: (String) -> Void

    init(
        settings: AppSettings = AppSettings(),
        playSound: @escaping (String) -> Void = HotkeySoundPlayer.playSystemSound,
        primeSound: @escaping (String) -> Void = HotkeySoundPlayer.playSystemSoundSilently
    ) {
        self.settings = settings
        self.playSound = playSound
        self.primeSound = primeSound
    }

    /// Opens the audio output path with a silent play. The first audible play
    /// after launch otherwise stalls the caller for ~150 ms, which on the
    /// start cue is time the user spends speaking into a mic that isn't
    /// capturing yet. Runs regardless of the sounds setting, since it is
    /// silent and a later toggle would pay the stall.
    func prime() {
        primeSound(Self.startSoundName)
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

    private static func playSystemSoundSilently(_ name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0
        sound.play()
    }
}
