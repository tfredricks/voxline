// voxlineTests/AXTextEditorTests.swift
import ApplicationServices
import Testing
@testable import voxline

@Suite struct AXTextEditorTests {

    private let before = "hello world"
    private let expected = "hello there"

    private func makeElement(values: [AXRead<String>]) -> FakeAXTextElement {
        let fake = FakeAXTextElement()
        fake.settable[kAXSelectedTextAttribute] = .value(true)
        fake.strings[kAXValueAttribute] = values
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 6, length: 5))
        return fake
    }

    private func makeEditor(sleeps: LockedBox<[Duration]>) -> AXTextEditor {
        var editor = AXTextEditor()
        editor.sleep = { duration in sleeps.mutate { $0.append(duration) } }
        return editor
    }

    @Test func success_with_expected_value_is_verified() async {
        let fake = makeElement(values: [.value(before), .value(expected)])
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: true))
        #expect(sleeps.read().isEmpty)
        #expect(fake.stringSets.map(\.attribute) == [kAXSelectedTextAttribute])
        #expect(fake.stringSets.map(\.value) == ["there"])
    }

    @Test func write_carries_two_second_timeout() async {
        let fake = makeElement(values: [.value(before), .value(expected)])

        _ = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(fake.stringSets.map(\.timeout) == [2])
    }

    @Test func success_with_unreadable_value_is_unverified() async {
        let fake = makeElement(values: [.value(before), .failed])

        let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: false))
    }

    @Test func success_with_value_unchanged_twice_is_rejected() async {
        let fake = makeElement(values: [.value(before)])
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .rejected)
        #expect(sleeps.read() == [.milliseconds(150)])
    }

    @Test func success_with_value_landing_after_the_settle_is_verified() async {
        let fake = makeElement(values: [.value(before), .value(before), .value(expected)])
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: true))
        #expect(sleeps.read() == [.milliseconds(150)])
    }

    @Test func success_with_value_changed_elsewhere_is_unverified() async {
        let fake = makeElement(values: [.value(before), .value("hello world!")])

        let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: false))
    }

    @Test func success_without_a_readable_range_is_unverified_when_the_value_changes() async {
        let fake = makeElement(values: [.value(before), .value(expected)])
        fake.ranges[kAXSelectedTextRangeAttribute] = .failed

        let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: false))
    }

    @Test func success_with_an_out_of_bounds_range_is_unverified_when_the_value_changes() async {
        let fake = makeElement(values: [.value(before), .value(expected)])
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: NSNotFound, length: 1))

        let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: false))
    }

    @Test func unsettable_selected_text_is_rejected_without_writing() async {
        for settable in [AXRead<Bool>.value(false), .absent, .failed] {
            let fake = makeElement(values: [.value(before), .value(expected)])
            fake.settable[kAXSelectedTextAttribute] = settable

            let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

            #expect(outcome == .rejected)
            #expect(fake.stringSets.isEmpty)
        }
    }

    @Test func late_write_landing_on_the_second_poll_is_verified() async {
        let fake = makeElement(values: [.value(before), .value(before), .value(expected)])
        fake.setResults = [.cannotComplete]
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: true))
        #expect(sleeps.read() == [.milliseconds(100), .milliseconds(100)])
        #expect(fake.stringSets.count == 1)
    }

    @Test func late_write_landing_as_another_value_is_unverified() async {
        let fake = makeElement(values: [.value(before), .failed, .value("hello world!")])
        fake.setResults = [.cannotComplete]
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .applied(verified: false))
        #expect(sleeps.read().count == 2)
    }

    @Test func late_write_that_never_lands_is_unknown_after_one_second() async {
        let fake = makeElement(values: [.value(before)])
        fake.setResults = [.cannotComplete]
        let sleeps = LockedBox<[Duration]>([])

        let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

        #expect(outcome == .unknown)
        #expect(sleeps.read() == Array(repeating: .milliseconds(100), count: 10))
        #expect(fake.stringSets.count == 1)
    }

    @Test func late_write_with_an_unreadable_starting_value_is_unknown() async {
        let fake = makeElement(values: [.failed, .value(expected)])
        fake.setResults = [.cannotComplete]

        let outcome = await makeEditor(sleeps: LockedBox([])).replaceSelection(of: fake, with: "there")

        #expect(outcome == .unknown)
    }

    @Test func other_errors_are_rejected() async {
        for error in [AXError.failure, .illegalArgument, .invalidUIElement, .attributeUnsupported, .apiDisabled] {
            let fake = makeElement(values: [.value(before), .value(expected)])
            fake.setResults = [error]
            let sleeps = LockedBox<[Duration]>([])

            let outcome = await makeEditor(sleeps: sleeps).replaceSelection(of: fake, with: "there")

            #expect(outcome == .rejected)
            #expect(sleeps.read().isEmpty)
        }
    }
}
