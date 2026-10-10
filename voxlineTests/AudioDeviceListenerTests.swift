import CoreAudio
import Testing
import Foundation
@testable import voxline

@Suite struct AudioDeviceListenerTests {

    @Test func listener_installs_and_uninstalls_without_crashing() {
        // We can't reliably trigger device-change events from a unit test on
        // CI, so we just verify the listener can be constructed and torn down
        // without hitting CoreAudio errors that would crash the process.
        var fired = 0
        do {
            let listener = AudioDeviceListener { fired += 1 }
            _ = listener   // silence "unused" — we want it alive in the scope
        }
        #expect(fired == 0)   // no spurious callback at install or teardown
    }

    @Test func listens_for_a_new_system_default_input_as_well_as_the_device_list() {
        #expect(AudioDeviceListener.watchedSelectors.contains(kAudioHardwarePropertyDevices))
        #expect(AudioDeviceListener.watchedSelectors.contains(kAudioHardwarePropertyDefaultInputDevice), "the picker's (default) suffix follows System Settings → Sound")
    }
}
