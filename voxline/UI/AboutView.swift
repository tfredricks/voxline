import SwiftUI
import AppKit

struct AboutView: View {
    let env: SupportEnvironment

    var body: some View {
        VStack(spacing: 16) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
            }

            VStack(spacing: 2) {
                Text("Voxline")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Version \(env.appVersion) (\(env.buildNumber))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 2) {
                Text("Local-first dictation for Mac.")
                Text("Audio never leaves your Mac.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            VStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(SupportLinks.repoURL)
                } label: {
                    Text("Visit GitHub").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(SupportLinks.bugReportURL(env: env))
                } label: {
                    Text("Report a Bug…").frame(maxWidth: .infinity)
                }
                Button {
                    NSWorkspace.shared.open(SupportLinks.feedbackURL(env: env))
                } label: {
                    Text("Send Feedback…").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)

            Spacer(minLength: 4)

            VStack(spacing: 2) {
                Text("Built with WhisperKit")
                Text("© 2026 Todd Fredricks")
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 320, height: 420)
    }
}

#Preview {
    AboutView(env: SupportEnvironment(
        appVersion: "1.0",
        buildNumber: "1",
        osVersion: "Version 14.5 (Build 23F79)",
        whisperModel: "large-v3-turbo"
    ))
}
