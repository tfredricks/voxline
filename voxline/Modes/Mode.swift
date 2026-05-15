// voxline/Modes/Mode.swift
import Foundation

/// Coarse category each Mode belongs to. Surfaced in the History "Mode" column
/// so users see "Chat / Email / Writing / Code / General" rather than the
/// per-app display name (which duplicates the App column).
enum ModeCategory: String, Codable, CaseIterable {
    case chat
    case email
    case writing
    case code
    case general

    var displayName: String {
        switch self {
        case .chat:    return "Chat"
        case .email:   return "Email"
        case .writing: return "Writing"
        case .code:    return "Code"
        case .general: return "General"
        }
    }
}

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
    /// Coarse category for History display. Defaults to `.general` so older
    /// on-disk JSON missing the field decodes cleanly.
    var category: ModeCategory = .general
}
