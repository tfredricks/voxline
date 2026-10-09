// voxline/Hotkey/ModifierTracker.swift
import CoreGraphics
import Foundation

/// Resolves which of the eight modifier keys are held from a flagsChanged
/// event. Device bits name sides directly; when an event carries only the
/// generic family bit (Screen Sharing, synthetic input), the keycode names
/// the side that changed, and a family with no history defaults to its left key.
struct ModifierTracker: Equatable, Sendable {

    struct Family: Sendable {
        let generic: CGEventFlags
        let left: HotkeyChord.Modifier
        let right: HotkeyChord.Modifier
        let leftKeyCode: Int64
        let rightKeyCode: Int64
    }

    static let families: [Family] = [
        Family(generic: .maskShift,     left: .leftShift,   right: .rightShift,   leftKeyCode: 56, rightKeyCode: 60),
        Family(generic: .maskControl,   left: .leftControl, right: .rightControl, leftKeyCode: 59, rightKeyCode: 62),
        Family(generic: .maskAlternate, left: .leftOption,  right: .rightOption,  leftKeyCode: 58, rightKeyCode: 61),
        Family(generic: .maskCommand,   left: .leftCommand, right: .rightCommand, leftKeyCode: 55, rightKeyCode: 54),
    ]

    private(set) var held: Set<HotkeyChord.Modifier> = []

    @discardableResult
    mutating func update(flags: CGEventFlags, keyCode: Int64) -> Set<HotkeyChord.Modifier> {
        for family in Self.families {
            let previous = held.intersection([family.left, family.right])
            held.subtract(previous)
            guard flags.contains(family.generic) else { continue }
            let leftDevice = family.left.isHeld(in: flags)
            let rightDevice = family.right.isHeld(in: flags)
            var sides = previous
            if leftDevice || rightDevice {
                sides = []
                if leftDevice { sides.insert(family.left) }
                if rightDevice { sides.insert(family.right) }
            } else if keyCode == family.leftKeyCode {
                sides.formSymmetricDifference([family.left])
            } else if keyCode == family.rightKeyCode {
                sides.formSymmetricDifference([family.right])
            }
            if sides.isEmpty { sides = [family.left] }
            held.formUnion(sides)
        }
        return held
    }

    mutating func reset(to held: Set<HotkeyChord.Modifier>) { self.held = held }
}
