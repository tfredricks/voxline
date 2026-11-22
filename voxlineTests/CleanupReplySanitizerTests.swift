import Testing
import Foundation
@testable import voxline

@Suite struct CleanupReplySanitizerTests {

    @Test func reported_leak_keeps_only_the_final_text() {
        let reply = """
        Let's just double check. Is this the best design to have this stored in GitHub with a personal access token?

        Wait, I need to correct my output: the transcript contains "Let's just double check" which should drop "just" as filler. Final text:

        Let's double check. Is this the best design to have this stored in GitHub with a personal access token?
        """
        #expect(CleanupReplySanitizer.finalText(from: reply)
                == "Let's double check. Is this the best design to have this stored in GitHub with a personal access token?")
    }

    @Test func label_on_its_own_line_with_text_on_the_same_line() {
        let reply = "Meet Tuesday.\n\nActually, the speaker corrected to Wednesday.\nCorrected text: Meet Wednesday."
        #expect(CleanupReplySanitizer.finalText(from: reply) == "Meet Wednesday.")
    }

    @Test func bold_markdown_label_is_recognized() {
        let reply = "Ship it to dove.\n\nWait, my output kept a mishearing.\n\n**Final text:**\nShip it to dev."
        #expect(CleanupReplySanitizer.finalText(from: reply) == "Ship it to dev.")
    }

    @Test func last_label_wins_when_the_model_revises_twice() {
        let reply = "A\n\nWait, fix that. Final text: B\n\nActually, correction. Final output: C"
        #expect(CleanupReplySanitizer.finalText(from: reply) == "C")
    }

    @Test func multi_paragraph_final_text_is_kept_whole() {
        let reply = "x\n\nWait, I need to correct my output.\nFinal text:\nFirst paragraph.\n\nSecond paragraph."
        #expect(CleanupReplySanitizer.finalText(from: reply) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test func ordinary_reply_passes_through_unchanged() {
        let reply = "Let's double check the design before we merge."
        #expect(CleanupReplySanitizer.finalText(from: reply) == reply)
    }

    @Test func dictated_wait_without_a_label_passes_through() {
        let reply = "Wait, I need to correct my earlier message: the meeting is at 3 PM."
        #expect(CleanupReplySanitizer.finalText(from: reply) == reply)
    }

    @Test func dictated_label_without_a_revision_note_passes_through() {
        let reply = "Here is the plan.\nFinal version: ship on Friday."
        #expect(CleanupReplySanitizer.finalText(from: reply) == reply)
    }

    @Test func label_mid_sentence_is_not_a_label() {
        let reply = "Wait, the final text: we ship Friday."
        #expect(CleanupReplySanitizer.finalText(from: reply) == reply)
    }

    @Test func empty_text_after_the_label_keeps_the_reply() {
        let reply = "Draft.\n\nWait, I need to fix my output. Final text:\n   "
        #expect(CleanupReplySanitizer.finalText(from: reply) == reply)
    }
}
