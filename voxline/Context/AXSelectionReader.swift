import ApplicationServices
import Foundation

/// Reads the focused element's selection through Accessibility and falls back
/// to the synthetic-Cmd+C reader only when AX exposes nothing. Secure fields
/// never yield a selection.
struct AXSelectionReader: SelectionSnapshotting {

    let readAX: @Sendable () -> String?
    let fallback: any SelectionSnapshotting

    init(
        readAX: @escaping @Sendable () -> String? = AXSelectionReader.focusedSelectedText,
        fallback: any SelectionSnapshotting = DefaultSelectionSnapshot()
    ) {
        self.readAX = readAX
        self.fallback = fallback
    }

    func readSelection() async -> String? {
        if let selected = readAX(), !selected.isEmpty { return selected }
        return await fallback.readSelection()
    }

    static let focusedSelectedText: @Sendable () -> String? = {
        guard AXIsProcessTrusted(),
              let element = AXUIElement.systemWideFocusedElement() else { return nil }
        if element.stringAttribute(kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) { return nil }
        return element.stringAttribute(kAXSelectedTextAttribute)
    }
}
