import Testing
import Foundation
@testable import voxline

@Suite struct CapturedContextTests {

    @Test func empty_has_all_optional_fields_nil_and_arrays_empty() {
        let c = CapturedContext.empty
        #expect(c.appName == nil)
        #expect(c.bundleID == nil)
        #expect(c.windowTitle == nil)
        #expect(c.fieldRole == nil)
        #expect(c.fieldSubrole == nil)
        #expect(c.isSecureField == false)
        #expect(c.textBeforeCursor == nil)
        #expect(c.textAfterCursor == nil)
        #expect(c.selectedText == nil)
        #expect(c.customVocabulary == [])
        #expect(c.captureDurationMs == 0)
        #expect(c.captureNotes == [])
    }

    @Test func focused_field_is_nil_without_a_role_or_subrole() {
        #expect(CapturedContext.empty.focusedField == nil)
    }

    @Test func focused_field_carries_the_role_and_subrole() {
        var c = CapturedContext.empty
        c.fieldRole = "AXTextField"
        c.fieldSubrole = "AXSecureTextField"
        #expect(c.focusedField == FocusedField(role: "AXTextField", subrole: "AXSecureTextField"))
        c.fieldRole = nil
        #expect(c.focusedField == FocusedField(role: nil, subrole: "AXSecureTextField"))
    }

    @Test func equality_ignores_nothing() {
        let a = CapturedContext.empty
        var b = CapturedContext.empty
        b.appName = "Slack"
        #expect(a != b)
    }
}
