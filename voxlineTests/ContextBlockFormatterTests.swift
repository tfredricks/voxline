import Testing
import Foundation
@testable import voxline

@Suite struct ContextBlockFormatterTests {

    private let trailing = "Return only the final text to insert. Do not add quotes, prefixes, or commentary."

    @Test func empty_context_omits_context_block() {
        let out = ContextBlockFormatter.format(transcript: "hello world", context: .empty)
        #expect(out == """
        Raw transcript:
        "hello world"

        \(trailing)
        """)
    }

    @Test func full_context_emits_all_lines() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        c.bundleID = "com.tinyspeck.slackmacgap"
        c.windowTitle = "#sales-pipeline — Acme workspace"
        c.fieldRole = "AXTextArea"
        c.textBeforeCursor = "Hey Kamil, following up on"
        c.textAfterCursor = ""
        c.selectedText = "the paragraph you highlighted"
        c.visibleLabels = ["Kamil Szczerba", "Q4 Renewal", "Acme"]
        c.customVocabulary = ["Cursor", "LangGraph", "canonical_title"]

        let out = ContextBlockFormatter.format(transcript: "send that update", context: c)

        #expect(out.contains("Raw transcript:\n\"send that update\""))
        #expect(out.contains("- App: Slack (com.tinyspeck.slackmacgap)"))
        #expect(out.contains("- Window: #sales-pipeline — Acme workspace"))
        #expect(out.contains("- Field: AXTextArea"))
        #expect(out.contains("- Selected text: \"the paragraph you highlighted\""))
        #expect(out.contains("- Text before cursor: \"Hey Kamil, following up on\""))
        #expect(out.contains("- Visible labels: [\"Kamil Szczerba\", \"Q4 Renewal\", \"Acme\"]"))
        #expect(out.contains("- Custom vocabulary: Cursor, LangGraph, canonical_title"))
        #expect(out.hasSuffix(trailing))
        // Empty text-after-cursor must be omitted, not emitted as "" line.
        #expect(!out.contains("- Text after cursor:"))
    }

    @Test func partial_context_omits_empty_lines() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        c.bundleID = "com.tinyspeck.slackmacgap"
        // No window, no field, no text, no labels, no vocab.
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("Context:"))
        #expect(out.contains("- App: Slack (com.tinyspeck.slackmacgap)"))
        #expect(!out.contains("- Window:"))
        #expect(!out.contains("- Field:"))
        #expect(!out.contains("- Selected text:"))
        #expect(!out.contains("- Text before cursor:"))
        #expect(!out.contains("- Visible labels:"))
        #expect(!out.contains("- Custom vocabulary:"))
    }

    @Test func secure_field_suppresses_value_lines_but_keeps_app_and_window() {
        var c = CapturedContext.empty
        c.appName = "1Password"
        c.bundleID = "com.1password.1password"
        c.windowTitle = "Login"
        c.isSecureField = true
        c.textBeforeCursor = "hunter2"   // must NOT appear
        c.selectedText = "hunter2"       // must NOT appear
        c.visibleLabels = ["Email", "Password"]
        c.customVocabulary = ["Cursor"]
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("- App: 1Password (com.1password.1password)"))
        #expect(out.contains("- Window: Login"))
        #expect(out.contains("- Field: secure"))
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("- Selected text:"))
        #expect(!out.contains("- Text before cursor:"))
        #expect(!out.contains("- Text after cursor:"))
        // Non-value lines still allowed.
        #expect(out.contains("- Visible labels: [\"Email\", \"Password\"]"))
        #expect(out.contains("- Custom vocabulary: Cursor"))
    }

    @Test func app_line_renders_without_bundle_id_when_missing() {
        var c = CapturedContext.empty
        c.appName = "Slack"
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("- App: Slack\n"))
        #expect(!out.contains("("))
    }

    @Test func transcript_is_escaped_for_embedded_quotes() {
        let out = ContextBlockFormatter.format(transcript: "she said \"hi\"", context: .empty)
        #expect(out.contains("\"she said \\\"hi\\\"\""))
    }

    @Test func transcript_is_escaped_for_embedded_backslashes() {
        let out = ContextBlockFormatter.format(transcript: "path\\to\\file", context: .empty)
        #expect(out.contains("\"path\\\\to\\\\file\""))
    }

    @Test func custom_vocabulary_entries_are_escaped() {
        var c = CapturedContext.empty
        c.customVocabulary = ["plain", "say \"hi\"", "back\\slash"]
        let out = ContextBlockFormatter.format(transcript: "hi", context: c)
        #expect(out.contains("- Custom vocabulary: plain, say \\\"hi\\\", back\\\\slash"))
    }
}
