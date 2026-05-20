// voxline/Settings/SettingsView.swift
import SwiftUI
import AppKit

struct SettingsView: View {

    @Environment(AppState.self) private var appState
    @Environment(UpdateService.self) private var updateService
    @State private var generalVM: GeneralSettingsViewModel
    @State private var apiKeysVM: APIKeysSettingsViewModel
    @State private var levelMonitor = MicLevelMonitor()
    @State private var status: SettingsStatusViewModel
    @State private var vocabularyVM: CustomVocabularyListViewModel

    init(
        generalVM: GeneralSettingsViewModel,
        apiKeysVM: APIKeysSettingsViewModel
    ) {
        _generalVM = State(wrappedValue: generalVM)
        _apiKeysVM = State(wrappedValue: apiKeysVM)
        _status = State(wrappedValue: SettingsStatusViewModel(general: generalVM, keys: apiKeysVM))
        _vocabularyVM = State(wrappedValue: CustomVocabularyListViewModel(
            store: CustomVocabularyStore()
        ))
    }

    var body: some View {
        @Bindable var generalVM = generalVM
        @Bindable var apiKeysVM = apiKeysVM

        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                SettingsStatusStrip(status: status) { anchor in
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                }

                Form {
                    Section("Startup") {
                        Toggle("Launch Voxline at login", isOn: $generalVM.launchAtLogin)
                        if generalVM.loginItemStatus == .requiresApproval {
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
                    }

                    Section("Software Updates") {
                        @Bindable var updateService = updateService
                        Toggle("Automatically check for updates",
                               isOn: $updateService.automaticallyChecksForUpdates)
                        Text("Voxline checks once a day in the background and shows a small badge on the menu-bar icon when an update is ready. Click \"Check for updates…\" in the menu to check manually.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Section("Hotkey") {
                        ChordRecorderView(chord: $generalVM.chord)
                    }
                    .id(SettingsAnchor.hotkey)

                    Section("Microphone") {
                        Picker("Input device", selection: $generalVM.audioInputDeviceUID) {
                            ForEach(generalVM.deviceRows) { row in
                                Text(row.label).tag(row.uid)
                            }
                        }
                        HStack(spacing: 6) {
                            Text("Live level")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                            MicLevelMeter(monitor: levelMonitor)
                        }
                    }
                    .id(SettingsAnchor.microphone)

                    Section("Recognition") {
                        Picker("Whisper model", selection: $generalVM.whisperModel) {
                            ForEach(WhisperModel.allCases, id: \.self) { m in
                                let cached = TranscriptionService.isModelCached(m)
                                let label = cached
                                    ? "\(m.displayName) — ✓ downloaded"
                                    : "\(m.displayName) — to download · \(m.approxSizeMB) MB"
                                Text(label).tag(m)
                            }
                        }
                        Text("Switching downloads the new model on demand.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    .id(SettingsAnchor.recognition)

                    CleanupSection(general: generalVM, keys: apiKeysVM)
                        .id(SettingsAnchor.cleanup)

                    CustomVocabularyListView(viewModel: vocabularyVM)
                        .id(SettingsAnchor.customVocabulary)

                    Section("Feedback") {
                        Toggle("Play sound on record start/stop", isOn: $generalVM.playHotkeySounds)
                    }
                    .id(SettingsAnchor.feedback)

                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            generalVM.resetToDefaults()
                            vocabularyVM.reload()
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            .frame(minWidth: 440, idealWidth: 460, maxWidth: 520, minHeight: 460, idealHeight: 540)
        }
        .task {
            generalVM.refreshFromUserDefaults()
            generalVM.refreshLoginItemStatus()
        }
        .onAppear {
            levelMonitor.preferredInputDeviceUID = generalVM.audioInputDeviceUID
            startMonitorIfAllowed()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: generalVM.audioInputDeviceUID) { _, newValue in
            levelMonitor.stop()
            levelMonitor.preferredInputDeviceUID = newValue
            startMonitorIfAllowed()
        }
        .onChange(of: appState.status) { _, newStatus in
            if newStatus == .recording {
                levelMonitor.stop()
            } else {
                startMonitorIfAllowed()
            }
        }
    }

    private func startMonitorIfAllowed() {
        guard appState.status != .recording else { return }
        try? levelMonitor.start()
    }
}
