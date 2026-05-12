// voxline/UI/HistoryView.swift
//
// Standalone window listing recent cleaned dictations with Time / Mode /
// App / Preview columns. Click a row to copy that entry's text. Replaces
// the menu-bar submenu — the latter could not surface the resolved mode
// for each row without exploding in size.

import AppKit
import SwiftUI

/// Pure-string formatting helpers for the history table's Preview column.
/// Kept separate from the view so it can be unit-tested without spinning up
/// SwiftUI.
enum HistoryViewFormatter {

    /// Single-line preview: collapse all whitespace runs (including newlines
    /// and tabs) into single spaces, trim, then truncate to `maxChars` with
    /// an ellipsis.
    static func previewText(_ text: String, maxChars: Int) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= maxChars { return collapsed }
        return String(collapsed.prefix(maxChars)) + "…"
    }
}

struct HistoryView: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    /// Selection-bound row click. We immediately copy and clear the selection
    /// so a second click on the same row still fires. Using `selection:` is
    /// the only first-class row-click affordance SwiftUI's `Table` exposes
    /// on macOS; `onTapGesture` per cell wouldn't fire on whitespace inside
    /// a row.
    @State private var selectedID: DictationHistoryItem.ID? = nil

    var body: some View {
        Group {
            if store.items.isEmpty {
                emptyState
            } else {
                table
            }
        }
        .frame(minWidth: 560, minHeight: 320)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear history") { store.clear() }
                    .disabled(store.items.isEmpty)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No recent dictations.")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Hold your push-to-talk hotkey to dictate. Cleaned dictations appear here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var table: some View {
        Table(store.items, selection: $selectedID) {
            TableColumn("Time") { item in
                Text(Self.relativeTime(item.timestamp))
                    .help(Self.tooltip(item))
            }
            .width(min: 80, ideal: 100)

            TableColumn("Mode") { item in
                Text(item.modeDisplayName ?? "—")
                    .help(Self.tooltip(item))
            }
            .width(min: 80, ideal: 110)

            TableColumn("App") { item in
                Text(item.appName ?? item.appBundleID ?? "—")
                    .help(Self.tooltip(item))
            }
            .width(min: 100, ideal: 140)

            TableColumn("Preview") { item in
                Text(HistoryViewFormatter.previewText(item.cleanedText, maxChars: 120))
                    .help(Self.tooltip(item))
            }
        }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID,
                  let item = store.items.first(where: { $0.id == id })
            else { return }
            copy(item)
            selectedID = nil
        }
    }

    private func copy(_ item: DictationHistoryItem) {
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

    private static func relativeTime(_ when: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: when, relativeTo: Date())
    }

    private static func tooltip(_ item: DictationHistoryItem) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return "\(df.string(from: item.timestamp))\n\n\(item.cleanedText)"
    }
}
