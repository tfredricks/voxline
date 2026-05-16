import ApplicationServices

/// Reads role + subrole from the system-wide AX focused element. Returns nil
/// when Accessibility isn't trusted, no element is focused, or the element
/// doesn't expose role info — ModeRouter callers degrade to bundle-ID-only
/// routing in that case.
struct AXFocusedFieldInspector: FocusedFieldInspecting {

    func inspect() -> FocusedField? {
        guard AXIsProcessTrusted() else { return nil }
        guard let element = AXUIElement.systemWideFocusedElement() else { return nil }
        let role = element.stringAttribute(kAXRoleAttribute)
        let subrole = element.stringAttribute(kAXSubroleAttribute)
        if role == nil && subrole == nil { return nil }
        return FocusedField(role: role, subrole: subrole)
    }
}
