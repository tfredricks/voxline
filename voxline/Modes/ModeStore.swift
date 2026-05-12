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
    /// ModeRouter's bundle-exact matches are preferred. Existing users have
    /// their persisted modes file reconciled on load — `reconcileShippedPrompts`
    /// overwrites prompts for any shipped bundle ID, so the active prompt is
    /// always whatever ships here.
    ///
    /// Mode prompts are appended to `LLMService.transcriptionPreamble` as the
    /// system prompt. The preamble carries the shared cleaning rules (fillers,
    /// disfluencies, self-corrections, word-choice preservation) so each mode
    /// prompt is a focused style delta — punctuation density, paragraph
    /// behavior, and what the model must not invent.
    ///
    /// - `chatPrompt`    — Slack, Discord, Messages, Teams, etc.
    /// - `emailPrompt`   — Mail, Outlook, Spark.
    /// - `writingPrompt` — Word, Pages, Notion, Obsidian, Notes.
    /// - `codePrompt`    — Terminal, iTerm, VS Code, Cursor, Xcode.
    /// - `defaultPrompt` — wildcard fallback, plus Excel/PowerPoint/Keynote/
    ///   Numbers where the content isn't really prose.
    static let defaultPrompt = """
    Default style. Apply natural punctuation and capitalization. Keep \
    contractions and the speaker's register; don't formalize casual \
    phrasing. Do not add structure (lists, headings, bullets) the speaker \
    didn't dictate.
    """

    static let chatPrompt = """
    Chat message. Conversational register; keep contractions and casual \
    phrasing. Use light punctuation: a one-line message needs no trailing \
    period; multi-sentence messages get full stops. Never invent a \
    greeting, sign-off, or "Hi <name>" the speaker didn't dictate.
    """

    static let emailPrompt = """
    Email body. Full sentences with proper capitalization and paragraph \
    breaks at topic shifts. Never invent a greeting, sign-off, or "Dear \
    <name>" the speaker didn't dictate. Preserve the speaker's register; \
    don't formalize casual phrasing.
    """

    static let writingPrompt = """
    Document prose. Full sentences with proper capitalization and \
    paragraph structure. Break paragraphs where the speaker pauses or \
    shifts topic. Treat output as long-form prose, not a chat snippet.
    """

    static let codePrompt = """
    Code, terminal command, or technical identifier. Do not add or change \
    punctuation or capitalization the speaker didn't dictate. Do not \
    rephrase. Pass through symbols, numbers, and identifiers verbatim.
    """

    static let shippedDefaults: [Mode] = [
        // Chat
        Mode(bundleID: "com.tinyspeck.slackmacgap",         displayName: "Slack",       prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "Cisco-Systems.Spark",               displayName: "Webex",       prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "us.zoom.xos",                       displayName: "Zoom",        prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.teams2",              displayName: "Teams",       prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.teams",               displayName: "Teams (Classic)", prompt: chatPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.MobileSMS",               displayName: "Messages",    prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.hnc.Discord",                   displayName: "Discord",     prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "ru.keepcoder.Telegram",             displayName: "Telegram",    prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "net.whatsapp.WhatsApp",             displayName: "WhatsApp",    prompt: chatPrompt,    model: nil, temperature: nil),
        Mode(bundleID: "org.whispersystems.signal-desktop", displayName: "Signal",      prompt: chatPrompt,    model: nil, temperature: nil),
        // Email
        Mode(bundleID: "com.apple.mail",                    displayName: "Mail",        prompt: emailPrompt,   model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Outlook",             displayName: "Outlook",     prompt: emailPrompt,   model: nil, temperature: nil),
        Mode(bundleID: "com.readdle.smartemail-Mac",        displayName: "Spark",       prompt: emailPrompt,   model: nil, temperature: nil),
        // Long-form writing
        Mode(bundleID: "com.microsoft.Word",                displayName: "Word",        prompt: writingPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.iWork.Pages",             displayName: "Pages",       prompt: writingPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.Notes",                   displayName: "Notes",       prompt: writingPrompt, model: nil, temperature: nil),
        Mode(bundleID: "notion.id",                         displayName: "Notion",      prompt: writingPrompt, model: nil, temperature: nil),
        Mode(bundleID: "md.obsidian",                       displayName: "Obsidian",    prompt: writingPrompt, model: nil, temperature: nil),
        // Office, non-prose
        Mode(bundleID: "com.microsoft.Excel",               displayName: "Excel",       prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.Powerpoint",          displayName: "PowerPoint",  prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.iWork.Keynote",           displayName: "Keynote",     prompt: defaultPrompt, model: nil, temperature: nil),
        Mode(bundleID: "com.apple.iWork.Numbers",           displayName: "Numbers",     prompt: defaultPrompt, model: nil, temperature: nil),
        // Code / terminal
        Mode(bundleID: "com.apple.Terminal",                displayName: "Terminal",    prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.googlecode.iterm2",             displayName: "iTerm",       prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.microsoft.VSCode",              displayName: "VS Code",     prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.todesktop.230313mzl4w4u92",     displayName: "Cursor",      prompt: codePrompt,    model: nil, temperature: nil),
        Mode(bundleID: "com.apple.dt.Xcode",                displayName: "Xcode",       prompt: codePrompt,    model: nil, temperature: nil),
        // Wildcard fallback (must stay last)
        Mode(bundleID: Mode.wildcardBundleID,               displayName: "Default",     prompt: defaultPrompt, model: nil, temperature: nil),
    ]
}
