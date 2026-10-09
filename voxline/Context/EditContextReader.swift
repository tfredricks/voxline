import ApplicationServices
import Foundation

struct EditContextPolicy: Sendable {
    /// Apps whose kAXValue is an editor's hidden input rather than the
    /// document: their selection is kept, their field is reported unavailable.
    /// Provisional; the manual pass confirms or empties it.
    var untrustedFieldBundleIDs: Set<String>
    var fieldBudget: Int = FieldWindow.budget
    var selectionMax: Int = 8_000

    static let `default` = EditContextPolicy(untrustedFieldBundleIDs: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"])
}

protocol EditContextReading: Sendable {
    func read() -> Result<EditContext, EditContextRefusal>
}

/// Reads the focused element, its field window, selection, and cursor through
/// the `AXTextElement` seam. Synchronous; callers run it off the main actor.
///
/// - Without Accessibility trust it refuses with `.accessibilityNotGranted`
///   before reading anything, so a command never reaches the LLM only to
///   fail at insert.
/// - The secure check fails closed: a secure subrole refuses with
///   `.secureField`, an unreadable subrole with `.notResponding`.
/// - The selection is resolved from kAXSelectedTextRange (R), kAXValue (V),
///   and kAXSelectedText (S). An empty S means "nothing selected" only when R
///   is readable; every inconclusive read sets `needsCopyFallback`.
/// - An R that is negative or overflows counts as absent, and an R that lies
///   outside a readable V is dropped from the selection, so no range handed
///   downstream is unchecked.
/// - `cursor` and `field` are set only when V is readable, R lies inside it,
///   and the app is not in `EditContextPolicy.untrustedFieldBundleIDs`.
struct EditContextReader: EditContextReading {
    private let source: @Sendable () -> AXRead<FocusedElementSnapshot>
    private let policy: EditContextPolicy
    private let isAXTrusted: @Sendable () -> Bool

    init(source: @escaping @Sendable () -> AXRead<FocusedElementSnapshot> = { LiveFocusedElementSource.read() },
         policy: EditContextPolicy = .default,
         isAXTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() }) {
        self.source = source
        self.policy = policy
        self.isAXTrusted = isAXTrusted
    }

    func read() -> Result<EditContext, EditContextRefusal> {
        guard isAXTrusted() else {
            AppLog.context.info("edit context: accessibility not granted")
            return .failure(.accessibilityNotGranted)
        }

        let snapshot: FocusedElementSnapshot
        switch source() {
        case .value(let focused):
            snapshot = focused
        case .absent:
            return .success(EditContext(
                isEditable: false, element: nil, field: nil, selection: nil, cursor: nil, needsCopyFallback: false
            ))
        case .failed:
            AppLog.context.info("edit context: focused element not responding")
            return .failure(.notResponding)
        }
        let element = snapshot.element

        let subroleRead = element.string(kAXSubroleAttribute)
        if subroleRead.isFailed {
            AppLog.context.info("edit context: subrole not responding")
            return .failure(.notResponding)
        }
        let subrole = subroleRead.value
        if subrole == (kAXSecureTextFieldSubrole as String) {
            AppLog.context.info("edit context: secure field")
            return .failure(.secureField)
        }
        let role = element.string(kAXRoleAttribute).value
        let isEditable = FocusedField(role: role, subrole: subrole).isEditable

        var context = EditContext(
            appName: snapshot.appName,
            bundleID: snapshot.bundleID,
            windowTitle: snapshot.windowTitle,
            role: role,
            subrole: subrole,
            isEditable: isEditable,
            element: element.ref,
            field: nil,
            selection: nil,
            cursor: nil,
            needsCopyFallback: false
        )

        let selectedRange = element.range(kAXSelectedTextRangeAttribute).value.flatMap {
            $0.fits(in: Int.max) ? $0 : nil
        }
        let value: AXRead<String> = isEditable ? element.string(kAXValueAttribute) : .absent

        var readableValue: NSString?
        if let range = selectedRange, let text = value.value, range.fits(in: (text as NSString).length) {
            let full = text as NSString
            readableValue = full
            context.selection = range.length > 0
                ? SelectionInfo(text: full.substring(with: range.nsRange), range: range)
                : nil
            context.cursor = range.location
        } else {
            (context.selection, context.needsCopyFallback) = Self.resolveWithoutField(
                selectedRange, keepsRange: value.value == nil, element
            )
        }

        if readableValue != nil, let bundleID = snapshot.bundleID, policy.untrustedFieldBundleIDs.contains(bundleID) {
            readableValue = nil
            context.cursor = nil
            AppLog.context.info("edit context: field untrusted for \(bundleID, privacy: .public)")
        }

        if let full = readableValue, let cursor = context.cursor {
            let anchor = context.selection?.range ?? UTF16Range(location: cursor, length: 0)
            let window = FieldWindow.make(text: full, anchor: anchor, budget: policy.fieldBudget)
            context.field = FieldWindowText(
                text: full.substring(with: window.nsRange), range: window, fullLength: full.length
            )
        }

        if let selection = context.selection, selection.text.utf16.count > policy.selectionMax {
            AppLog.context.info("edit context: selection too long (\(selection.text.utf16.count) units)")
            return .failure(.selectionTooLong)
        }
        return .success(context)
    }

    private static func resolveWithoutField(
        _ selectedRange: UTF16Range?,
        keepsRange: Bool,
        _ element: any AXTextElement
    ) -> (selection: SelectionInfo?, needsCopyFallback: Bool) {
        if let range = selectedRange, range.length == 0 { return (nil, false) }
        if let text = element.string(kAXSelectedTextAttribute).value, !text.isEmpty {
            return (SelectionInfo(text: text, range: keepsRange ? selectedRange : nil), false)
        }
        return (nil, true)
    }
}
