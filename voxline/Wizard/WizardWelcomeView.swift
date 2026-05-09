// voxline/Wizard/WizardWelcomeView.swift
import SwiftUI

struct WizardWelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome to voxline").font(.largeTitle.bold())
            Text("Hold a chord to dictate. Speak. Release. voxline transcribes locally and pastes cleaned text into the focused field.")
                .foregroundStyle(.secondary)
            Text("Setup takes about a minute. We'll grant a few macOS permissions, set an LLM provider, and download the speech recognition model.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
