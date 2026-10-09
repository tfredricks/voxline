import Foundation

struct Token: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case word, space, punctuation
    }

    let kind: Kind
    let text: String
    /// Where the token sits in the string it came from.
    let range: UTF16Range
}

/// Splits text into words, whitespace runs, and single punctuation marks. Pure.
enum WordTokenizer {

    /// Join two word characters into one word: "don't", "Node.js", "e-mail".
    static let joiners: Set<Character> = ["'", "’", ".", "-", "_"]

    static func tokens(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var offset = 0
        var index = 0
        while index < characters.count {
            let start = index
            let kind: Token.Kind
            if isWordCharacter(characters[index]) {
                kind = .word
                index += 1
                while index < characters.count {
                    if isWordCharacter(characters[index]) {
                        index += 1
                    } else if joiners.contains(characters[index]), index + 1 < characters.count,
                              isWordCharacter(characters[index + 1]) {
                        index += 2
                    } else {
                        break
                    }
                }
            } else if characters[index].isWhitespace {
                kind = .space
                index += 1
                while index < characters.count, characters[index].isWhitespace { index += 1 }
            } else {
                kind = .punctuation
                index += 1
            }
            let piece = String(characters[start..<index])
            let length = piece.utf16.count
            tokens.append(Token(kind: kind, text: piece, range: UTF16Range(location: offset, length: length)))
            offset += length
        }
        return tokens
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
