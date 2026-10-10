// voxline/Wizard/WizardPermissionsView.swift
import SwiftUI

struct WizardPermissionsView: View {
    @Binding var allGranted: Bool
    @State private var perms = PermissionsService()
    @State private var summary = PermissionsSummary(
        microphone: .notDetermined,
        accessibility: .notDetermined,
        inputMonitoring: .notDetermined
    )
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Grant permissions").font(.title.bold())
            Text("Voxline needs two macOS permissions. Grant each, then continue.")
                .foregroundStyle(.secondary)

            PermissionRows(summary: summary, includesInputMonitoring: false, onChange: refresh)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
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
        summary = perms.summary()
        allGranted = summary.requiredGranted
    }
}
