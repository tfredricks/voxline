import Foundation

/// Turns a `CapturedContext` into the user-message body the LLM receives.
///
/// Shape:
/// ```
/// Raw transcript:
/// "<transcript>"
///
/// Context:
/// - App: ...
/// - Window: ...
/// - Field: ...
/// - Selected text: "..."
/// - Text before cursor: "..."
/// - Text after cursor: "..."
/// - Visible labels: [...]
/// - Custom vocabulary: ...
///
/// Return only the final text to insert. Do not add quotes, prefixes, or commentary.
/// ```
///
/// Lines are omitted when their underlying values are nil/empty. The whole
/// `Context:` block is omitted when no fields would render. Secure-field
/// contexts suppress value-bearing lines but keep app/window/labels/vocab.
enum ContextBlockFormatter {

    static let trailingInstruction =
        "Return only the final text to insert. Do not add quotes, prefixes, or commentary."

    static func format(transcript: String, context: CapturedContext) -> String {
        var out = "Raw transcript:\n\"\(escape(transcript))\""
        let lines = contextLines(from: context)
        if !lines.isEmpty {
            out += "\n\nContext:\n"
            out += lines.joined(separator: "\n")
        }
        out += "\n\n\(trailingInstruction)"
        return out
    }

    private static func contextLines(from c: CapturedContext) -> [String] {
        var lines: [String] = []

        if let app = c.appName, !app.isEmpty {
            if let bid = c.bundleID, !bid.isEmpty {
                lines.append("- App: \(app) (\(bid))")
            } else {
                lines.append("- App: \(app)")
            }
        } else if let bid = c.bundleID, !bid.isEmpty {
            lines.append("- App: \(bid)")
        }

        if let w = c.windowTitle, !w.isEmpty {
            lines.append("- Window: \(w)")
        }

        if c.isSecureField {
            lines.append("- Field: secure")
        } else if let role = c.fieldRole, !role.isEmpty {
            lines.append("- Field: \(role)")
        }

        // Value-bearing lines: only when NOT a secure field.
        if !c.isSecureField {
            if let s = c.selectedText, !s.isEmpty {
                lines.append("- Selected text: \"\(escape(s))\"")
            }
            if let t = c.textBeforeCursor, !t.isEmpty {
                lines.append("- Text before cursor: \"\(escape(t))\"")
            }
            if let t = c.textAfterCursor, !t.isEmpty {
                lines.append("- Text after cursor: \"\(escape(t))\"")
            }
        }

        if !c.visibleLabels.isEmpty {
            let quoted = c.visibleLabels.map { "\"\(escape($0))\"" }.joined(separator: ", ")
            lines.append("- Visible labels: [\(quoted)]")
        }

        if !c.customVocabulary.isEmpty {
            let escaped = c.customVocabulary.map(escape).joined(separator: ", ")
            lines.append("- Custom vocabulary: \(escaped)")
        }

        return lines
    }

    /// Escape backslashes first, then quotes — swapping the order would
    /// double-escape the slashes inserted for `"`.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
