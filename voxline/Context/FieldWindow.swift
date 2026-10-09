import Foundation

enum FieldWindow {
    static let budget = 12_000

    /// Whole field when it fits; otherwise `anchor` plus up to 2/3 of the
    /// remaining budget before it and the rest after, unused room donated to
    /// the other side, edges snapped inward to composed-character boundaries.
    static func make(text: NSString, anchor: UTF16Range, budget: Int = budget) -> UTF16Range {
        let full = text.length
        if full <= budget { return UTF16Range(location: 0, length: full) }

        let remaining = max(0, budget - anchor.length)
        var before = min(anchor.location, remaining * 2 / 3)
        let after = min(full - anchor.end, remaining - before)
        before = min(anchor.location, remaining - after)

        var start = anchor.location - before
        var end = anchor.end + after

        if 0 < start, start < full {
            let sequence = text.rangeOfComposedCharacterSequence(at: start)
            if sequence.location < start {
                start = min(sequence.location + sequence.length, anchor.location)
            }
        }
        if 0 < end, end < full {
            let sequence = text.rangeOfComposedCharacterSequence(at: end)
            if sequence.location < end {
                end = max(sequence.location, anchor.end)
            }
        }
        return UTF16Range(location: start, length: end - start)
    }
}
