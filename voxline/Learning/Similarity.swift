import Foundation

/// How alike a misheard phrase and the user's correction are. Pure.
enum Similarity {

    /// Close on spelling alone at or under this normalized edit distance.
    static let spellingThreshold = 0.34
    /// Close at or under this distance when the phonetic keys also match.
    static let phoneticThreshold = 0.6

    /// Lowercased letters and digits only, so "arg max" and "Argmax" compare equal.
    static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }

    /// Edit distance of the normalized strings over the longer one's length;
    /// 1 when either normalizes to empty.
    static func distance(_ a: String, _ b: String) -> Double {
        let x = normalized(a), y = normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return 1 }
        return Double(levenshtein(x, y)) / Double(max(x.count, y.count))
    }

    /// Soundex digit classes without truncation, the first letter coded too:
    /// vowels and h, w, y are dropped, ASCII digits are kept, and runs of
    /// one code collapse to one.
    static func phoneticKey(_ text: String) -> String {
        var key = ""
        for character in normalized(text) {
            let code: Character
            if character.isASCII, character.isNumber {
                code = character
            } else if let mapped = codes[character] {
                code = mapped
            } else {
                continue
            }
            if key.last != code { key.append(code) }
        }
        return key
    }

    static func isClose(_ a: String, _ b: String) -> Bool {
        let d = distance(a, b)
        if d <= spellingThreshold { return true }
        let key = phoneticKey(a)
        return d <= phoneticThreshold && key.count >= 2 && key == phoneticKey(b)
    }

    private static let codes: [Character: Character] = {
        let groups: [(String, Character)] = [
            ("bfpv", "1"), ("cgjkqsxz", "2"), ("dt", "3"), ("l", "4"), ("mn", "5"), ("r", "6"),
        ]
        var map: [Character: Character] = [:]
        for (letters, code) in groups {
            for letter in letters { map[letter] = code }
        }
        return map
    }()
}
