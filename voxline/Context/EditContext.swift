import Foundation

struct SelectionInfo: Equatable, Sendable {
    var text: String
    /// nil when the text came from Cmd+C or from kAXSelectedText without a range.
    var range: UTF16Range?
}

/// A window of the focused field's value, in UTF-16 units of the full value.
struct FieldWindowText: Equatable, Sendable {
    var text: String
    var range: UTF16Range
    var fullLength: Int
    var cutBefore: Bool { range.location > 0 }
    var cutAfter: Bool { range.end < fullLength }
}

/// What a command edits: the focused element, its field window, and the
/// selection and cursor in UTF-16 units of the full value. `field` is nil when
/// the value is unavailable or untrusted; `cursor` is set only when `field` is.
struct EditContext: Equatable, Sendable {
    var appName, bundleID, windowTitle, role, subrole: String?
    var isEditable: Bool
    var element: AXElementRef?
    var field: FieldWindowText?
    var selection: SelectionInfo?
    var cursor: Int?
    var needsCopyFallback: Bool
}

enum EditContextRefusal: Error, Equatable, Sendable { case secureField, notResponding, selectionTooLong }
