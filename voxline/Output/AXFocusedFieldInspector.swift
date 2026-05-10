import ApplicationServices

/// Reads role + subrole from the system-wide AX focused element. Returns nil
/// when Accessibility isn't trusted, no element is focused, or the element
/// doesn't expose role info — ModeRouter callers degrade to bundle-ID-only
/// routing in that case.
struct AXFocusedFieldInspector: FocusedFieldInspecting {

    func inspect() -> FocusedField? {
        guard AXIsProcessTrusted() else { return nil }
        guard let element = focusedElement() else { return nil }
        let role = stringAttribute(kAXRoleAttribute, on: element)
        let subrole = stringAttribute(kAXSubroleAttribute, on: element)
        if role == nil && subrole == nil { return nil }
        return FocusedField(role: role, subrole: subrole)
    }

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func stringAttribute(_ attribute: String, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value as? String
    }
}
