import Foundation

/// Where a dictation landed in its field, plus enough text on each side to
/// find it again later. Pure.
struct AnchorText: Equatable, Sendable {

    static let contextLength = 32

    let inserted: String
    let range: UTF16Range
    /// Up to `contextLength` units before `range`, its start snapped outward
    /// to a composed-character boundary. Shorter only when the field's start clipped it.
    let prefix: String
    /// Up to `contextLength` units after `range`, its end snapped outward.
    /// Shorter only when the field's end clipped it.
    let suffix: String

    /// nil unless `caret` is an empty range inside `value` and the
    /// `inserted.utf16.count` units just before it read exactly `inserted`.
    static func make(value: String, caret: UTF16Range, inserted: String) -> AnchorText? {
        let text = value as NSString
        let length = inserted.utf16.count
        guard length > 0, caret.length == 0, caret.fits(in: text.length), caret.location >= length else { return nil }
        let range = UTF16Range(location: caret.location - length, length: length)
        guard text.substring(with: range.nsRange) == inserted else { return nil }
        let prefixStart = text.composedBoundary(atOrBefore: max(0, range.location - contextLength))
        let suffixEnd = text.composedBoundary(atOrAfter: min(text.length, range.end + contextLength))
        return AnchorText(
            inserted: inserted,
            range: range,
            prefix: text.substring(with: NSRange(location: prefixStart, length: range.location - prefixStart)),
            suffix: text.substring(with: NSRange(location: range.end, length: suffixEnd - range.end))
        )
    }
}

/// The field a dictation went into, and where it landed there.
struct InsertAnchor: Sendable {
    let element: any AXTextElement
    let text: AnchorText
}
