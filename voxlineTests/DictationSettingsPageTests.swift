import SwiftUI
import Testing
@testable import voxline

@Suite struct DictationSettingsPageTests {

    @Test func level_meter_runs_while_the_window_is_in_front() {
        #expect(DictationSettingsPage.monitorsLevel(status: .idle, windowActivity: .key))
        #expect(DictationSettingsPage.monitorsLevel(status: .idle, windowActivity: .active))
        #expect(DictationSettingsPage.monitorsLevel(status: .thinking, windowActivity: .key))
    }

    @Test func level_meter_stops_when_the_window_is_inactive() {
        #expect(!DictationSettingsPage.monitorsLevel(status: .idle, windowActivity: .inactive))
    }

    @Test func level_meter_stops_while_recording() {
        #expect(!DictationSettingsPage.monitorsLevel(status: .recording, windowActivity: .key))
        #expect(!DictationSettingsPage.monitorsLevel(status: .recording, windowActivity: .inactive))
    }
}
