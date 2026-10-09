import AppKit
import SwiftUI

struct MeetingsSettingsPage: View {
    @Bindable var model: MeetingSettingsViewModel

    var body: some View {
        SettingsPage(.meetings) {
            Section("Recording") {
                LabeledContent("Start/stop shortcut") {
                    HStack(spacing: 8) {
                        KeyComboRecorderView(combo: model.shortcut, onRecord: { model.updateShortcut($0) })
                        if model.shortcut != nil {
                            Button("Clear") { model.clearShortcut() }
                        }
                    }
                }
                Toggle("Show recording timer", isOn: $model.showTimer)
                Toggle("Live transcript", isOn: $model.liveTranscript)
                    .disabled(!model.showTimer)
                Text("Shows the last few things said in the recording timer. Transcribed on this Mac with Apple Speech; nothing is saved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("Keep meeting audio", selection: $model.retention) {
                    ForEach(MeetingAudioRetention.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Text("Meetings record your microphone and your Mac's sound output for up to 60 minutes. Audio stays on this Mac; only the transcript goes to your LLM provider to write the notes. Use headphones on calls for the cleanest transcript.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Notes") {
                LabeledContent("Notes folder") {
                    HStack(spacing: 8) {
                        Text(model.notesFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                TextField("Meeting notes model", text: $model.notesModel, prompt: Text(model.notesModelPlaceholder))
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.notesFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.setNotesFolder(url)
        }
    }
}
