// voxline/Output/DictationSpacing.swift
import Foundation

/// Puts a space between a dictation and the text before the cursor, so
/// back-to-back dictations don't run together ("Hello.How are you"). Pure.
enum DictationSpacing {

    /// `text` with a leading space when `before` (the field text before the
    /// cursor at press) ends in a character that needs one. Unknown `before`
    /// and terminals, where the AX value is the scrollback, leave it alone.
    static func spaced(_ text: String, before: String?, bundleID: String?) -> String {
        guard !InsertionPlan.isTerminal(bundleID),
              let last = before?.last, let first = text.first,
              !last.isWhitespace, !first.isWhitespace,
              !noSpaceAfter.contains(last), !noSpaceBefore.contains(first),
              !isUnspaced(last), !isUnspaced(first)
        else { return text }
        return " " + text
    }

    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "@", "#", "$", "`"]
    private static let noSpaceBefore: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "”", "’", "%", "…"]

    /// Han, kana, and CJK punctuation: those scripts don't separate words
    /// with spaces. Hangul does, so it is not listed.
    private static func isUnspaced(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first?.value else { return false }
        return (0x3000...0x30FF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
            || (0x4E00...0x9FFF).contains(scalar) || (0xFF00...0xFF65).contains(scalar)
    }
}
