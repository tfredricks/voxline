import SwiftUI

enum SettingsAnchor: Hashable {
    case hotkey, microphone, recognition, cleanup, feedback
}

struct SettingsStatusStrip: View {
    let status: SettingsStatusViewModel
    var scrollTo: (SettingsAnchor) -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(status.isReady ? "Ready" : "Setup needed")
                    .fontWeight(.semibold)
            }

            chip(text: status.micChipText, showsCheck: false) { scrollTo(.microphone) }
            chip(text: status.modelChipText, showsCheck: status.modelChipShowsCheck) { scrollTo(.recognition) }
            chip(text: status.providerChipText, showsCheck: status.providerChipShowsCheck) { scrollTo(.cleanup) }

            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4))
    }

    @ViewBuilder
    private func chip(text: String, showsCheck: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(text).foregroundStyle(.secondary)
                if showsCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Jump to section")
    }
}
