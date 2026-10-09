// voxline/Output/TypingInjector.swift
import Foundation

enum TypingChunker {
    /// Splits on Character boundaries; a grapheme longer than maxUnits is its own chunk.
    static func chunks(_ text: String, maxUnits: Int = 20) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(character.utf16)
            if current.count + units.count > maxUnits && !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

/// Types text as tagged Unicode key events, one chunk per event pair, so a
/// grapheme (flag, ZWJ family, stacked accents) never arrives split (issue 16).
/// Callers run the release gate first.
struct TypingInjector: Sendable {
    var post: @Sendable ([UInt16]) -> Void = { SyntheticKeys.typeChunk($0) }

    /// Posts every chunk in order; empty text posts nothing.
    func type(_ text: String) {
        for chunk in TypingChunker.chunks(text) {
            post(chunk)
        }
    }
}
