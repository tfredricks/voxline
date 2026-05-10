import Foundation

/// JSON-backed persistence for the user's modes list. Reads/writes the file
/// at `fileURL`. On a missing file, `load()` returns `shippedDefaults` and
/// writes them so the user can edit a real seed.
final class ModeStore {

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Convenience initializer pointing at the canonical Application Support
    /// path returned by `AppPaths.modesFile()`.
    convenience init() throws {
        try self.init(fileURL: AppPaths.modesFile())
    }

    func load() throws -> [Mode] {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Mode].self, from: data)
        }
        try save(Self.shippedDefaults)
        return Self.shippedDefaults
    }

    func save(_ modes: [Mode]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(modes)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Shipped defaults. The wildcard `*` mode must remain last so that
    /// ModeRouter's bundle-exact matches are preferred. Existing users keep
    /// their persisted modes file — new entries here only reach a clean
    /// install.
    static let shippedDefaults: [Mode] = [
        Mode(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            prompt: "Concise, casual. Strip fillers. No greeting unless dictated.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "Cisco-Systems.Spark",
            displayName: "Webex",
            prompt: "Concise, casual chat. Strip fillers. No greeting unless dictated.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.apple.mail",
            displayName: "Mail",
            prompt: "Format as a professional email body. Punctuate. Preserve meaning.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.microsoft.Outlook",
            displayName: "Outlook",
            prompt: "Format as a professional email body. Punctuate. Preserve meaning.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.microsoft.Word",
            displayName: "Word",
            prompt: "Format as polished prose. Punctuate. Capitalize sentences. Preserve meaning.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.microsoft.Excel",
            displayName: "Excel",
            prompt: "Return concise cell content. Strip fillers. No trailing punctuation unless dictated.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.microsoft.Powerpoint",
            displayName: "PowerPoint",
            prompt: "Format as concise slide text. Strip fillers. Keep it tight.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.apple.Terminal",
            displayName: "Terminal",
            prompt: "Return as-is. Treat as shell input: no auto-punctuation, no capitalization changes, minimal cleanup.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.microsoft.VSCode",
            displayName: "VS Code",
            prompt: "Return as-is, treat as code-adjacent text. Minimal cleanup.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: "com.todesktop.230313mzl4w4u92",
            displayName: "Cursor",
            prompt: "Return as-is, treat as code-adjacent text. Minimal cleanup.",
            model: nil,
            temperature: nil
        ),
        Mode(
            bundleID: Mode.wildcardBundleID,
            displayName: "Default",
            prompt: "Strip fillers. Punctuate. Preserve the speaker's voice.",
            model: nil,
            temperature: nil
        )
    ]
}
