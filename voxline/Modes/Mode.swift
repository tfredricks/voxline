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
    /// Coarse category for History display. JSON saved before the field
    /// existed decodes as `.general`; `ModeStore` then takes the shipped
    /// category for shipped apps.
    var category: ModeCategory = .general
}

extension Mode {
    /// Synthesized decoding ignores default values, so fields added after
    /// a modes.json was saved must be optional here.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        prompt = try container.decode(String.self, forKey: .prompt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        fieldKind = try container.decodeIfPresent(FieldKind.self, forKey: .fieldKind)
        category = try container.decodeIfPresent(ModeCategory.self, forKey: .category) ?? .general
    }
}
