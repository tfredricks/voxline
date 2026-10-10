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
    private let primeSound: ((String) -> Void)?
    private var primer: NSSound?

    /// `primeSound` replaces the silent system play in tests.
    init(
        settings: AppSettings = AppSettings(),
        playSound: @escaping (String) -> Void = HotkeySoundPlayer.playSystemSound,
        primeSound: ((String) -> Void)? = nil
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
        if let primeSound {
            primeSound(Self.startSoundName)
        } else {
            primer = Self.playSystemSoundSilently(Self.startSoundName)
        }
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

    /// Plays a muted copy of the named sound and returns it; the caller keeps
    /// it until it finishes. `NSSound(named:)` hands out one shared instance
    /// per name, the one `playSystemSound` plays, so muting that instance
    /// would silence the cue for the rest of the session.
    @discardableResult
    static func playSystemSoundSilently(_ name: String) -> NSSound? {
        guard let sound = NSSound(named: name)?.copy() as? NSSound else { return nil }
        sound.volume = 0
        sound.play()
        return sound
    }
}
