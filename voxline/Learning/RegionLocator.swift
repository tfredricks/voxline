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
/// guesses: anything it can't pin down is `.ambiguous`. Pure.
enum RegionLocator {

    static func locate(_ anchor: AnchorText, in value: String) -> RegionMatch {
        let text = value as NSString
        let start: Int
        if anchor.prefix.isEmpty {
            start = 0
        } else {
            let first = text.range(of: anchor.prefix, options: .literal)
            guard first.location != NSNotFound else { return .ambiguous }
            let rest = NSRange(location: first.location + 1, length: text.length - first.location - 1)
            guard text.range(of: anchor.prefix, options: .literal, range: rest).location == NSNotFound else { return .ambiguous }
            start = first.location + first.length
        }

        let end: Int
        if anchor.suffix.isEmpty {
            end = text.length
        } else {
            let found = text.range(of: anchor.suffix, options: .literal, range: NSRange(location: start, length: text.length - start))
            guard found.location != NSNotFound else { return .ambiguous }
            end = found.location
        }

        let length = end - start
        let inserted = anchor.inserted.utf16.count
        if length > max(2 * inserted, inserted + 200) { return .ambiguous }
        if length * 4 < inserted { return .discarded }
        let region = text.substring(with: NSRange(location: start, length: length))
        return region == anchor.inserted ? .unchanged : .changed(region)
    }
}
