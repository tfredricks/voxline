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

/// Placeholder body — filled in by Task 4. Defined here so the file exists
/// in the project and the formatter is reachable from the test target.
struct HistoryView: View {
    @Bindable var store: DictationHistoryStore
    @Bindable var state: AppState

    var body: some View {
        EmptyView()
    }
}
