import AppKit
import SwiftUI

/// Pure formatting helpers for history menu rows. Kept separate from the
/// SwiftUI view so they can be unit-tested without spinning up AppKit.
enum DictationHistoryMenuFormatter {

    /// Single-line preview: collapse all whitespace runs (incl. newlines/tabs)
    /// into single spaces, trim, then truncate to `maxChars` with an ellipsis.
    static func previewText(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }

    /// "<preview> · <relative-time>" — "Hey team, just wanted to… · 2m ago".
    static func rowLabel(
        for item: DictationHistoryItem,
        now: Date = Date(),
        maxPreviewChars: Int = 50
    ) -> String {
        let preview = previewText(item.cleanedText, maxChars: maxPreviewChars)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let when = formatter.localizedString(for: item.timestamp, relativeTo: now)
        return "\(preview) · \(when)"
    }
}

/// "Recent dictations" submenu. Rendered inside `MenuBarContent`.
struct DictationHistoryMenu: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    var body: some View {
        Menu("Recent dictations") {
            if store.items.isEmpty {
                Button("No recent dictations") {}
                    .disabled(true)
            } else {
                ForEach(store.items) { item in
                    Button(DictationHistoryMenuFormatter.rowLabel(for: item)) {
                        copy(item: item)
                    }
                }
                Divider()
                Button("Clear History") {
                    store.clear()
                }
            }
        }
    }

    private func copy(item: DictationHistoryItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.cleanedText, forType: .string)
        state.toastMessage = "Copied"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if state.toastMessage == "Copied" {
                state.toastMessage = nil
            }
        }
    }
}
