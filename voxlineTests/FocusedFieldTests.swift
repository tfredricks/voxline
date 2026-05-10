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
}
