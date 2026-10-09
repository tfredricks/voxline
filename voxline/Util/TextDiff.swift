import Foundation

enum TextDiff {
    struct Change: Equatable {
        let range: UTF16Range
        let replacement: String
    }

    /// Smallest UTF-16 range of `old` that, replaced, yields `new`, widened
    /// to composed-character boundaries so no surrogate pair, combining
    /// sequence, flag, or CRLF is split. Each edge widens until it is a
    /// boundary in both strings: regional indicators pair from the start of
    /// their run, so a shared suffix can split differently in each. nil when
    /// the strings are equal.
    static func minimalChange(from old: String, to new: String) -> Change? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        let oldNS = old as NSString, newNS = new as NSString

        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        var previous: Int
        repeat {
            previous = p
            p = min(oldNS.composedBoundary(atOrBefore: p), newNS.composedBoundary(atOrBefore: p))
        } while p != previous
        repeat {
            previous = s
            s = min(a.count - oldNS.composedBoundary(atOrAfter: a.count - s),
                    b.count - newNS.composedBoundary(atOrAfter: b.count - s))
        } while s != previous

        let range = UTF16Range(location: p, length: a.count - s - p)
        let replacement = String(utf16CodeUnits: Array(b[p ..< (b.count - s)]), count: b.count - s - p)
        return Change(range: range, replacement: replacement)
    }
}
