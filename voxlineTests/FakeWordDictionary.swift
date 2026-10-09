@testable import voxline

/// Knows `known`, compared lowercased.
struct FakeWordDictionary: WordDictionary {
    var known: Set<String> = FakeWordDictionary.common

    func isKnown(_ word: String) -> Bool { known.contains(word.lowercased()) }

    static let common: Set<String> = [
        "ask", "to", "review", "the", "model", "send", "now", "ping", "about", "it", "on",
        "tuesday", "thursday", "there", "their", "slack", "thanks", "for", "help", "we",
        "could", "use", "new", "pipeline", "clod", "claude", "jason", "json", "cooper",
        "done", "arg", "max", "please", "hi", "bob",
    ]
}
