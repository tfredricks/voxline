import Foundation
import Testing
@testable import voxline

@Suite struct EditPlannerTests {

    private static let fieldText = "the cat sat"
    private static let windowLocation = 100
    private static let selectionRange = UTF16Range(location: 104, length: 3)

    private func makeContext(
        isEditable: Bool = true,
        fieldReadable: Bool = true,
        selection: SelectionInfo? = nil,
        cursor: Int? = nil
    ) -> EditContext {
        let field = fieldReadable
            ? FieldWindowText(
                text: Self.fieldText,
                range: UTF16Range(location: Self.windowLocation, length: (Self.fieldText as NSString).length),
                fullLength: 500
            )
            : nil
        return EditContext(
            appName: "Notes", bundleID: "com.apple.Notes", windowTitle: "Trip plan", role: "AXTextArea", subrole: nil,
            isEditable: isEditable, element: nil, field: field, selection: selection, cursor: cursor,
            needsCopyFallback: false
        )
    }

    private var rangedSelection: SelectionInfo { SelectionInfo(text: "cat", range: Self.selectionRange) }
    private var unrangedSelection: SelectionInfo { SelectionInfo(text: "cat", range: nil) }

    private func plan(_ action: CommandAction, _ text: String, _ context: EditContext, isPreset: Bool = false) -> PlannedEdit {
        EditPlanner.plan(result: CommandResult(action: action, text: text), context: context, isPreset: isPreset)
    }

    // MARK: Not editable

    @Test func non_editable_with_text_copies() {
        let context = makeContext(isEditable: false, fieldReadable: false, selection: unrangedSelection)
        for action in CommandAction.allCases {
            #expect(plan(action, "summary", context) == .copy("summary"))
        }
    }

    @Test func non_editable_with_empty_text_does_nothing() {
        let context = makeContext(isEditable: false, fieldReadable: false, selection: unrangedSelection)
        #expect(plan(.insert, "", context) == .nothing("Couldn't apply that"))
    }

    // MARK: replace_selection

    @Test func replace_selection_without_selection_inserts_at_cursor() {
        let context = makeContext(cursor: 3)
        #expect(plan(.replaceSelection, "dog", context) == .replace(UTF16Range(location: 3, length: 0), expected: "", with: "dog"))
    }

    @Test func replace_selection_without_selection_or_cursor_inserts_at_caret() {
        let context = makeContext(fieldReadable: false)
        #expect(plan(.replaceSelection, "dog", context) == .insertAtCaret("dog"))
    }

    @Test func replace_selection_without_selection_and_empty_text_does_nothing() {
        let context = makeContext(cursor: 3)
        #expect(plan(.replaceSelection, "", context) == .nothing("Couldn't apply that"))
    }

    @Test func replace_selection_equal_to_selection_is_no_change() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.replaceSelection, "cat", context) == .nothing("No changes"))
    }

    @Test func replace_selection_with_readable_field_replaces_the_range() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.replaceSelection, "dog", context) == .replace(Self.selectionRange, expected: "cat", with: "dog"))
    }

    @Test func replace_selection_with_empty_text_deletes() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.replaceSelection, "", context) == .replace(Self.selectionRange, expected: "cat", with: ""))
    }

    @Test func replace_selection_with_unavailable_field_replaces_the_live_selection() {
        let context = makeContext(fieldReadable: false, selection: rangedSelection)
        #expect(plan(.replaceSelection, "dog", context) == .replaceLiveSelection("dog"))
    }

    @Test func replace_selection_with_unranged_selection_replaces_the_live_selection() {
        let context = makeContext(fieldReadable: false, selection: unrangedSelection)
        #expect(plan(.replaceSelection, "dog", context) == .replaceLiveSelection("dog"))
    }

    // MARK: insert

    @Test func insert_empty_text_does_nothing() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.insert, "", context) == .nothing("Couldn't apply that"))
    }

    @Test func insert_with_readable_selection_goes_after_it() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.insert, " nap", context) == .replace(UTF16Range(location: 107, length: 0), expected: "", with: " nap"))
    }

    @Test func insert_with_unranged_selection_goes_after_the_live_selection() {
        let context = makeContext(fieldReadable: false, selection: unrangedSelection)
        #expect(plan(.insert, " nap", context) == .insertAfterLiveSelection(" nap"))
    }

    @Test func insert_with_cursor_goes_at_the_cursor() {
        let context = makeContext(cursor: 111)
        #expect(plan(.insert, " down", context) == .replace(UTF16Range(location: 111, length: 0), expected: "", with: " down"))
    }

    @Test func insert_without_cursor_goes_at_the_caret() {
        let context = makeContext(fieldReadable: false)
        #expect(plan(.insert, "Hello", context) == .insertAtCaret("Hello"))
    }

    // MARK: rewrite

    @Test func rewrite_with_unavailable_field_does_nothing() {
        let context = makeContext(fieldReadable: false)
        #expect(plan(.rewrite, "the dog sat", context) == .nothing("Couldn't apply that"))
    }

    @Test func rewrite_replaces_the_minimal_hunk_offset_by_the_window() {
        let context = makeContext(cursor: 111)
        #expect(plan(.rewrite, "the dog sat", context) == .replace(UTF16Range(location: 104, length: 3), expected: "cat", with: "dog"))
    }

    @Test func rewrite_with_a_selection_still_diffs() {
        let context = makeContext(selection: SelectionInfo(text: "the", range: UTF16Range(location: 100, length: 3)), cursor: 100)
        #expect(plan(.rewrite, "the cat sat down", context) == .replace(UTF16Range(location: 111, length: 0), expected: "", with: " down"))
    }

    @Test func rewrite_identical_is_no_change() {
        let context = makeContext(cursor: 111)
        #expect(plan(.rewrite, "the cat sat", context) == .nothing("No changes"))
    }

    @Test func rewrite_empty_does_nothing() {
        let context = makeContext(cursor: 111)
        #expect(plan(.rewrite, "", context) == .nothing("Couldn't apply that"))
    }

    // MARK: Presets and markers

    @Test func preset_insert_with_selection_replaces_the_selection() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.insert, "dog", context, isPreset: true) == .replace(Self.selectionRange, expected: "cat", with: "dog"))
    }

    @Test func preset_rewrite_with_live_selection_replaces_the_live_selection() {
        let context = makeContext(fieldReadable: false, selection: unrangedSelection)
        #expect(plan(.rewrite, "dog", context, isPreset: true) == .replaceLiveSelection("dog"))
    }

    @Test func markers_are_stripped_before_comparing() {
        let context = makeContext(selection: rangedSelection, cursor: 104)
        #expect(plan(.replaceSelection, "⟦selection⟧cat⟦/selection⟧", context) == .nothing("No changes"))
        #expect(plan(.replaceSelection, "d⟦cursor⟧og", context) == .replace(Self.selectionRange, expected: "cat", with: "dog"))
    }

    @Test func markers_are_stripped_from_a_rewrite() {
        let context = makeContext(cursor: 111)
        #expect(plan(.rewrite, "⟦cut⟧the cat sat⟦cursor⟧⟦cut⟧", context) == .nothing("No changes"))
    }

    @Test func text_of_only_markers_counts_as_empty() {
        let context = makeContext(cursor: 111)
        #expect(plan(.insert, "⟦cursor⟧", context) == .nothing("Couldn't apply that"))
    }
}
