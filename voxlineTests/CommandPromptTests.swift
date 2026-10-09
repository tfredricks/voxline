import Foundation
import Testing
@testable import voxline

@Suite struct CommandPromptTests {

    private static let helloWorld = FieldWindowText(
        text: "Hello world", range: UTF16Range(location: 0, length: 11), fullLength: 11
    )

    private func makeContext(
        appName: String? = "Notes",
        bundleID: String? = "com.apple.Notes",
        windowTitle: String? = "Trip plan",
        role: String? = "AXTextArea",
        isEditable: Bool = true,
        field: FieldWindowText? = helloWorld,
        selection: SelectionInfo? = nil,
        cursor: Int? = 5
    ) -> EditContext {
        EditContext(
            appName: appName, bundleID: bundleID, windowTitle: windowTitle, role: role, subrole: nil,
            isEditable: isEditable, element: nil, field: field, selection: selection, cursor: cursor,
            needsCopyFallback: false
        )
    }

    private func makeRequest(
        _ context: EditContext,
        instruction: String = "make the last paragraph shorter",
        actions: [CommandAction] = [.insert, .rewrite],
        vocabulary: [String] = ["LangGraph", "Argmax"],
        includesField: Bool = true
    ) -> CommandRequest {
        CommandRequest(
            instruction: instruction, context: context, actions: actions, vocabulary: vocabulary,
            model: "claude-haiku-4-5", includesField: includesField
        )
    }

    private func lines(_ request: CommandRequest) -> [String] {
        CommandPrompt.user(request).components(separatedBy: "\n")
    }

    // MARK: System prompt

    @Test func system_prompt_opens_with_the_task() {
        #expect(CommandPrompt.system.hasPrefix("You edit text inside a field in the user's Mac app. The user spoke an\ninstruction."))
        #expect(CommandPrompt.system.hasSuffix("- If you can't do what was asked with this text, use \"insert\" with empty\n  \"text\"."))
    }

    @Test func system_prompt_names_every_action_and_marker() {
        for action in CommandAction.allCases {
            #expect(CommandPrompt.system.contains("\"\(action.rawValue)\""))
        }
        for marker in [CommandPrompt.cursorMarker, CommandPrompt.selectionStart, CommandPrompt.selectionEnd, CommandPrompt.cutMarker] {
            #expect(CommandPrompt.system.contains(marker))
        }
    }

    @Test func markers_are_the_spec_brackets() {
        #expect(CommandPrompt.cursorMarker == "⟦cursor⟧")
        #expect(CommandPrompt.selectionStart == "⟦selection⟧")
        #expect(CommandPrompt.selectionEnd == "⟦/selection⟧")
        #expect(CommandPrompt.cutMarker == "⟦cut⟧")
    }

    // MARK: User message

    @Test func user_message_matches_the_spec_example() {
        let message = CommandPrompt.user(makeRequest(makeContext()))
        #expect(message == "INSTRUCTION: make the last paragraph shorter\nAPP: Notes — window \"Trip plan\" — text area\nSPELLINGS: LangGraph, Argmax\nACTIONS: insert, rewrite\nFIELD:\n<<<\nHello⟦cursor⟧ world\n>>>")
    }

    @Test func selection_is_wrapped_in_markers() {
        let context = makeContext(
            selection: SelectionInfo(text: "world", range: UTF16Range(location: 6, length: 5)), cursor: 6
        )
        let message = CommandPrompt.user(makeRequest(context, actions: [.replaceSelection, .insert]))
        #expect(message.hasSuffix("ACTIONS: replace_selection, insert\nFIELD:\n<<<\nHello ⟦selection⟧world⟦/selection⟧\n>>>"))
        #expect(!message.contains(CommandPrompt.cursorMarker))
    }

    @Test func cut_window_marks_both_edges_and_shifts_offsets() {
        let field = FieldWindowText(text: "Hello world", range: UTF16Range(location: 100, length: 11), fullLength: 300)
        let message = CommandPrompt.user(makeRequest(makeContext(field: field, cursor: 105)))
        #expect(message.hasSuffix("FIELD:\n<<<\n⟦cut⟧Hello⟦cursor⟧ world⟦cut⟧\n>>>"))
    }

    @Test func cut_window_shifts_the_selection() {
        let field = FieldWindowText(text: "Hello world", range: UTF16Range(location: 100, length: 11), fullLength: 111)
        let context = makeContext(
            field: field,
            selection: SelectionInfo(text: "world", range: UTF16Range(location: 106, length: 5)),
            cursor: 106
        )
        let message = CommandPrompt.user(makeRequest(context))
        #expect(message.hasSuffix("<<<\n⟦cut⟧Hello ⟦selection⟧world⟦/selection⟧\n>>>"))
    }

    @Test func cut_only_after() {
        let field = FieldWindowText(text: "Hello world", range: UTF16Range(location: 0, length: 11), fullLength: 50)
        let message = CommandPrompt.user(makeRequest(makeContext(field: field, cursor: 0)))
        #expect(message.hasSuffix("<<<\n⟦cursor⟧Hello world⟦cut⟧\n>>>"))
    }

    @Test func markers_land_on_utf16_offsets() {
        let field = FieldWindowText(text: "👍 ok", range: UTF16Range(location: 0, length: 5), fullLength: 5)
        let message = CommandPrompt.user(makeRequest(makeContext(field: field, cursor: 2)))
        #expect(message.hasSuffix("<<<\n👍⟦cursor⟧ ok\n>>>"))
    }

