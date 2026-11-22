import Foundation

/// Recovers the final text from a cleanup reply in which the model revised
/// its own output in the open: a first draft, a note such as "Wait, I need to
/// correct my output…", then a "Final text:" label and the corrected text.
/// Pure; any reply without both the revision note and the label passes
/// through unchanged.
enum CleanupReplySanitizer {

    private static let label = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[.!?])[ \t]+)[ \t]*[*_]{0,2}(?:final|corrected|cleaned|revised|updated|fixed)(?:[ \t]+(?:cleaned|corrected|final))?[ \t]+(?:text|output|version|transcript|result)[*_]{0,2}[ \t]*:[*_]{0,2}[ \t]*"#,
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let revisionNote = try! NSRegularExpression(
        pattern: #"\b(?:wait|actually|correction|let me (?:re|fix|correct|redo)|i (?:need to|have to|should) (?:correct|fix|revise|redo)|i made (?:a|an) (?:mistake|error)|my (?:output|answer|response|reply)|the transcript (?:contains|says|has))\b"#,
        options: [.caseInsensitive]
    )

    /// The text after the last revision label when the reply before it holds
    /// a revision note, else `reply` unchanged.
    static func finalText(from reply: String) -> String {
        let ns = reply as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard let last = label.matches(in: reply, range: whole).last else { return reply }

        let before = ns.substring(to: last.range.location)
        guard revisionNote.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil else {
            return reply
        }

        let after = ns.substring(from: last.range.location + last.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return after.isEmpty ? reply : after
    }
}
