import AppKit
import SwiftUI

/// Standalone permissions panel shown outside the first-run wizard: at launch
/// when a required permission is missing, on runtime revocation, or from the
/// menu-bar "Fix permissions…" item. Polls live and calls `onRequiredGranted`
/// once Accessibility + Microphone are both granted so the host window can
/// auto-close.
struct PermissionsStatusView: View {
    var onRequiredGranted: () -> Void = {}

    @State private var perms = PermissionsService()
    @State private var summary = PermissionsSummary(
        microphone: .notDetermined, accessibility: .notDetermined, inputMonitoring: .notDetermined
    )
    @State private var pollTimer: Timer?
    /// Only auto-close once the window has actually observed a missing required
    /// permission and then seen it granted — i.e. the user just fixed it.
    /// Otherwise opening "Check Permissions" while everything is already
    /// granted would close the window in the same frame it appears.
    @State private var sawRequiredMissing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("voxline needs permissions").font(.title2.bold())
                Text("Grant the required permissions so the hotkey, transcription, and paste work everywhere. This window closes itself once the required permissions are granted.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
                detail: "Captures your voice for on-device transcription.",
                status: summary.microphone,
                grantLabel: "Grant",
                action: { Task { _ = await perms.requestMicrophone(); refresh() } }
            )

            row(
                title: "Input Monitoring",
                tag: .recommended,
                detail: "Improves global hotkey reliability on some Macs. Grant this if the hotkey doesn't trigger outside voxline's own window.",
                status: summary.inputMonitoring,
                grantLabel: "Grant",
                action: openInputMonitoringSettings
            )
        }
        .padding(32)
        .frame(width: 540, alignment: .leading)
        .onAppear { start() }
        .onDisappear { stop() }
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
            Image(systemName: statusSymbol(status))
                .foregroundStyle(statusColor(status))
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

    private func statusSymbol(_ s: PermissionStatus) -> String {
        s == .granted ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private func statusColor(_ s: PermissionStatus) -> Color {
        s == .granted ? .green : .red
    }

    private func openAccessibilitySettings() {
        perms.promptAccessibility()
        openSettingsPane("com.apple.preference.security?Privacy_Accessibility")
    }

    private func openInputMonitoringSettings() {
        // Trigger the system prompt the first time; then deep-link so the user
        // can flip the toggle if it was previously denied.
        _ = perms.requestInputMonitoring()
        openSettingsPane("com.apple.preference.security?Privacy_ListenEvent")
        refresh()
    }

    private func openSettingsPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        summary = perms.summary()
        if summary.requiredGranted {
            // Close only if we previously saw a missing required permission
            // (the user just granted it). Opening the panel with everything
            // already granted keeps it up so the user can review status and
            // grant the recommended Input Monitoring.
            if sawRequiredMissing { onRequiredGranted() }
        } else {
            sawRequiredMissing = true
        }
    }
}