    @Test func unknown_cursor_renders_no_marker() {
        let message = CommandPrompt.user(makeRequest(makeContext(cursor: nil)))
        #expect(message.hasSuffix("FIELD:\n<<<\nHello world\n>>>"))
    }

    @Test func excluded_field_renders_unavailable_with_the_selection() {
        let context = makeContext(selection: SelectionInfo(text: "world", range: UTF16Range(location: 6, length: 5)), cursor: 6)
        let message = CommandPrompt.user(makeRequest(context, actions: [.replaceSelection], includesField: false))
        #expect(message.hasSuffix("ACTIONS: replace_selection\nFIELD: unavailable\nSELECTION:\n<<<\nworld\n>>>"))
        #expect(!message.contains("Hello"))
    }

    @Test func missing_field_renders_unavailable_with_an_unranged_selection() {
        let context = makeContext(field: nil, selection: SelectionInfo(text: "world", range: nil), cursor: nil)
        let message = CommandPrompt.user(makeRequest(context, actions: [.replaceSelection, .insert]))
        #expect(message.hasSuffix("FIELD: unavailable\nSELECTION:\n<<<\nworld\n>>>"))
    }

    @Test func unavailable_field_without_a_selection_says_nothing_selected() {
        let message = CommandPrompt.user(makeRequest(makeContext(field: nil, cursor: nil), actions: [.insert]))
        #expect(message.hasSuffix("ACTIONS: insert\nFIELD: unavailable\nSELECTION: nothing selected"))
    }

    @Test func empty_vocabulary_omits_spellings() {
        let message = CommandPrompt.user(makeRequest(makeContext(), vocabulary: []))
        #expect(!message.contains("SPELLINGS"))
        #expect(lines(makeRequest(makeContext(), vocabulary: []))[2] == "ACTIONS: insert, rewrite")
    }

    @Test func nil_app_and_bundle_omits_app() {
        let request = makeRequest(makeContext(appName: nil, bundleID: nil))
        #expect(!CommandPrompt.user(request).contains("APP:"))
        #expect(lines(request)[1] == "SPELLINGS: LangGraph, Argmax")
    }

    @Test func bundle_id_stands_in_for_a_missing_app_name() {
        let request = makeRequest(makeContext(appName: nil))
        #expect(lines(request)[1] == "APP: com.apple.Notes — window \"Trip plan\" — text area")
    }

    @Test func missing_window_title_is_skipped() {
        let request = makeRequest(makeContext(windowTitle: nil))
        #expect(lines(request)[1] == "APP: Notes — text area")
    }

    @Test func non_editable_field_is_labelled() {
        let request = makeRequest(makeContext(role: "AXStaticText", isEditable: false, field: nil, cursor: nil))
        #expect(lines(request)[1] == "APP: Notes — window \"Trip plan\" — static text (not editable)")
    }

    @Test func empty_actions_omit_the_line() {
        let message = CommandPrompt.user(makeRequest(makeContext(), actions: []))
        #expect(!message.contains("ACTIONS"))
    }

    // MARK: Field description

    @Test func known_roles_have_plain_names() {
        #expect(CommandPrompt.fieldDescription(role: "AXTextArea", isEditable: true) == "text area")
        #expect(CommandPrompt.fieldDescription(role: "AXTextField", isEditable: true) == "text field")
        #expect(CommandPrompt.fieldDescription(role: "AXComboBox", isEditable: true) == "combo box")
        #expect(CommandPrompt.fieldDescription(role: "AXWebArea", isEditable: true) == "web content")
        #expect(CommandPrompt.fieldDescription(role: "AXStaticText", isEditable: true) == "static text")
        #expect(CommandPrompt.fieldDescription(role: nil, isEditable: true) == "unknown field")
    }

    @Test func other_roles_are_spelled_out() {
        #expect(CommandPrompt.fieldDescription(role: "AXSearchField", isEditable: true) == "search field")
        #expect(CommandPrompt.fieldDescription(role: "AXGroup", isEditable: true) == "group")
    }

    @Test func non_editable_suffix() {
        #expect(CommandPrompt.fieldDescription(role: "AXStaticText", isEditable: false) == "static text (not editable)")
        #expect(CommandPrompt.fieldDescription(role: nil, isEditable: false) == "unknown field (not editable)")
    }

    // MARK: Allowed actions

    @Test func allowed_readable_with_selection() {
        #expect(CommandAction.allowed(fieldReadable: true, hasSelection: true, isPreset: false) == [.replaceSelection, .insert])
    }

    @Test func allowed_readable_without_selection() {
        #expect(CommandAction.allowed(fieldReadable: true, hasSelection: false, isPreset: false) == [.insert, .rewrite])
    }

    @Test func allowed_unavailable_with_selection() {
        #expect(CommandAction.allowed(fieldReadable: false, hasSelection: true, isPreset: false) == [.replaceSelection, .insert])
    }

    @Test func allowed_unavailable_without_selection() {
        #expect(CommandAction.allowed(fieldReadable: false, hasSelection: false, isPreset: false) == [.insert])
    }

    @Test func allowed_preset() {
        for readable in [true, false] {
            for selected in [true, false] {
                #expect(CommandAction.allowed(fieldReadable: readable, hasSelection: selected, isPreset: true) == [.replaceSelection])
            }
        }
    }
}
