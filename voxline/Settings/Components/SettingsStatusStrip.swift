import SwiftUI

enum SettingsAnchor: Hashable {
    case hotkey, microphone, recognition, cleanup, customVocabulary, feedback
}

struct SettingsStatusStrip: View {
    let status: SettingsStatusViewModel
    var scrollTo: (SettingsAnchor) -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle()
                    .fill(status.isReady ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(status.isReady ? "Ready" : "Setup needed")
                    .fontWeight(.semibold)
            }

            chip(text: status.micChipText, showsCheck: false) { scrollTo(.microphone) }
            chip(text: status.modelChipText, showsCheck: status.modelChipShowsCheck) { scrollTo(.recognition) }
            chip(text: status.providerChipText, showsCheck: status.providerChipShowsCheck) { scrollTo(.cleanup) }

            Spacer(minLength: 0)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private func chip(text: String, showsCheck: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(text)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .imageScale(.small)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Jump to section")
    }
}
