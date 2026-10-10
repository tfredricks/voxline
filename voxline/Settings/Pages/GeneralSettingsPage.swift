import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var general: GeneralSettingsViewModel
    @Environment(UpdateService.self) private var updateService
    @State private var confirmingReset = false

    var body: some View {
        @Bindable var updateService = updateService
        SettingsPage(.general) {
            Section("Startup") {
                Toggle("Launch Voxline at login", isOn: $general.launchAtLogin)
                if general.loginItemStatus == .requiresApproval {
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(
                            "Approval required — open Login Items in System Settings",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.link)
                }
                Toggle("Show Voxline in Dock", isOn: $general.showInDock)
                Text("When off, Voxline appears in the Dock only while its window is open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $updateService.automaticallyChecksForUpdates)
                Text("Voxline checks once a day and shows a badge on the menu-bar icon when an update is ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Sounds") {
                Toggle("Play sound on record start/stop", isOn: $general.playHotkeySounds)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults…") { confirmingReset = true }
                }
            }
        }
        .task { general.refreshLoginItemStatus() }
        .confirmationDialog("Reset settings to defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { general.resetToDefaults() }
        } message: {
            Text("Hotkeys, microphone, recognition, AI provider, command model and sounds go back to their defaults. API keys, presets, vocabulary, learning and meeting settings stay, except a meeting notes model when the provider changes.")
        }
    }
}
