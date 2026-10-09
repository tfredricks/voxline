import Foundation
import ApplicationServices

/// Coarse classification of the focused UI element, derived from AX role +
/// subrole. Drives ModeRouter's field-specific lookup so users can configure,
/// e.g., a "Slack search" mode distinct from "Slack chat".
///
/// Kept intentionally small — AX subroles for search and secure inputs are
/// well-defined across AppKit/Catalyst/Electron, but "code editor" detection
/// from AX alone is unreliable, so code-style cleanup is left to bundle-ID
/// matching (Cursor, VS Code, Xcode, etc.).
enum FieldKind: String, Codable, Equatable, Sendable, CaseIterable {
    case search
    case secure
    case text
}

/// Snapshot of the currently focused UI element's identity. Carries raw AX
/// role/subrole strings so future heuristics can adjust `kind` without
/// breaking the inspector contract.
struct FocusedField: Equatable, Sendable {
    let role: String?
    let subrole: String?

    var kind: FieldKind {
        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }
        if subrole == (kAXSearchFieldSubrole as String) { return .search }
        return .text
    }
}

extension FocusedField {

    /// Roles that can never take typed text. Everything else, including nil
    /// and unfamiliar roles, counts as editable so an AX-opaque editor is
    /// never refused.
    static let nonEditableRoles: Set<String> = [
        "AXApplication", "AXButton", "AXCheckBox", "AXDisclosureTriangle",
        "AXImage", "AXIncrementor", "AXLink", "AXMenu", "AXMenuBar",
        "AXMenuButton", "AXMenuItem", "AXPopUpButton",
        "AXProgressIndicator", "AXRadioButton", "AXScrollArea",
        "AXSlider", "AXSplitGroup", "AXStaticText", "AXTabGroup",
        "AXToolbar", "AXWindow",
    ]

    var isEditable: Bool {
        guard let role else { return true }
        return !Self.nonEditableRoles.contains(role)
    }
}
