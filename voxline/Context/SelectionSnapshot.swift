import ApplicationServices
import Foundation

/// Reads the FULL current selection from the frontmost app's focused element,
/// for the "transform selection by voice" path. Distinct from the context
/// probe: it returns the whole selection (up to a generous cap) as the primary
/// payload to rewrite — not a 500-char background sample — and returns nil in
/// secure fields so a password selection is never sent to the LLM.
protocol SelectionSnapshotting: Sendable {
    func readSelection() -> String?
}

struct DefaultSelectionSnapshot: SelectionSnapshotting {
    /// Generous ceiling so whole paragraphs transform, while bounding a runaway
    /// read (and the LLM request that follows it).
    static let selectionMax = 8_000

    /// Truncate to `selectionMax` characters. Pure so it is unit-testable
    /// without an AX round-trip.
    static func cap(_ s: String) -> String {
        s.count > selectionMax ? String(s.prefix(selectionMax)) : s
    }

    func readSelection() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let focused = AXUIElement.systemWideFocusedElement() else { return nil }
        // Never read a secure field's contents.
        if focused.stringAttribute(kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        guard
            let selected = focused.stringAttribute(kAXSelectedTextAttribute),
            !selected.isEmpty
        else {
            return nil
        }
        return Self.cap(selected)
    }
}
