import Foundation

/// Pure predicate for utterances short and clean enough that LLM cleanup
/// would change nothing.
enum CleanupFastPath {

    static let maxWords = 6

    private static let fillerTokens: Set<String> = ["um", "uh", "er", "ah", "hmm"]
    private static let fillerPhrases: [[String]] = [["you", "know"], ["i", "mean"]]

    static func shouldSkip(_ transcript: String) -> Bool {
        let rawTokens = transcript.lowercased().split(whereSeparator: \.isWhitespace)
        guard (1...maxWords).contains(rawTokens.count) else { return false }

        let words = rawTokens
            .map { String($0.filter { !$0.isPunctuation }) }
            .filter { !$0.isEmpty }
        guard words.contains(where: { $0.contains { $0.isLetter || $0.isNumber } }) else { return false }
        if words.contains(where: fillerTokens.contains) { return false }
        for (first, second) in zip(words, words.dropFirst()) where fillerPhrases.contains([first, second]) {
            return false
        }
        return true
    }
}
