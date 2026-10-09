// voxline/Wizard/WizardWelcomeView.swift
import SwiftUI
import AppKit

struct WizardWelcomeView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 72, height: 72)
                }
                Text("Welcome to Voxline").font(.largeTitle.bold())
            }
            Text("Hold a hotkey to dictate. Speak. Release. Voxline transcribes your speech and pastes cleaned-up text into the focused field.")
                .foregroundStyle(.secondary)
            Text("Setup takes about a minute. We'll grant a few macOS permissions, set an LLM provider, and get the speech engine ready.")
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
