import Testing
import Foundation
@testable import voxline

@Suite struct HotkeySoundPlayerTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private final class Recorder {
        var played: [String] = []
        func capture(_ name: String) { played.append(name) }
    }

    @Test func play_start_uses_tink_when_enabled() {
        let settings = AppSettings(defaults: makeDefaults()) // default true
        let rec = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: rec.capture)
        player.playStart()
        #expect(rec.played == [HotkeySoundPlayer.startSoundName])
    }

    @Test func play_stop_uses_pop_when_enabled() {
        let settings = AppSettings(defaults: makeDefaults())
        let rec = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: rec.capture)
        player.playStop()
        #expect(rec.played == [HotkeySoundPlayer.stopSoundName])
    }

    @Test func play_start_and_stop_are_silent_when_disabled() {
        let d = makeDefaults()
        var settings = AppSettings(defaults: d)
        settings.playHotkeySounds = false
        let rec = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: rec.capture)
        player.playStart()
        player.playStop()
        #expect(rec.played.isEmpty)
    }

    @Test func prime_plays_the_start_sound_silently_and_nothing_audibly() {
        let settings = AppSettings(defaults: makeDefaults())
        let audible = Recorder()
        let silent = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: audible.capture, primeSound: silent.capture)
        player.prime()
        #expect(silent.played == [HotkeySoundPlayer.startSoundName])
        #expect(audible.played.isEmpty)
    }

    @Test func prime_runs_even_when_sounds_are_disabled() {
        let d = makeDefaults()
        var settings = AppSettings(defaults: d)
        settings.playHotkeySounds = false
        let silent = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: { _ in }, primeSound: silent.capture)
        player.prime()
        #expect(silent.played == [HotkeySoundPlayer.startSoundName], "priming is silent, so it costs nothing to keep the output path warm for a later toggle")
    }

    @Test func toggle_takes_effect_on_next_call() {
        let d = makeDefaults()
        var settings = AppSettings(defaults: d)
        let rec = Recorder()
        let player = HotkeySoundPlayer(settings: settings, playSound: rec.capture)

        player.playStart() // enabled by default
        settings.playHotkeySounds = false
        player.playStop() // should be skipped

        #expect(rec.played == [HotkeySoundPlayer.startSoundName])
    }
}
