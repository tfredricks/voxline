import Foundation

enum PlannedEdit: Equatable {
    case replace(UTF16Range, expected: String, with: String)
    case replaceLiveSelection(String)
    case insertAfterLiveSelection(String)
    case insertAtCaret(String)
    case copy(String)
    /// Nothing to apply; the string is the toast.
    case nothing(String)
}

enum EditPlanner {
    static let markers = [CommandPrompt.cursorMarker, CommandPrompt.selectionStart, CommandPrompt.selectionEnd, CommandPrompt.cutMarker]

    static func plan(result: CommandResult, context: EditContext, isPreset: Bool) -> PlannedEdit {
        let text = markers.reduce(result.text) { $0.replacingOccurrences(of: $1, with: "") }
        let action: CommandAction = isPreset ? .replaceSelection : result.action

        guard context.isEditable else {
            return text.isEmpty ? .nothing("Couldn't apply that") : .copy(text)
        }

        switch action {
        case .replaceSelection:
            guard let selection = context.selection else {
                return plan(result: CommandResult(action: .insert, text: text), context: context, isPreset: false)
            }
            if text == selection.text { return .nothing("No changes") }
            if context.field != nil, let range = selection.range {
                return .replace(range, expected: selection.text, with: text)
            }
            return .replaceLiveSelection(text)

        case .insert:
            if text.isEmpty { return .nothing("Couldn't apply that") }
            if let selection = context.selection {
                if context.field != nil, let range = selection.range {
                    return .replace(UTF16Range(location: range.end, length: 0), expected: "", with: text)
                }
                return .insertAfterLiveSelection(text)
            }
            if let cursor = context.cursor {
                return .replace(UTF16Range(location: cursor, length: 0), expected: "", with: text)
            }
            return .insertAtCaret(text)

        case .rewrite:
            guard let field = context.field else { return .nothing("Couldn't apply that") }
            if text.isEmpty { return .nothing("Couldn't apply that") }
            guard let change = TextDiff.minimalChange(from: field.text, to: text) else { return .nothing("No changes") }
            let expected = (field.text as NSString).substring(with: change.range.nsRange)
            let range = UTF16Range(location: field.range.location + change.range.location, length: change.range.length)
            return .replace(range, expected: expected, with: change.replacement)
        }
    }
}
