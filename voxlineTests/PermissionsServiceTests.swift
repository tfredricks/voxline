import Testing
@testable import voxline

@Suite struct PermissionsServiceTests {

    @Test func microphoneStatusReturnsKnownValue() {
        let service = PermissionsService()
        let status = service.microphoneStatus
        // Whatever the runner's TCC state is, it must be one of these:
        #expect([.granted, .denied, .notDetermined].contains(status))
    }

    @Test func accessibilityStatusReturnsKnownValue() {
        let service = PermissionsService()
        let status = service.accessibilityStatus
        // Accessibility doesn't have a "notDetermined" state in the same way;
        // it's effectively granted-or-not.
        #expect([.granted, .denied].contains(status))
    }
}
