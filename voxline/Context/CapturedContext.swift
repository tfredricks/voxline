import Foundation

/// Snapshot of "where is the user dictating right now" signals captured at
/// push-to-talk press. Consumed by `ContextBlockFormatter` to build the LLM
/// user message. All optional/zero fields are omitted from the formatted
/// output — there is no "unknown" line in the prompt.
///
/// Caps on string lengths are enforced at the producer layer (the AX probe).
/// The formatter does not re-trim.
struct CapturedContext: Equatable, Sendable {

    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var fieldRole: String?
    var fieldSubrole: String?
    /// True when the focused field is a secure text field (password input).
    /// When true, value-bearing lines (before/after cursor, selected text)
    /// are suppressed by the formatter.
    var isSecureField: Bool
    var textBeforeCursor: String?
    var textAfterCursor: String?
    var selectedText: String?
    var customVocabulary: [String]
    /// Wall-clock duration of the capture, in milliseconds. Diagnostic only.
    var captureDurationMs: Int
    /// Short reason codes like "ax-timeout", "secure-field", "ax-not-trusted".
    /// Diagnostic only — never included in the prompt.
    var captureNotes: [String]

    static let empty = CapturedContext(
        appName: nil,
        bundleID: nil,
        windowTitle: nil,
        fieldRole: nil,
        fieldSubrole: nil,
        isSecureField: false,
        textBeforeCursor: nil,
        textAfterCursor: nil,
        selectedText: nil,
        customVocabulary: [],
        captureDurationMs: 0,
        captureNotes: []
    )
}
