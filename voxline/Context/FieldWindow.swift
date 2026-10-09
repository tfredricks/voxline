import Foundation

enum FieldWindow {
    static let budget = 12_000

    /// Whole field when it fits; otherwise `anchor` plus up to 2/3 of the
    /// remaining budget before it and the rest after, unused room donated to
    /// the other side, edges snapped inward to composed-character boundaries
    /// (CR+LF counts as one).
    static func make(text: NSString, anchor: UTF16Range, budget: Int = budget) -> UTF16Range {
        let full = text.length
        if full <= budget { return UTF16Range(location: 0, length: full) }

        let remaining = max(0, budget - anchor.length)
        var before = min(anchor.location, remaining * 2 / 3)
        let after = min(full - anchor.end, remaining - before)
        before = min(anchor.location, remaining - after)

        let start = min(text.composedBoundary(atOrAfter: anchor.location - before), anchor.location)
        let end = max(text.composedBoundary(atOrBefore: anchor.end + after), anchor.end)
        return UTF16Range(location: start, length: end - start)
    }
}
