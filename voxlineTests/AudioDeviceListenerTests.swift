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
        #expect(fired >= 0)   // sanity: no crash
    }
}
