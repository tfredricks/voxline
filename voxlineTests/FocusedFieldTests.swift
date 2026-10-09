import Testing
@testable import voxline

@Suite struct FocusedFieldTests {

    @Test func secure_subrole_classifies_as_secure() {
        let f = FocusedField(role: "AXTextField", subrole: "AXSecureTextField")
        #expect(f.kind == .secure)
    }

    @Test func search_subrole_classifies_as_search() {
        let f = FocusedField(role: "AXTextField", subrole: "AXSearchField")
        #expect(f.kind == .search)
    }

    @Test func text_field_with_no_subrole_classifies_as_text() {
        let f = FocusedField(role: "AXTextField", subrole: nil)
        #expect(f.kind == .text)
    }

    @Test func text_area_classifies_as_text() {
        let f = FocusedField(role: "AXTextArea", subrole: nil)
        #expect(f.kind == .text)
    }

    @Test func unknown_subrole_falls_through_to_text() {
        let f = FocusedField(role: "AXTextField", subrole: "AXFooBar")
        #expect(f.kind == .text)
    }

    @Test func button_is_not_editable() {
        #expect(FocusedField(role: "AXButton", subrole: nil).isEditable == false)
    }

    @Test func static_text_is_not_editable() {
        #expect(FocusedField(role: "AXStaticText", subrole: nil).isEditable == false)
    }

    @Test func text_area_and_text_field_are_editable() {
        #expect(FocusedField(role: "AXTextArea", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXTextField", subrole: nil).isEditable)
    }

    @Test func cell_based_containers_are_editable() {
        #expect(FocusedField(role: "AXCell", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXTable", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXRow", subrole: nil).isEditable)
    }

    @Test func unknown_and_nil_roles_are_treated_as_editable() {
        #expect(FocusedField(role: "AXGroup", subrole: nil).isEditable)
        #expect(FocusedField(role: "AXWebArea", subrole: nil).isEditable)
        #expect(FocusedField(role: nil, subrole: nil).isEditable)
    }
}
