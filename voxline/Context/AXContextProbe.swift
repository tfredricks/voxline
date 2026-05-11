import Foundation

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
