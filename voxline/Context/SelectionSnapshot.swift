import ApplicationServices
import Foundation

/// Reads the FULL current selection from the frontmost app's focused element,
/// for the "transform selection by voice" path. Distinct from the context
/// probe: it returns the whole live selection (untruncated) as the primary
/// payload to rewrite — not a 500-char background sample — and returns nil in
/// secure fields so a password selection is never sent to the LLM.
protocol SelectionSnapshotting: Sendable {
    func readSelection() -> String?
}

struct DefaultSelectionSnapshot: SelectionSnapshotting {
    /// Transform length limit enforced by the caller (`CapturePipeline`),
    /// which refuses to transform selections longer than this rather than
    /// silently truncating them. Truncating here would desync the read range
    /// from the write range: `performTransform` pastes back over the full
    /// live selection, so truncating the read would silently drop the
    /// untransformed tail of any selection over this length.
    static let selectionMax = 8_000

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
        return selected
    }
}
