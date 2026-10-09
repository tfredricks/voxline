import Foundation

enum RegionMatch: Equatable, Sendable {
    case changed(String)
    case unchanged
    /// Under a quarter of the inserted length is left: the user undid or
    /// deleted the dictation.
    case discarded
    /// The prefix is missing or not unique, the suffix is missing, or the
    /// region is implausibly long.
    case ambiguous
    /// The field's value couldn't be read. Set by `CorrectionWindow`, never
    /// by `RegionLocator`.
    case unreadable

    /// For logs: the case name, never the text.
    var logName: String {
        switch self {
        case .changed: return "changed"
        case .unchanged: return "unchanged"
        case .discarded: return "discarded"
        case .ambiguous: return "ambiguous"
        case .unreadable: return "unreadable"
        }
    }
}

/// Finds the dictated region in a later value of the same field. Never
/// guesses: anything it can't pin down is `.ambiguous`. A context side shorter
/// than `AnchorText.contextLength` was clipped by the field edge when anchored,
/// so it must sit at that edge now. Pure.
enum RegionLocator {

    static func locate(_ anchor: AnchorText, in value: String) -> RegionMatch {
        let text = value as NSString
        let start: Int
        if anchor.prefix.isEmpty {
            start = 0
        } else if anchor.prefix.utf16.count < AnchorText.contextLength {
            guard text.hasPrefix(anchor.prefix) else { return .ambiguous }
            start = anchor.prefix.utf16.count
        } else {
            let found = matches(of: anchor.prefix, in: text, from: 0)
            guard found.count == 1, let at = found.first else { return .ambiguous }
            start = at + anchor.prefix.utf16.count
        }

        let end: Int
        if anchor.suffix.isEmpty {
            end = text.length
        } else if anchor.suffix.utf16.count < AnchorText.contextLength {
            let suffixStart = text.length - anchor.suffix.utf16.count
            guard suffixStart >= start, text.hasSuffix(anchor.suffix) else { return .ambiguous }
            end = suffixStart
        } else {
            let found = matches(of: anchor.suffix, in: text, from: start)
            guard found.count == 1, let at = found.first else { return .ambiguous }
            end = at
        }

        let length = end - start
        let inserted = anchor.inserted.utf16.count
        if length > max(2 * inserted, inserted + 200) { return .ambiguous }
        if length * 4 < inserted { return .discarded }
        let region = text.substring(with: NSRange(location: start, length: length))
        return region == anchor.inserted ? .unchanged : .changed(region)
    }

    /// Start offsets of every occurrence of a non-empty `needle` at or after
    /// `from`, overlapping ones included.
    private static func matches(of needle: String, in text: NSString, from: Int) -> [Int] {
        var found: [Int] = []
        var cursor = from
        while cursor < text.length {
            let hit = text.range(of: needle, options: .literal, range: NSRange(location: cursor, length: text.length - cursor))
            guard hit.location != NSNotFound else { break }
            found.append(hit.location)
            cursor = hit.location + 1
        }
        return found
    }
}
