import ApplicationServices
import Foundation

/// Why a dictation couldn't be anchored, so its window learns nothing.
enum AnchorSkip: String, Sendable {
    case notTrusted, noElement, notResponding, secure, valueUnreadable, notAtCaret
    /// A new capture started before the anchor read finished.
    case superseded
}

enum AnchorRead: Sendable {
    case anchored(InsertAnchor)
    case skipped(AnchorSkip)

    var skipped: AnchorSkip? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

/// Every AX read Learning makes. Synchronous; callers run it off the main actor.
protocol CorrectionReading: Sendable {
    /// One attempt at anchoring `inserted` in the focused field.
    func anchor(for inserted: String) -> AnchorRead
    func focusedRef() -> AXRead<AXElementRef>
    func value(of element: any AXTextElement) -> AXRead<String>
}

struct LiveCorrectionReader: CorrectionReading {
    var isTrusted: @Sendable () -> Bool = { AXIsProcessTrusted() }
    var focused: @Sendable () -> AXRead<AXElementRef> = { LiveFocusedElementSource.readElement() }

    func anchor(for inserted: String) -> AnchorRead {
        guard isTrusted() else { return .skipped(.notTrusted) }
        switch focused() {
        case .value(let ref): return Self.anchor(in: LiveAXTextElement(element: ref.element), inserted: inserted)
        case .absent: return .skipped(.noElement)
        case .failed: return .skipped(.notResponding)
        }
    }

    /// The checks once the element is known. Fails closed on the secure
    /// check, as `EditContextReader` does.
    static func anchor(in element: any AXTextElement, inserted: String) -> AnchorRead {
        let subrole = element.string(kAXSubroleAttribute)
        if subrole.isFailed { return .skipped(.notResponding) }
        if subrole.value == (kAXSecureTextFieldSubrole as String) { return .skipped(.secure) }
        guard let value = element.string(kAXValueAttribute).value,
              let caret = element.range(kAXSelectedTextRangeAttribute).value else { return .skipped(.valueUnreadable) }
        guard let text = AnchorText.make(value: value, caret: caret, inserted: inserted) else { return .skipped(.notAtCaret) }
        return .anchored(InsertAnchor(element: element, text: text))
    }

    func focusedRef() -> AXRead<AXElementRef> {
        focused()
    }

    func value(of element: any AXTextElement) -> AXRead<String> {
        element.string(kAXValueAttribute)
    }
}
