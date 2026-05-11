// voxline/Wizard/WizardPermissionsView.swift
import AppKit
import SwiftUI

struct WizardPermissionsView: View {
    @State private var perms = PermissionsService()
    @State private var mic: PermissionStatus = .notDetermined
    @State private var ax: PermissionStatus = .notDetermined
    @State private var im: PermissionStatus = .notDetermined
    @State private var pollTimer: Timer?

    var allGranted: Bool { mic == .granted && ax == .granted && im == .granted }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant permissions").font(.title.bold())
            Text("voxline needs three macOS permissions. Grant each, then continue.")
                .foregroundStyle(.secondary)

            permissionRow(
                title: "Microphone",
                detail: "To capture your voice for transcription.",
                status: mic,
                grantLabel: "Grant",
                action: { Task { mic = await perms.requestMicrophone() } }
            )

            permissionRow(
                title: "Accessibility",
                detail: "To listen for the hold-to-talk hotkey and paste cleaned text.",
                status: ax,
                grantLabel: "Open System Settings",
                action: openAccessibilitySettings
            )

            permissionRow(
                title: "Input Monitoring",
                detail: "Required for the hotkey to work outside voxline itself.",
                status: im,
                grantLabel: "Grant",
                action: { im = perms.requestInputMonitoring() }
            )
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionStatus,
        grantLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: statusSymbol(status))
                .foregroundStyle(statusColor(status))
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(grantLabel, action: action)
                .disabled(status == .granted)
        }
    }

    private func statusSymbol(_ s: PermissionStatus) -> String {
        switch s {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .notDetermined: return "circle"
        }
    }

    private func statusColor(_ s: PermissionStatus) -> Color {
        switch s {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined: return .secondary
        }
    }

    private func openAccessibilitySettings() {
        perms.promptAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPolling() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func refresh() {
        mic = perms.microphoneStatus
        ax = perms.accessibilityStatus
        im = perms.inputMonitoringStatus
    }
}
