import Foundation

/// A spelling dictionary: the system's, or a test double.
@MainActor
protocol WordDictionary {
    func isKnown(_ word: String) -> Bool
}

struct Classification: Equatable, Sendable {
    /// Terms to add to the vocabulary, in order, without duplicates.
    var vocabulary: [String] = []
    /// True when some change is not a vocabulary fix.
    var isStyleSignal = false
    var hunkCount = 0
}

/// Sorts the user's edits to a dictation into vocabulary fixes and style
/// signals. Pure apart from the dictionary it is given.
enum CorrectionClassifier {

    static let termLength = 2...40
    static let sentenceEnds: Set<String> = [".", "!", "?"]

    /// `before` is the field text just ahead of the region (the anchor
    /// prefix), used to tell whether the region starts mid-sentence. A region
    /// over `TokenDiff.maxTokens` tokens is a style signal with no vocabulary.
    @MainActor
    static func classify(inserted: String, corrected: String, before: String, dictionary: some WordDictionary) -> Classification {
        let newTokens = WordTokenizer.tokens(corrected)
        let old = WordTokenizer.tokens(inserted).filter { $0.kind != .space }
        let new = newTokens.filter { $0.kind != .space }
        guard let hunks = TokenDiff.hunks(old: old, new: new) else {
            return Classification(isStyleSignal: true)
        }

        var result = Classification(hunkCount: hunks.count)
        let insertedWords = old.filter { $0.kind == .word }.count
        let changed = hunks.reduce(0) { $0 + max(words(old[$1.old]).count, words(new[$1.new]).count) }
        let heavyRewrite = changed > 2 && changed * 2 > insertedWords

        for hunk in hunks {
            let oldWords = words(old[hunk.old])
            let newWords = words(new[hunk.new])
            guard !heavyRewrite,
                  isSubstitution(oldWords, newWords),
                  Similarity.isClose(oldWords.map(\.text).joined(), newWords.map(\.text).joined()),
                  hasSignal(oldWords, newWords,
                            midSentence: startsMidSentence(newWords[0], in: newTokens, before: before),
                            dictionary: dictionary)
            else {
                result.isStyleSignal = true
                continue
            }
            let first = newWords[0].range, last = newWords[newWords.count - 1].range
            let term = (corrected as NSString).substring(with: NSRange(location: first.location, length: last.end - first.location))
            if isTermShaped(term), !result.vocabulary.contains(term) {
                result.vocabulary.append(term)
            }
        }
        return result
    }

    /// True when the nearest non-space token before `word`, in `tokens` and
    /// then in `before`, exists and is neither `.`, `!`, `?`, nor a line break.
    static func startsMidSentence(_ word: Token, in tokens: [Token], before: String) -> Bool {
        let preceding = Array(tokens.prefix { $0.range.location < word.range.location })
        for run in [preceding, WordTokenizer.tokens(before)] {
            for token in run.reversed() {
                if token.kind == .space {
                    if token.text.contains(where: \.isNewline) { return false }
                    continue
                }
                return !(token.kind == .punctuation && sentenceEnds.contains(token.text))
            }
        }
        return false
    }

    static func isTermShaped(_ term: String) -> Bool {
        termLength.contains(term.count) && !term.allSatisfy(\.isNumber)
    }

    private static func words(_ tokens: ArraySlice<Token>) -> [Token] {
        tokens.filter { $0.kind == .word }
    }

    private static func isSubstitution(_ old: [Token], _ new: [Token]) -> Bool {
        guard (1...2).contains(old.count), (1...2).contains(new.count) else { return false }
        let oldText = old.map(\.text), newText = new.map(\.text)
        guard oldText != newText else { return false }
        return oldText.joined(separator: " ").lowercased() != newText.joined(separator: " ").lowercased()
    }

    @MainActor
    private static func hasSignal(_ old: [Token], _ new: [Token], midSentence: Bool, dictionary: some WordDictionary) -> Bool {
        if new.contains(where: { hasDigitOrInnerCapital($0.text) || !dictionary.isKnown($0.text) }) {
            return true
        }
        guard let first = new.first?.text.first, first.isUppercase, midSentence,
              let oldFirst = old.first?.text.first, oldFirst.isLowercase else { return false }
        return true
    }

    private static func hasDigitOrInnerCapital(_ word: String) -> Bool {
        word.contains(where: \.isNumber) || word.dropFirst().contains(where: \.isUppercase)
    }
}
