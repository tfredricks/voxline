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

    /// Defaults from spec §5.2.
    static let shippedDefaults: [Mode] = [
        Mode(
            bundleID: "com.tinyspeck.slackmacgap",
            displayName: "Slack",
            prompt: "Concise, casual. Strip fillers. No greeting unless dictated.",
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
