import Testing
@testable import voxline

@Suite struct SimilarityTests {

    @Test func normalized_keeps_lowercase_letters_and_digits() {
        #expect(Similarity.normalized("Arg max!") == "argmax")
        #expect(Similarity.normalized("GPT-4o") == "gpt4o")
        #expect(Similarity.normalized(" , ") == "")
    }

    @Test func levenshtein_counts_single_character_edits() {
        #expect(Similarity.levenshtein("kitten", "sitting") == 3)
        #expect(Similarity.levenshtein("", "abc") == 3)
        #expect(Similarity.levenshtein("same", "same") == 0)
    }

    @Test func distance_is_over_the_longer_normalized_length() {
        let table: [(String, String, Double)] = [
            ("Cooper Nettis", "Kubernetes", 0.5),
            ("arg max", "Argmax", 0.0),
            ("Jason", "JSON", 0.2),
            ("clod", "Claude", 0.5),
            ("Tuesday", "Thursday", 0.25),
            ("there", "their", 0.4),
        ]
        for (old, new, expected) in table {
            #expect(abs(Similarity.distance(old, new) - expected) < 0.001, "\(old) → \(new)")
        }
        #expect(Similarity.distance("", "x") == 1)
    }

    @Test func phonetic_key_codes_every_letter_and_collapses_runs() {
        let table: [(String, String)] = [
            ("Cooper Nettis", "216532"), ("Kubernetes", "216532"),
            ("arg max", "6252"), ("Argmax", "6252"),
            ("Jason", "25"), ("JSON", "25"),
            ("clod", "243"), ("Claude", "243"),
            ("Tuesday", "323"), ("Thursday", "3623"),
            ("GPT4", "2134"), ("why", ""),
        ]
        for (text, key) in table {
            #expect(Similarity.phoneticKey(text) == key, "\(text)")
        }
    }

    @Test func close_pairs() {
        let pairs: [(String, String)] = [
            ("Cooper Nettis", "Kubernetes"),
            ("arg max", "Argmax"),
            ("Jason", "JSON"),
            ("clod", "Claude"),
            ("cat", "cut"),
            ("there", "their"),
        ]
        for (old, new) in pairs {
            #expect(Similarity.isClose(old, new), "\(old) → \(new)")
        }
    }

    @Test func far_pairs() {
        let pairs: [(String, String)] = [
            ("the new pipeline", "LangGraph"),
            ("pat", "boot"),
            ("cat", "dog"),
            ("", "x"),
        ]
        for (old, new) in pairs {
            #expect(!Similarity.isClose(old, new), "\(old) → \(new)")
        }
        #expect(Similarity.phoneticKey("pat") == Similarity.phoneticKey("boot"))
    }
}
