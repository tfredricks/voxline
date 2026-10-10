import AppKit
import SwiftUI

/// The permission rows on Home and in the first-run wizard.
struct PermissionRows: View {
    let summary: PermissionsSummary
    /// The wizard asks only for the required permissions.
    var includesInputMonitoring = true
    var onChange: () -> Void = {}

    @State private var perms = PermissionsService()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(
                title: "Accessibility",
                tag: .required,
                detail: "Lets voxline listen for the global hotkey and paste text into other apps.",
                status: summary.accessibility,
                grantLabel: "Open System Settings",
                action: openAccessibilitySettings
            )
            row(
                title: "Microphone",
                tag: .required,
                detail: "Captures your voice for transcription.",
                status: summary.microphone,
                grantLabel: summary.microphone.microphoneGrantAction.label,
                action: { grantMicrophone(summary.microphone.microphoneGrantAction) }
            )
            if includesInputMonitoring {
                row(
                    title: "Input Monitoring",
                    tag: .recommended,
                    detail: "Improves global hotkey reliability on some Macs. Grant this if the hotkey doesn't trigger outside voxline's own window.",
                    status: summary.inputMonitoring,
                    grantLabel: "Grant",
                    action: openInputMonitoringSettings
                )
            }
        }
    }

    private enum RowTag {
        case required, recommended
        var label: String { self == .required ? "Required" : "Recommended" }
        var color: Color { self == .required ? .orange : .secondary }
    }

    private func row(
        title: String,
        tag: RowTag,
        detail: String,
        status: PermissionStatus,
        grantLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status == .granted ? .green : .red)
                .font(.title2)
                .frame(width: 26)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(tag.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(tag.color)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(tag.color.opacity(0.5)))
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(grantLabel, action: action)
                .disabled(status == .granted)
        }
    }

    private func grantMicrophone(_ action: PermissionGrantAction) {
        switch action {
        case .request:
            Task { _ = await perms.requestMicrophone(); onChange() }
        case .openSystemSettings:
            openSettingsPane("com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func openAccessibilitySettings() {
        perms.promptAccessibility()
        openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
    }

    private func openInputMonitoringSettings() {
        _ = perms.requestInputMonitoring()
        openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
        onChange()
    }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What a permission row's button does.
enum PermissionGrantAction: Equatable {
    /// Ask macOS, which prompts only while the user hasn't answered.
    case request
    case openSystemSettings

    var label: String {
        switch self {
        case .request: "Grant"
        case .openSystemSettings: "Open System Settings"
        }
    }
}

extension PermissionStatus {
    /// macOS asks for the microphone once. After "Don't Allow", or under a
    /// restriction, a request returns at once with no prompt, so only System
    /// Settings can grant it.
    var microphoneGrantAction: PermissionGrantAction {
        self == .denied ? .openSystemSettings : .request
    }
}
