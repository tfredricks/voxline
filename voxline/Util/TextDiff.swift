import Foundation

enum TextDiff {
    struct Change: Equatable {
        let range: UTF16Range
        let replacement: String
    }

    /// Smallest UTF-16 range of `old` that, replaced, yields `new`, widened
    /// to composed-character boundaries so no surrogate pair, combining
    /// sequence, or CRLF is split. nil when the strings are equal.
    static func minimalChange(from old: String, to new: String) -> Change? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        let oldNS = old as NSString, newNS = new as NSString

        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }

        p = min(boundaryAtOrBefore(oldNS, p), boundaryAtOrBefore(newNS, p))
        let oldEnd = boundaryAtOrAfter(oldNS, a.count - s)
        let newEnd = boundaryAtOrAfter(newNS, b.count - s)
        s = min(a.count - oldEnd, b.count - newEnd)

        let range = UTF16Range(location: p, length: a.count - s - p)
        let replacement = String(utf16CodeUnits: Array(b[p ..< (b.count - s)]), count: b.count - s - p)
        return Change(range: range, replacement: replacement)
    }

    private static func boundaryAtOrBefore(_ s: NSString, _ i: Int) -> Int {
        guard i > 0, i < s.length else { return i }
        if isInsideCRLF(s, i) { return i - 1 }
        return s.rangeOfComposedCharacterSequence(at: i).location
    }

    private static func boundaryAtOrAfter(_ s: NSString, _ i: Int) -> Int {
        guard i > 0, i < s.length else { return i }
        if isInsideCRLF(s, i) { return i + 1 }
        let r = s.rangeOfComposedCharacterSequence(at: i)
        return r.location == i ? i : r.location + r.length
    }

    /// `rangeOfComposedCharacterSequence` keeps surrogate pairs, combining
    /// marks, ZWJ sequences, and flags whole, but treats CR and LF as two.
    private static func isInsideCRLF(_ s: NSString, _ i: Int) -> Bool {
        s.character(at: i - 1) == 0x0D && s.character(at: i) == 0x0A
    }
}
