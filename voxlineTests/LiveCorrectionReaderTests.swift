import ApplicationServices
import Testing
@testable import voxline

@Suite struct LiveCorrectionReaderTests {

    private func field(value: String?, caret: Int?, subrole: AXRead<String> = .absent) -> FakeAXTextElement {
        let element = FakeAXTextElement()
        element.strings[kAXSubroleAttribute] = [subrole]
        if let value { element.setValue(value) }
        if let caret { element.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: caret, length: 0)) }
        return element
    }

    @Test func anchors_text_that_ends_at_the_caret() throws {
        let read = LiveCorrectionReader.anchor(in: field(value: "Hi, ask Bob", caret: 11), inserted: "ask Bob")
        guard case .anchored(let anchor) = read else { Issue.record("\(read)"); return }
        #expect(anchor.text.range == UTF16Range(location: 4, length: 7))
        #expect(anchor.text.prefix == "Hi, ")
    }

    @Test func secure_fields_and_unanswered_subroles_are_skipped() {
        let secure = field(value: "x", caret: 1, subrole: .value(kAXSecureTextFieldSubrole as String))
        #expect(LiveCorrectionReader.anchor(in: secure, inserted: "x").skipped == .secure)
        let hung = field(value: "x", caret: 1, subrole: .failed)
        #expect(LiveCorrectionReader.anchor(in: hung, inserted: "x").skipped == .notResponding)
    }

    @Test func an_unreadable_value_or_caret_is_skipped() {
        #expect(LiveCorrectionReader.anchor(in: field(value: nil, caret: 1), inserted: "x").skipped == .valueUnreadable)
        #expect(LiveCorrectionReader.anchor(in: field(value: "x", caret: nil), inserted: "x").skipped == .valueUnreadable)
    }

    @Test func text_not_at_the_caret_is_skipped() {
        #expect(LiveCorrectionReader.anchor(in: field(value: "ask Bob", caret: 2), inserted: "ask Bob").skipped == .notAtCaret)
    }

    @Test func untrusted_or_unfocused_is_skipped_before_any_read() {
        let untrusted = LiveCorrectionReader(isTrusted: { false }, focused: { .absent })
        #expect(untrusted.anchor(for: "x").skipped == .notTrusted)
        let nothing = LiveCorrectionReader(isTrusted: { true }, focused: { .absent })
        #expect(nothing.anchor(for: "x").skipped == .noElement)
        let hung = LiveCorrectionReader(isTrusted: { true }, focused: { .failed })
        #expect(hung.anchor(for: "x").skipped == .notResponding)
    }
}
