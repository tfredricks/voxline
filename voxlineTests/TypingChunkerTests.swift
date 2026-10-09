// voxlineTests/TypingChunkerTests.swift
import Testing
@testable import voxline

@Suite struct TypingChunkerTests {

    private func sizes(_ text: String, maxUnits: Int = 20) -> [Int] {
        TypingChunker.chunks(text, maxUnits: maxUnits).map(\.count)
    }

    private func rejoined(_ chunks: [[UInt16]]) -> String {
        String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
    }

    @Test func short_ascii_is_one_chunk() {
        #expect(TypingChunker.chunks("abc") == [Array("abc".utf16)])
    }

    @Test func long_ascii_splits_at_max_units() {
        #expect(sizes(String(repeating: "a", count: 25)) == [20, 5])
    }

    @Test func flags_are_never_split() {
        let text = String(repeating: "🇺🇸", count: 6)
        #expect(text.utf16.count == 24)
        let chunks = TypingChunker.chunks(text)
        #expect(chunks.map(\.count) == [20, 4])
        #expect(String(decoding: chunks[0], as: UTF16.self) == String(repeating: "🇺🇸", count: 5))
        #expect(String(decoding: chunks[1], as: UTF16.self) == "🇺🇸")
    }

    @Test func zwj_families_are_never_split() {
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf16.count == 11)
        let chunks = TypingChunker.chunks(family + family)
        #expect(chunks.map(\.count) == [11, 11])
        #expect(chunks.allSatisfy { String(decoding: $0, as: UTF16.self) == family })
    }

    @Test func grapheme_longer_than_max_gets_its_own_chunk() {
        let stacked = "a" + String(repeating: "\u{0301}", count: 25)
        #expect(stacked.count == 1)
        #expect(sizes(stacked) == [26])
        #expect(sizes("xy" + stacked + "z") == [2, 26, 1])
    }

    @Test func empty_text_has_no_chunks() {
        #expect(TypingChunker.chunks("").isEmpty)
    }

    @Test func chunks_rejoin_to_the_original_text() {
        let text = "Hello, wörld 👋🏽 — café 🇯🇵 नमस्ते " + String(repeating: "x", count: 40)
        let chunks = TypingChunker.chunks(text)
        #expect(rejoined(chunks) == text)
        #expect(chunks.allSatisfy { $0.count <= 20 })
    }
}

@Suite struct TypingInjectorTests {

    @Test func posts_every_chunk_in_order() {
        let posted = LockedBox<[[UInt16]]>([])
        let injector = TypingInjector(post: { units in posted.mutate { $0.append(units) } })
        let text = String(repeating: "b", count: 45)

        injector.type(text)

        #expect(posted.read() == TypingChunker.chunks(text))
        #expect(posted.read().map(\.count) == [20, 20, 5])
    }

    @Test func empty_text_posts_nothing() {
        let posted = LockedBox<[[UInt16]]>([])
        let injector = TypingInjector(post: { units in posted.mutate { $0.append(units) } })

        injector.type("")

        #expect(posted.read().isEmpty)
    }
}
