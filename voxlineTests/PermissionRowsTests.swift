import Testing
@testable import voxline

@Suite struct PermissionRowsTests {

    @Test func undecided_microphone_asks_macos() {
        let action = PermissionStatus.notDetermined.microphoneGrantAction
        #expect(action == .request)
        #expect(action.label == "Grant")
    }

    @Test func denied_microphone_opens_system_settings() {
        let action = PermissionStatus.denied.microphoneGrantAction
        #expect(action == .openSystemSettings)
        #expect(action.label == "Open System Settings")
    }

    @Test func granted_microphone_keeps_the_grant_label() {
        #expect(PermissionStatus.granted.microphoneGrantAction.label == "Grant")
    }
}
