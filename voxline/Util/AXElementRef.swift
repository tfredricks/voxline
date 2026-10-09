// voxline/Util/AXElementRef.swift
import ApplicationServices

/// CFEqual/CFHash identity of an AXUIElement, so "same focused element"
/// survives being handed between reads.
struct AXElementRef: Hashable, @unchecked Sendable {
    let element: AXUIElement
    static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}
