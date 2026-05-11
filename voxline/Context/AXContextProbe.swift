import Foundation
import ApplicationServices

/// Carries the value-bearing AX outputs that depend on the focused element:
/// window title, the slice of the value before the cursor, the slice after,
/// and any current selection. The implementation may return any subset as
/// nil — the caller treats nil as "couldn't determine".
struct AXContextProbeResult: Equatable, Sendable {
    var windowTitle: String?
    var textBeforeCursor: String?
    var textAfterCursor: String?
    var selectedText: String?
}

/// Probes the system-wide focused element for value-bearing signals. Each
/// implementation should honor the passed deadline; if the deadline has
/// already expired, return all-nil immediately.
protocol AXContextProbing: Sendable {
    func probe(deadline: CaptureDeadline) -> AXContextProbeResult
}

/// Real AX-backed implementation. All AX calls are synchronous cross-process
/// IPC; each one is guarded with the deadline check so a slow target app
/// can't burn the whole budget on one attribute.
///
/// Caps:
/// - Window title: 200 chars (long titles get truncated with ellipsis).
/// - Selected text: 500 chars (longer selections are truncated; the LLM
///   doesn't need the whole thing to understand context).
/// - Text before cursor: 200 chars (slice ending at the cursor).
/// - Text after cursor: 100 chars (slice starting at the cursor).
struct DefaultAXContextProbe: AXContextProbing {

    static let windowTitleMax = 200
    static let selectedTextMax = 500
    static let beforeCursorMax = 200
    static let afterCursorMax = 100

    func probe(deadline: CaptureDeadline) -> AXContextProbeResult {
        var result = AXContextProbeResult()
        if deadline.isExpired { return result }
        guard AXIsProcessTrusted() else { return result }

        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusStatus = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard focusStatus == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return result
        }
        let focused = focusedValue as! AXUIElement

        if deadline.isExpired { return result }
        result.windowTitle = readWindowTitle(focused: focused)

        if deadline.isExpired { return result }
        result.selectedText = clip(readString(focused, kAXSelectedTextAttribute), Self.selectedTextMax)

        if deadline.isExpired { return result }
        let (before, after) = readBeforeAfter(focused: focused)
        result.textBeforeCursor = before
        result.textAfterCursor = after

        return result
    }

    private func readWindowTitle(focused: AXUIElement) -> String? {
        var windowValue: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowValue)
        guard s == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let win = windowValue as! AXUIElement
        return clip(readString(win, kAXTitleAttribute), Self.windowTitleMax)
    }

    private func readBeforeAfter(focused: AXUIElement) -> (String?, String?) {
        // The selected-text range gives us the caret/anchor location; the
        // value attribute gives us the field's full content. Combine to
        // derive the slices around the cursor.
        var rangeValue: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        )
        guard rangeStatus == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return (nil, nil) }
        let axValue = rangeValue as! AXValue

        // The AXValue type tag is independent of the AXValue CFTypeID — verify
        // it carries a CFRange before extracting one. Matches the defensive
        // pattern in ClipboardInjector's selection-range reader.
        guard AXValueGetType(axValue) == .cfRange else { return (nil, nil) }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return (nil, nil) }

        guard let full = readString(focused, kAXValueAttribute) else { return (nil, nil) }
        let nsFull = full as NSString
        let location = max(0, min(range.location, nsFull.length))

        let beforeStart = max(0, location - Self.beforeCursorMax)
        let beforeRange = NSRange(location: beforeStart, length: location - beforeStart)
        let beforeSlice = beforeRange.length > 0 ? nsFull.substring(with: beforeRange) : ""

        let afterStart = location
        let afterAvail = max(0, nsFull.length - afterStart)
        let afterLen = min(Self.afterCursorMax, afterAvail)
        let afterRange = NSRange(location: afterStart, length: afterLen)
        let afterSlice = afterRange.length > 0 ? nsFull.substring(with: afterRange) : ""

        return (beforeSlice.isEmpty ? nil : beforeSlice,
                afterSlice.isEmpty ? nil : afterSlice)
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard s == .success else { return nil }
        return value as? String
    }

    private func clip(_ s: String?, _ maxLen: Int) -> String? {
        guard let s, !s.isEmpty else { return nil }
        if s.count <= maxLen { return s }
        return String(s.prefix(maxLen - 1)) + "…"
    }
}
