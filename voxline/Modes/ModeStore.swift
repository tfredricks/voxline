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
            let onDisk = try JSONDecoder().decode([Mode].self, from: data)
            // Always reconcile shipped prompts: for every mode whose bundle ID
            // matches a shipped default, overwrite the on-disk prompt with the
            // current shipped one. User-added modes (unknown bundle IDs) and
            // per-mode model/temperature overrides are passed through. There's
            // no UI to hand-edit prompts in voxline today, so we deliberately
            // don't try to preserve user prompt edits.
            let reconciled = Self.reconcileShippedPrompts(onDisk)
            if reconciled != onDisk {
                try? save(reconciled)
            }
            return reconciled
        }
        try save(Self.shippedDefaults)
        return Self.shippedDefaults
    }

    /// For each mode whose bundle ID has a shipped default, replace its prompt
    /// with the current shipped prompt. Everything else (displayName, model,
    /// temperature, plus modes with unknown bundle IDs) is untouched.
    /// Pure function — exported for testing.
    static func reconcileShippedPrompts(_ modes: [Mode]) -> [Mode] {
        let shippedPromptByID = Dictionary(uniqueKeysWithValues: shippedDefaults.map { ($0.bundleID, $0.prompt) })
        return modes.map { mode in
            guard let shipped = shippedPromptByID[mode.bundleID] else { return mode }
            var updated = mode
            updated.prompt = shipped
            return updated
        }
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
    ///
    /// We ship two prompts. Per-app distinctions like "casual chat" vs.
    /// "formal email" are already implicit in the speaker's own dictation
    /// (tone, salutation, etc.) and small models adapt well without explicit
    /// per-app hints. Terminal/code editors are the one case that genuinely
    /// inverts the default — they need filler-stripping without punctuation
    /// or capitalization changes — so they share a separate prompt.
    static let defaultPrompt = """
    Rewrite the transcript as if the speaker had typed it. Apply these \
    transformations:

    - Remove filler words: um, uh, like, you know, sort of, kind of.
    - Remove disfluencies: false starts, restarts, repeated words, \
    trailing-off pauses.
    - Resolve self-corrections to the speaker's final intent and DROP the \
    correction phrase entirely. Examples:
      "how precise, I mean fast" → "how fast"
      "red, no blue" → "blue"
      "Tuesday, wait, Wednesday" → "Wednesday"
      "scratch that, Wednesday" → "Wednesday"
      "I went to the- I went to the store" → "I went to the store"
    - Add natural punctuation and capitalization.
    - Preserve the speaker's tone, voice, and word choices — do not \
    formalize casual speech or paraphrase for style.

    Return only the revised text.
    """
    static let codePrompt = "Strip filler words only. Do not add punctuation, change capitalization, or rephrase. Return only the revised text."

    static let shippedDefaults: [Mode] = [
        Mode(bundleID: "com.tinyspeck.slackmacgap",     displayName: "Slack",      prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "Cisco-Systems.Spark",           displayName: "Webex",      prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.mail",                displayName: "Mail",       prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Outlook",         displayName: "Outlook",    prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Word",            displayName: "Word",       prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Excel",           displayName: "Excel",      prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Powerpoint",      displayName: "PowerPoint", prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.Terminal",            displayName: "Terminal",   prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.VSCode",          displayName: "VS Code",    prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor",     prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: Mode.wildcardBundleID,           displayName: "Default",    prompt: defaultPrompt, model: nil, temperature: nil),
    ]
}
