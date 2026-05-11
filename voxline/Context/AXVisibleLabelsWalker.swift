import Foundation

/// Walks the focused window's AX subtree and returns visible label-like
/// strings (titles, descriptions, statics) — capped in count, depth, and
/// per-entry length by the implementation. Honors the deadline and returns
/// whatever was collected when the budget runs out.
protocol AXVisibleLabelsWalking: Sendable {
    func walk(deadline: CaptureDeadline) -> [String]
}
