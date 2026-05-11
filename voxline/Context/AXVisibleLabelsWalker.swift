import ApplicationServices
import Foundation

/// Walks the focused window's AX subtree and returns visible label-like
/// strings (titles, descriptions, statics) — capped in count, depth, and
/// per-entry length by the implementation. Honors the deadline and returns
/// whatever was collected when the budget runs out.
protocol AXVisibleLabelsWalking: Sendable {
    func walk(deadline: CaptureDeadline) -> [String]
}

/// BFS over the focused window's AX subtree, collecting human-readable
/// label-like strings. Caps:
/// - Max collected labels: 20
/// - Max depth from the root window: 6
/// - Per-label char cap: 60
/// - Visits no more than 400 elements regardless of depth (guards against
///   pathological Electron trees).
///
/// Honors the deadline at every node — if `isExpired` flips true mid-walk,
/// returns what's been collected so far.
struct DefaultAXVisibleLabelsWalker: AXVisibleLabelsWalking {

    static let maxLabels = 20
    static let maxDepth = 6
    static let maxLabelChars = 60
    static let maxNodesVisited = 400

    /// Attributes scanned for label-like text. `kAXValueAttribute` is
    /// intentionally NOT included — for text fields it returns the user's live
    /// content, which is a privacy/semantic mismatch with "visible labels".
    /// `DefaultAXContextProbe` captures field values from the focused element
    /// only, on purpose.
    private let attributes: [String] = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
    ]

    func walk(deadline: CaptureDeadline) -> [String] {
        if deadline.isExpired { return [] }
        guard AXIsProcessTrusted() else { return [] }

        guard let root = focusedWindow() else { return [] }

        // Dedupe at the normalized-label level — repeated "Done" buttons across
        // a toolbar collapse to one entry on purpose; the LLM doesn't benefit
        // from seeing the same string twelve times.
        var seen = Set<String>()
        var collected: [String] = []
        var visited = 0

        // BFS queue of (element, depth). `Array.removeFirst()` is O(n); fine
        // at maxNodesVisited=400 (worst case ~80k element moves, sub-ms) but
        // revisit if the cap grows by an order of magnitude.
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        while !queue.isEmpty {
            if deadline.isExpired { break }
            if collected.count >= Self.maxLabels { break }
            if visited >= Self.maxNodesVisited { break }
            let (el, depth) = queue.removeFirst()
            visited += 1

            for attr in attributes {
                if let s = readString(el, attr), let label = normalize(s),
                   seen.insert(label).inserted {
                    collected.append(label)
                    if collected.count >= Self.maxLabels { break }
                }
            }

            if depth < Self.maxDepth, let children = readChildren(el) {
                for child in children {
                    queue.append((child, depth + 1))
                }
            }
        }
        return collected
    }

    private func focusedWindow() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &focusedValue
        )
        guard s == .success,
              let focusedValue,
              CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return nil }
        let focused = focusedValue as! AXUIElement

        var windowValue: CFTypeRef?
        let ws = AXUIElementCopyAttributeValue(focused, kAXWindowAttribute as CFString, &windowValue)
        guard ws == .success,
              let windowValue,
              CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        return (windowValue as! AXUIElement)
    }

    private func readChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard s == .success, let value else { return nil }
        return value as? [AXUIElement]
    }

    private func readString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard s == .success else { return nil }
        return value as? String
    }

    /// Reduce whitespace, drop strings that are pure punctuation/symbols or
    /// longer than the per-label char cap, return nil for empties.
    /// `internal` so tests can exercise it directly without an AX harness.
    func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        // Drop labels that are very long (likely a paragraph of body text,
        // not a "label"). Truncating would mislead the LLM.
        if trimmed.count > Self.maxLabelChars { return nil }
        // Require at least one alphanumeric character. Pure punctuation
        // ("…", "—") is not informative.
        if !trimmed.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
            return nil
        }
        return trimmed
    }
}
