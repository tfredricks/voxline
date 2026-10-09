import ApplicationServices
import Foundation
import Testing
@testable import voxline

@Suite struct EditContextReaderTests {

    private func makeFake(role: String = "AXTextArea") -> FakeAXTextElement {
        let fake = FakeAXTextElement()
        fake.strings[kAXRoleAttribute] = [.value(role)]
        return fake
    }

    private func makeReader(
        _ fake: FakeAXTextElement,
        bundleID: String = "com.apple.Notes",
        policy: EditContextPolicy = .default
    ) -> EditContextReader {
        EditContextReader(
            source: {
                .value(FocusedElementSnapshot(
                    element: fake, appName: "Notes", bundleID: bundleID, windowTitle: "Trip plan"
                ))
            },
            policy: policy,
            isAXTrusted: { true }
        )
    }

    private func readContext(_ reader: EditContextReader) throws -> EditContext {
        try reader.read().get()
    }

    // MARK: Selection table

    @Test func row1_readable_field_with_selection() throws {
        let fake = makeFake()
        fake.setValue("hello world")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 6, length: 5))

        let context = try readContext(makeReader(fake))

        #expect(context.field?.text == "hello world")
        #expect(context.field?.range == UTF16Range(location: 0, length: 11))
        #expect(context.field?.fullLength == 11)
        #expect(context.selection == SelectionInfo(text: "world", range: UTF16Range(location: 6, length: 5)))
        #expect(context.cursor == 6)
        #expect(context.needsCopyFallback == false)
        #expect(context.element == fake.ref)
        #expect(context.isEditable)
        #expect(context.appName == "Notes")
        #expect(context.bundleID == "com.apple.Notes")
        #expect(context.windowTitle == "Trip plan")
        #expect(context.role == "AXTextArea")
        #expect(context.subrole == nil)
        #expect(!fake.reads.contains(kAXSelectedTextAttribute))
    }

    @Test func row1_readable_field_no_selection() throws {
        let fake = makeFake()
        fake.setValue("hello world")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 3, length: 0))

        let context = try readContext(makeReader(fake))

        #expect(context.selection == nil)
        #expect(context.cursor == 3)
        #expect(context.field?.text == "hello world")
        #expect(context.needsCopyFallback == false)
    }

    @Test func row1_selection_is_sliced_in_utf16_units() throws {
        let fake = makeFake()
        fake.setValue("😀 hi 😀")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 3, length: 2))

        let context = try readContext(makeReader(fake))

        #expect(context.selection == SelectionInfo(text: "hi", range: UTF16Range(location: 3, length: 2)))
        #expect(context.field?.fullLength == 8)
    }

    @Test func row2_zero_length_range_without_value_is_trusted_no_selection() throws {
        let fake = makeFake()
        fake.strings[kAXValueAttribute] = [.failed]
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 3, length: 0))

        let context = try readContext(makeReader(fake))

        #expect(context.selection == nil)
        #expect(context.field == nil)
        #expect(context.cursor == nil)
        #expect(context.needsCopyFallback == false)
    }

    @Test func row3_range_and_selected_text_without_value() throws {
        for value: AXRead<String> in [.absent, .failed] {
            let fake = makeFake()
            fake.strings[kAXValueAttribute] = [value]
            fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 2, length: 3))
            fake.strings[kAXSelectedTextAttribute] = [.value("abc")]

            let context = try readContext(makeReader(fake))

            #expect(context.selection == SelectionInfo(text: "abc", range: UTF16Range(location: 2, length: 3)))
            #expect(context.field == nil)
            #expect(context.cursor == nil)
            #expect(context.needsCopyFallback == false)
        }
    }

    @Test func gap_range_without_readable_text_falls_back() throws {
        for selectedText: AXRead<String> in [.value(""), .absent, .failed] {
            let fake = makeFake()
            fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 2, length: 3))
            fake.strings[kAXSelectedTextAttribute] = [selectedText]

            let context = try readContext(makeReader(fake))

            #expect(context.needsCopyFallback)
            #expect(context.selection == nil)
            #expect(context.field == nil)
            #expect(context.cursor == nil)
        }
    }

    @Test func range_outside_value_keeps_selected_text_but_drops_the_range() throws {
        let fake = makeFake()
        fake.setValue("hi")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 5, length: 3))
        fake.strings[kAXSelectedTextAttribute] = [.value("abc")]

        let context = try readContext(makeReader(fake))

        #expect(context.selection == SelectionInfo(text: "abc", range: nil))
        #expect(context.field == nil)
        #expect(context.cursor == nil)
        #expect(context.needsCopyFallback == false)
    }

    @Test func range_outside_value_without_selected_text_falls_back() throws {
        for selectedText: AXRead<String> in [.value(""), .absent, .failed] {
            let fake = makeFake()
            fake.setValue("hi")
            fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 1, length: 3))
            fake.strings[kAXSelectedTextAttribute] = [selectedText]

            let context = try readContext(makeReader(fake))

            #expect(context.needsCopyFallback)
            #expect(context.selection == nil)
            #expect(context.field == nil)
            #expect(context.cursor == nil)
        }
    }

    @Test func zero_length_range_outside_value_is_no_selection() throws {
        let fake = makeFake()
        fake.setValue("hi")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 9, length: 0))

        let context = try readContext(makeReader(fake))

        #expect(context.selection == nil)
        #expect(context.cursor == nil)
        #expect(context.field == nil)
        #expect(context.needsCopyFallback == false)
    }

    private static let hostileRanges = [
        UTF16Range(location: NSNotFound, length: 1),
        UTF16Range(location: -1, length: 3),
        UTF16Range(location: 2, length: -1),
        UTF16Range(location: 1, length: Int.max),
    ]

    @Test func hostile_range_is_treated_as_absent() throws {
        for hostile in Self.hostileRanges {
            for value: AXRead<String> in [.value("xx abc"), .absent] {
                let fake = makeFake()
                fake.strings[kAXValueAttribute] = [value]
                fake.ranges[kAXSelectedTextRangeAttribute] = .value(hostile)
                fake.strings[kAXSelectedTextAttribute] = [.value("abc")]

                let context = try readContext(makeReader(fake))

                #expect(context.selection == SelectionInfo(text: "abc", range: nil))
                #expect(context.field == nil)
                #expect(context.cursor == nil)
                #expect(context.needsCopyFallback == false)
            }
        }
    }

    @Test func hostile_range_without_selected_text_falls_back() throws {
        for hostile in Self.hostileRanges {
            let fake = makeFake()
            fake.ranges[kAXSelectedTextRangeAttribute] = .value(hostile)

            let context = try readContext(makeReader(fake))

            #expect(context.needsCopyFallback)
            #expect(context.selection == nil)
        }
    }

    @Test func hostile_range_on_a_non_editable_element_is_treated_as_absent() throws {
        let fake = makeFake(role: "AXStaticText")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: NSNotFound, length: 1))
        fake.strings[kAXSelectedTextAttribute] = [.value("quote")]

        let context = try readContext(makeReader(fake))

        #expect(context.selection == SelectionInfo(text: "quote", range: nil))
    }

    @Test func row4_selected_text_without_range() throws {
        for range: AXRead<UTF16Range> in [.failed, .absent] {
            let fake = makeFake()
            fake.setValue("xx abc")
            fake.ranges[kAXSelectedTextRangeAttribute] = range
            fake.strings[kAXSelectedTextAttribute] = [.value("abc")]

            let context = try readContext(makeReader(fake))

            #expect(context.selection == SelectionInfo(text: "abc", range: nil))
            #expect(context.field == nil)
            #expect(context.cursor == nil)
            #expect(context.needsCopyFallback == false)
        }
    }

    @Test func row5_inconclusive() throws {
        for selectedText: AXRead<String> in [.absent, .value(""), .failed] {
            let fake = makeFake()
            fake.ranges[kAXSelectedTextRangeAttribute] = .absent
            fake.strings[kAXSelectedTextAttribute] = [selectedText]

            let context = try readContext(makeReader(fake))

            #expect(context.needsCopyFallback)
            #expect(context.selection == nil)
            #expect(context.field == nil)
            #expect(context.cursor == nil)
        }
    }

    // MARK: Element checks

    @Test func non_editable_keeps_selection_skips_value() throws {
        let fake = makeFake(role: "AXStaticText")
        fake.setValue("a whole quote here")
        fake.strings[kAXSelectedTextAttribute] = [.value("quote")]

        let context = try readContext(makeReader(fake))

        #expect(context.isEditable == false)
        #expect(context.selection == SelectionInfo(text: "quote", range: nil))
        #expect(context.field == nil)
        #expect(!fake.reads.contains(kAXValueAttribute))
    }

    @Test func secure_subrole_refuses() {
        let fake = makeFake(role: "AXTextField")
        fake.strings[kAXSubroleAttribute] = [.value("AXSecureTextField")]
        fake.setValue("hunter2")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 7))

        #expect(makeReader(fake).read() == .failure(.secureField))
        #expect(!fake.reads.contains(kAXValueAttribute))
        #expect(!fake.reads.contains(kAXSelectedTextAttribute))
    }

    @Test func failed_subrole_refuses() {
        let fake = makeFake()
        fake.strings[kAXSubroleAttribute] = [.failed]
        fake.setValue("hello")

        #expect(makeReader(fake).read() == .failure(.notResponding))
        #expect(!fake.reads.contains(kAXValueAttribute))

        let failedSource = EditContextReader(source: { .failed }, isAXTrusted: { true })
        #expect(failedSource.read() == .failure(.notResponding))
    }

    @Test func failed_role_degrades_to_nil_and_editable() throws {
        let fake = FakeAXTextElement()
        fake.strings[kAXRoleAttribute] = [.failed]
        fake.setValue("hello")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 5, length: 0))

        let context = try readContext(makeReader(fake))

        #expect(context.role == nil)
        #expect(context.isEditable)
        #expect(context.cursor == 5)
    }

    @Test func search_subrole_is_reported() throws {
        let fake = makeFake(role: "AXTextField")
        fake.strings[kAXSubroleAttribute] = [.value("AXSearchField")]
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 0))

        let context = try readContext(makeReader(fake))

        #expect(context.subrole == "AXSearchField")
        #expect(context.role == "AXTextField")
    }

    @Test func absent_focus_is_a_non_editable_empty_context() throws {
        let reader = EditContextReader(source: { .absent }, isAXTrusted: { true })

        let context = try reader.read().get()

        #expect(context == EditContext(
            isEditable: false, element: nil, field: nil, selection: nil, cursor: nil, needsCopyFallback: false
        ))
    }

    // MARK: Policy

    @Test func default_policy_values() {
        let policy = EditContextPolicy.default
        #expect(policy.untrustedFieldBundleIDs == ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"])
        #expect(policy.fieldBudget == 12_000)
        #expect(policy.selectionMax == 8_000)
    }

    @Test func untrusted_bundle_drops_field_keeps_selection() throws {
        for bundleID in ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"] {
            let fake = makeFake()
            fake.setValue("let x = 1")
            fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 4, length: 1))

            let context = try readContext(makeReader(fake, bundleID: bundleID))

            #expect(context.field == nil)
            #expect(context.cursor == nil)
            #expect(context.selection == SelectionInfo(text: "x", range: UTF16Range(location: 4, length: 1)))
            #expect(context.needsCopyFallback == false)
            #expect(context.bundleID == bundleID)
        }
    }

    @Test func selection_over_max_refuses() throws {
        let fake = makeFake()
        fake.setValue(String(repeating: "a", count: 9_000))
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 8_001))
        #expect(makeReader(fake).read() == .failure(.selectionTooLong))

        let atMax = makeFake()
        atMax.setValue(String(repeating: "a", count: 9_000))
        atMax.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 8_000))
        let context = try readContext(makeReader(atMax))
        #expect(context.selection?.text.utf16.count == 8_000)
    }

    @Test func selection_cap_counts_utf16_units() {
        let fake = makeFake()
        fake.ranges[kAXSelectedTextRangeAttribute] = .absent
        fake.strings[kAXSelectedTextAttribute] = [.value(String(repeating: "😀", count: 4_001))]

        #expect(makeReader(fake).read() == .failure(.selectionTooLong))
    }

    @Test func selection_cap_follows_the_policy() {
        let fake = makeFake()
        fake.ranges[kAXSelectedTextRangeAttribute] = .absent
        fake.strings[kAXSelectedTextAttribute] = [.value("abcdef")]
        var policy = EditContextPolicy.default
        policy.selectionMax = 5

        #expect(makeReader(fake, policy: policy).read() == .failure(.selectionTooLong))
    }

    @Test func field_is_windowed() throws {
        let fake = makeFake()
        fake.setValue(String(repeating: "a", count: 30_000))
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 15_000, length: 0))

        let context = try readContext(makeReader(fake))
        let field = try #require(context.field)

        #expect(field.range == UTF16Range(location: 7_000, length: 12_000))
        #expect(field.fullLength == 30_000)
        #expect((field.text as NSString).length == 12_000)
        #expect(field.cutBefore && field.cutAfter)
        #expect(context.cursor == 15_000)
    }

    @Test func field_window_is_anchored_on_the_selection() throws {
        let fake = makeFake()
        let value = String(repeating: "a", count: 10_000) + "TARGET" + String(repeating: "b", count: 20_000)
        fake.setValue(value)
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 10_000, length: 6))

        let context = try readContext(makeReader(fake))
        let field = try #require(context.field)

        let offset = 10_000 - field.range.location
        #expect((field.text as NSString).substring(with: NSRange(location: offset, length: 6)) == "TARGET")
        #expect(field.range.length == 12_000)
    }

    @Test func field_budget_follows_the_policy() throws {
        let fake = makeFake()
        fake.setValue(String(repeating: "a", count: 300))
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 150, length: 0))
        var policy = EditContextPolicy.default
        policy.fieldBudget = 120

        let context = try readContext(makeReader(fake, policy: policy))

        #expect(context.field?.range == UTF16Range(location: 70, length: 120))
    }

    @Test func whole_field_window_is_not_cut() throws {
        let fake = makeFake()
        fake.setValue("short note")
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 0))

        let field = try #require(try readContext(makeReader(fake)).field)

        #expect(!field.cutBefore)
        #expect(!field.cutAfter)
    }

    @Test func not_trusted_refuses_without_reading() {
        let fake = makeFake()
        fake.setValue("hello")
        let sourceReads = LockedBox(0)
        let reader = EditContextReader(
            source: {
                sourceReads.mutate { $0 += 1 }
                return .value(FocusedElementSnapshot(element: fake, appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Trip plan"))
            },
            isAXTrusted: { false }
        )

        #expect(reader.read() == .failure(.accessibilityNotGranted))
        #expect(sourceReads.read() == 0)
        #expect(fake.reads.isEmpty)
    }
}
