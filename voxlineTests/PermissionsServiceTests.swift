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

    // MARK: - PermissionsSummary.requiredGranted

    @Test func requiredGranted_trueOnlyWhenAccessibilityAndMicGranted() {
        #expect(PermissionsSummary(microphone: .granted, accessibility: .granted, inputMonitoring: .granted).requiredGranted)
        // Input Monitoring is NOT required — required set is satisfied without it.
        #expect(PermissionsSummary(microphone: .granted, accessibility: .granted, inputMonitoring: .denied).requiredGranted)
        #expect(PermissionsSummary(microphone: .granted, accessibility: .granted, inputMonitoring: .notDetermined).requiredGranted)
    }

    @Test func requiredGranted_falseWhenEitherRequiredMissing() {
        #expect(!PermissionsSummary(microphone: .denied, accessibility: .granted, inputMonitoring: .granted).requiredGranted)
        #expect(!PermissionsSummary(microphone: .granted, accessibility: .denied, inputMonitoring: .granted).requiredGranted)
        #expect(!PermissionsSummary(microphone: .notDetermined, accessibility: .granted, inputMonitoring: .granted).requiredGranted)
        #expect(!PermissionsSummary(microphone: .denied, accessibility: .denied, inputMonitoring: .denied).requiredGranted)
    }
}
