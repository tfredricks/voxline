import Foundation

/// One run of differences, as index ranges into the two token arrays.
struct Hunk: Equatable, Sendable {
    let old: Range<Int>
    let new: Range<Int>
}

/// Token-level longest-common-subsequence diff, comparing token text. Pure.
enum TokenDiff {

    static let maxTokens = 1_000

    /// Hunks in order, empty when the arrays are equal, nil when either side
    /// has more than `maxTokens` tokens.
    static func hunks(old: [Token], new: [Token]) -> [Hunk]? {
        guard old.count <= maxTokens, new.count <= maxTokens else { return nil }
        let n = old.count, m = new.count, width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                let value = old[i].text == new[j].text
                    ? table[(i + 1) * width + j + 1] + 1
                    : max(table[(i + 1) * width + j], table[i * width + j + 1])
                table[i * width + j] = value
            }
        }

        var hunks: [Hunk] = []
        var i = 0, j = 0
        var start: (old: Int, new: Int)?
        while i < n || j < m {
            if i < n, j < m, old[i].text == new[j].text {
                if let open = start {
                    hunks.append(Hunk(old: open.old..<i, new: open.new..<j))
                    start = nil
                }
                i += 1
                j += 1
            } else {
                if start == nil { start = (i, j) }
                if j >= m || (i < n && table[(i + 1) * width + j] >= table[i * width + j + 1]) {
                    i += 1
                } else {
                    j += 1
                }
            }
        }
        if let open = start {
            hunks.append(Hunk(old: open.old..<i, new: open.new..<j))
        }
        return hunks
    }
}
