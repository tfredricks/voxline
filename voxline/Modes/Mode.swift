// voxline/Modes/Mode.swift
import Foundation

struct Mode: Codable, Equatable, Identifiable {
    static let wildcardBundleID = "*"

    /// Stable ID for SwiftUI ForEach. Bundle ID is stable enough as long as
    /// the user doesn't have two modes with the same bundle ID — the editor
    /// enforces uniqueness on save.
    var id: String { bundleID }

    var bundleID: String
    var displayName: String
    var prompt: String
    var model: String?
    var temperature: Double?
    /// nil = matches any focused field for this bundleID. A specific value
    /// makes this mode win only when the AX inspector reports the same kind.
    var fieldKind: FieldKind? = nil

    /// Convenience initializer for "Add new mode" with sensible defaults.
    static func newDraft(bundleID: String = "", displayName: String = "") -> Mode {
        Mode(
            bundleID: bundleID,
            displayName: displayName,
            prompt: "Strip fillers. Punctuate. Preserve the speaker's voice.",
            model: nil,
            temperature: nil,
            fieldKind: nil
        )
    }
}
