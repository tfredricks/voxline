// voxline/Wizard/WizardModelDownloadView.swift
import SwiftUI

struct WizardModelDownloadView: View {
    @Bindable var state: AppState
    let model: WhisperModel
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download speech recognition model").font(.title.bold())
            Text("\(model.displayName) — about \(model.approxSizeMB) MB. Runs entirely on your Mac; audio never leaves the device.")
                .foregroundStyle(.secondary)

            if case .error(let message) = state.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button("Retry") { onRetry() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ModelDownloadView(state: state)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
