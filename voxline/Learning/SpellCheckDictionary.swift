import AppKit

/// `NSSpellChecker` in its current language. Words the user taught macOS
/// count as known.
@MainActor
struct SpellCheckDictionary: WordDictionary {
    func isKnown(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }
}
