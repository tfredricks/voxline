import Foundation
import Testing
@testable import voxline

@Suite struct StyleNotePromptTests {

    /// `count` texts, each exactly `length` characters, numbered from 0 (oldest).
    private func texts(_ count: Int, length: Int) -> [FinalText] {
        (0..<count).map { i in
            let label = "\(i)|"
            return FinalText(text: label + String(repeating: "a", count: length - label.count), bundleID: nil, date: .distantPast)
        }
    }

    @Test func keeps_the_newest_texts_within_the_budget_oldest_first() {
        var data = CategoryLearning()
        data.recentTexts = texts(25, length: 600)
        let request = StyleNotePrompt.request(category: .chat, data: data, model: "m")
        #expect(request.texts.count == 13)
        #expect(request.texts.first?.hasPrefix("12|") == true)
        #expect(request.texts.last?.hasPrefix("24|") == true)
        #expect(request.categoryName == "Chat")
        #expect(request.model == "m")
    }

    @Test func small_inputs_are_kept_whole() {
        var data = CategoryLearning()
        data.note = "- Short."
        data.recentTexts = texts(5, length: 20)
        let request = StyleNotePrompt.request(category: .email, data: data, model: "m")
        #expect(request.texts.count == 5)
        #expect(request.currentNote == "- Short.")
    }

    @Test func keeps_the_newest_pairs_within_the_budget() {
        var data = CategoryLearning()
        data.recentTexts = texts(1, length: 20)
        data.stylePairs = (0..<10).map {
            StylePair(before: "\($0)" + String(repeating: "b", count: 499), after: String(repeating: "c", count: 500), date: .distantPast)
        }
        let request = StyleNotePrompt.request(category: .chat, data: data, model: "m")
        #expect(request.pairs.count == 6)
        #expect(request.pairs.last?.before.hasPrefix("9") == true)
    }

    @Test func user_prompt_lists_note_texts_and_corrections() {
        let request = StyleNoteRequest(
            categoryName: "Chat", currentNote: "- Short.",
            texts: ["Sounds good", #"On "it""#],
            pairs: [StylePair(before: "Thanks.", after: "Thanks", date: .distantPast)],
            model: "m"
        )
        #expect(StyleNotePrompt.user(request) == #"""
        Current note:
        - Short.

        Texts:
        1. "Sounds good"
        2. "On \"it\""

        Corrections:
        "Thanks." → "Thanks"
        """#)
    }

    @Test func user_prompt_without_note_or_corrections_is_just_texts() {
        let request = StyleNoteRequest(categoryName: "Chat", currentNote: nil, texts: ["Sounds good"], pairs: [], model: "m")
        #expect(StyleNotePrompt.user(request) == "Texts:\n1. \"Sounds good\"")
    }

    @Test func system_prompt_names_the_category_and_forbids_content() {
        let system = StyleNotePrompt.system(categoryName: "Email")
        #expect(system.contains("writing habits in Email messages"))
        #expect(system.contains("Never quote the texts"))
    }

    @Test func the_reply_is_trimmed_and_cut_at_a_line_break() {
        #expect(StyleNotePrompt.note(fromReply: "  \n ") == nil)
        #expect(StyleNotePrompt.note(fromReply: "\n- Short.\n") == "- Short.")
        let lines = String(repeating: "x", count: 550) + "\n" + String(repeating: "y", count: 149)
        #expect(StyleNotePrompt.note(fromReply: lines) == String(repeating: "x", count: 550))
        #expect(StyleNotePrompt.note(fromReply: String(repeating: "z", count: 700))?.count == LearningStore.noteCap)
    }

    @Test func the_cap_counts_utf16_units_and_never_cuts_mid_line() throws {
        let first = String(repeating: "x", count: 400)
        let second = String(repeating: "\u{1F600}", count: 150)
        let reply = first + "\n" + second
        #expect(reply.count < LearningStore.noteCap)
        #expect(reply.utf16.count > LearningStore.noteCap)
        let note = try #require(StyleNotePrompt.note(fromReply: reply))
        #expect(note == first)
        #expect(LearningStore.capped(note, LearningStore.noteCap) == note)
    }

    @Test func thinking_models_get_headroom() {
        #expect(LLMRequest.styleNoteBudget(model: "claude-haiku-4-5") == 400)
        #expect(LLMRequest.styleNoteBudget(model: "claude-sonnet-5-5") == 400 + 4_096)
    }
}
