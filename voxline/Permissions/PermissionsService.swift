import AVFoundation
import ApplicationServices
import Foundation
import IOKit.hid

enum PermissionStatus: Equatable {
    case granted
    case denied
    case notDetermined
}

/// Immutable snapshot of the three permission states plus the required-set
/// predicate. A pure value type so the "which are required" policy is
/// unit-testable without touching live system APIs.
struct PermissionsSummary: Equatable {
    let microphone: PermissionStatus
    let accessibility: PermissionStatus
    let inputMonitoring: PermissionStatus

    /// Accessibility (global hotkey tap + paste) and Microphone (recording)
    /// are hard requirements — the app can't function without them. Input
    /// Monitoring is recommended for hotkey reliability on some Macs but is
    /// not required to run.
    var requiredGranted: Bool {
        accessibility == .granted && microphone == .granted
    }
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

    /// Input Monitoring is a separate TCC category from Accessibility.
    /// Best-effort, not required: a session-level CGEventTap with .listenOnly
    /// on .flagsChanged generally works with Accessibility alone. We still
    /// read and prompt because some macOS configurations report a more
    /// reliable tap once IM is also granted. Surfaced in the Debug pane.
    var inputMonitoringStatus: PermissionStatus {
        let result = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if result == kIOHIDAccessTypeGranted { return .granted }
        if result == kIOHIDAccessTypeDenied  { return .denied }
        return .notDetermined
    }

    /// Triggers the system Input Monitoring prompt the first time it's called.
    /// On subsequent calls (after the user has actioned the dialog) it just
    /// returns the current state. The TCC prompt is asynchronous in the sense
    /// that the user has to action it; this returns the state at call time.
    @discardableResult
    func requestInputMonitoring() -> PermissionStatus {
        return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? .granted : .denied
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

    /// Live snapshot of all three permission states.
    func summary() -> PermissionsSummary {
        PermissionsSummary(
            microphone: microphoneStatus,
            accessibility: accessibilityStatus,
            inputMonitoring: inputMonitoringStatus
        )
    }
}
