import AVFoundation
import ApplicationServices
import Foundation

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

struct PermissionsService {

    var microphoneStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .denied:        return .denied
        case .restricted:    return .denied
        case .notDetermined: return .notDetermined
        // Fail-closed: treat unknown future cases as denied so the first-run
        // wizard surfaces a "not granted" state rather than re-prompting in a loop.
        @unknown default:    return .denied
        }
    }

    var accessibilityStatus: PermissionStatus {
        // No prompting variant — just read current state.
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Triggers the system mic-access prompt if status is .notDetermined.
    /// Returns the resulting status.
    @discardableResult
    func requestMicrophone() async -> PermissionStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// Prompts the user (via AX prompt + System Settings deep link) to grant Accessibility.
    /// AX permission cannot be granted programmatically; this just nudges.
    func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }
}
