// voxline/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {

    @State private var generalVM: GeneralSettingsViewModel
    @State private var apiKeysVM: APIKeysSettingsViewModel
    @State private var levelMonitor = MicLevelMonitor()
    @State private var status: SettingsStatusViewModel

    init(generalVM: GeneralSettingsViewModel, apiKeysVM: APIKeysSettingsViewModel) {
        _generalVM = State(wrappedValue: generalVM)
        _apiKeysVM = State(wrappedValue: apiKeysVM)
        _status = State(wrappedValue: SettingsStatusViewModel(general: generalVM, keys: apiKeysVM))
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
                        HStack(spacing: 8) {
                            Text("Live level")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .frame(width: 80, alignment: .leading)
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

                    Section("Feedback") {
                        Toggle("Play sound on record start/stop", isOn: $generalVM.playHotkeySounds)
                    }
                    .id(SettingsAnchor.feedback)

                    HStack {
                        Spacer()
                        Button("Reset to Defaults") { generalVM.resetToDefaults() }
                    }
                }
                .formStyle(.grouped)
            }
            .frame(minWidth: 540, idealWidth: 600, minHeight: 480, idealHeight: 560)
        }
        .onAppear {
            levelMonitor.preferredInputDeviceUID = generalVM.audioInputDeviceUID
            try? levelMonitor.start()
        }
        .onDisappear { levelMonitor.stop() }
        .onChange(of: generalVM.audioInputDeviceUID) { _, newValue in
            levelMonitor.stop()
            levelMonitor.preferredInputDeviceUID = newValue
            try? levelMonitor.start()
        }
    }
}
