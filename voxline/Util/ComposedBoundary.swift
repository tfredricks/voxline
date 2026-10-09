import Foundation

extension NSString {
    /// The composed-character boundary at or before `index`, in UTF-16 units.
    /// CR+LF counts as one character.
    func composedBoundary(atOrBefore index: Int) -> Int {
        guard index > 0, index < length else { return index }
        if isInsideCRLF(index) { return index - 1 }
        return rangeOfComposedCharacterSequence(at: index).location
    }

    /// The composed-character boundary at or after `index`, in UTF-16 units.
    /// CR+LF counts as one character.
    func composedBoundary(atOrAfter index: Int) -> Int {
        guard index > 0, index < length else { return index }
        if isInsideCRLF(index) { return index + 1 }
        let sequence = rangeOfComposedCharacterSequence(at: index)
        return sequence.location == index ? index : sequence.location + sequence.length
    }

    /// `rangeOfComposedCharacterSequence` keeps surrogate pairs, combining
    /// marks, ZWJ sequences, and flags whole, but treats CR and LF as two.
    private func isInsideCRLF(_ index: Int) -> Bool {
        character(at: index - 1) == 0x0D && character(at: index) == 0x0A
    }
}
