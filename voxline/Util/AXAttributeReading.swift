import ApplicationServices

/// Tiny read-only AX helpers used by the focused-element inspectors, the
/// paste-eligibility menu walk, and the context probe. Each call is one
/// synchronous cross-process IPC; callers that need a deadline guard wrap
/// these themselves.
extension AXUIElement {

    /// System-wide focused UI element, or nil when no element is exposed.
    /// Returns nil when Accessibility isn't trusted as well — the underlying
    /// AX call quietly fails in that case.
    static func systemWideFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        return system.elementAttribute(kAXFocusedUIElementAttribute as CFString)
    }

    /// Read a string-valued attribute. Returns nil on AX failure or type
    /// mismatch.
    func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Read an AXUIElement-valued attribute. Verifies the CFTypeID so a
    /// surprise CFType (string, number, AXValue) doesn't get force-cast
    /// into an AXUIElement.
    func elementAttribute(_ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    /// Read a Bool-valued attribute. Returns nil on AX failure or non-Bool
    /// payload.
    func boolAttribute(_ attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute, &value) == .success else {
            return nil
        }
        return value as? Bool
    }
}
