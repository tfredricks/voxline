import Foundation

/// A stored instruction bound to a global key combo. The defaults carry fixed
/// ids so "Restore default presets" and the interceptor's combo-to-id map stay
/// stable across restores.
struct PresetShortcut: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var combo: KeyCombo
    var name: String
    var instruction: String

    static let defaults: [PresetShortcut] = [
        PresetShortcut(
            id: UUID(uuidString: "6A1D5C0E-0001-4F6B-9B0A-5A1E0C0DE001")!,
            combo: KeyCombo(keyCode: 18, modifiers: .option),
            name: "Fix grammar",
            instruction: "Fix grammar, spelling, and punctuation. Change nothing else."
        ),
        PresetShortcut(
            id: UUID(uuidString: "6A1D5C0E-0002-4F6B-9B0A-5A1E0C0DE002")!,
            combo: KeyCombo(keyCode: 19, modifiers: .option),
            name: "Make concise",
            instruction: "Make this more concise. Keep every fact and the original tone."
        ),
        PresetShortcut(
            id: UUID(uuidString: "6A1D5C0E-0003-4F6B-9B0A-5A1E0C0DE003")!,
            combo: KeyCombo(keyCode: 20, modifiers: .option),
            name: "Make professional",
            instruction: "Rewrite this in a clear, professional tone. Keep the meaning and every fact."
        ),
    ]
}
