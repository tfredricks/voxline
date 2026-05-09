import Foundation

/// Per-app prompt configuration. The active mode is selected by bundle ID;
/// `*` is the wildcard fallback when no specific match exists.
struct Mode: Codable, Equatable {
    static let wildcardBundleID = "*"

    let bundleID: String
    let displayName: String
    let prompt: String
    /// Optional per-mode override of the LLM model id. When nil, AppSettings.llmModel is used.
    let model: String?
    /// Optional per-mode override of the sampling temperature.
    let temperature: Double?
}
