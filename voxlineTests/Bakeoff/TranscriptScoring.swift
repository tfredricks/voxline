import Foundation

/// Pure transcript-scoring helpers for the engine bake-off.
enum TranscriptScoring {

    /// Lowercased words with everything except letters, digits, and
    /// apostrophes treated as a separator. Typographic apostrophes count as
    /// plain ones.
    static func normalizedWords(_ s: String) -> [String] {
        let cleaned = s.lowercased().map { char -> Character in
            if char == "\u{2019}" { return "'" }
            if char.isLetter || char.isNumber || char == "'" || char.isWhitespace { return char }
            return " "
        }
        return String(cleaned).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Word-level Levenshtein distance and the reference word count, so
    /// callers can pool errors across clips.
    static func wordEdits(reference: String, hypothesis: String) -> (distance: Int, referenceCount: Int) {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        if ref.isEmpty { return (hyp.count, 0) }
        if hyp.isEmpty { return (ref.count, ref.count) }
        var previous = Array(0...hyp.count)
        for i in 1...ref.count {
            var current = [i] + Array(repeating: 0, count: hyp.count)
            for j in 1...hyp.count {
                let substitution = previous[j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            previous = current
        }
        return (previous[hyp.count], ref.count)
    }

    /// Edits over reference words: 0 when both sides are empty, 1 when only
    /// the reference is.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        let edits = wordEdits(reference: reference, hypothesis: hypothesis)
        if edits.referenceCount == 0 { return edits.distance == 0 ? 0 : 1 }
        return Double(edits.distance) / Double(edits.referenceCount)
    }

    /// Lowercase letters and digits only, so "lang graph" and "LangGraph"
    /// compare equal.
    static func compact(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// `hits` is the smaller of the two non-overlapping occurrence counts, so
    /// a hypothesis cannot earn credit for repeating a term.
    static func termHits(term: String, reference: String, hypothesis: String) -> (inReference: Int, hits: Int) {
        let needle = compact(term)
        let inReference = occurrences(of: needle, in: compact(reference))
        let inHypothesis = occurrences(of: needle, in: compact(hypothesis))
        return (inReference, min(inReference, inHypothesis))
    }

    static func median(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Nearest-rank percentile; `fraction` is in 0...1.
    static func percentile(_ values: [Int], _ fraction: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count) - 1e-9).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }
}
