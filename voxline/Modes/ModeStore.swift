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
    /// Five prompts, routed by app category:
    ///
    /// - `chatPrompt`  — Slack, Webex, Zoom, MS Teams. Short, conversational,
    ///   light punctuation, never invents greetings or sign-offs.
    /// - `emailPrompt` — Mail, Outlook. Full punctuation and paragraphs;
    ///   never invents a greeting or sign-off the speaker didn't dictate.
    /// - `writingPrompt` — Word, Pages. Long-form document prose with
    ///   paragraph structure.
    /// - `codePrompt`  — Terminal, VS Code, Cursor. Filler-only stripping;
    ///   no punctuation or capitalization changes.
    /// - `defaultPrompt` — wildcard fallback, plus Excel/PowerPoint where
    ///   the content isn't really prose.
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

    static let chatPrompt = """
    Rewrite the transcript as if the speaker had typed it into a chat \
    message. Apply these transformations:

    - Remove filler words: um, uh, like, you know, sort of, kind of.
    - Remove disfluencies: false starts, restarts, repeated words, \
    trailing-off pauses.
    - Resolve self-corrections to the speaker's final intent and DROP the \
    correction phrase entirely.
    - Keep it conversational. Contractions are fine. Do not add a \
    greeting, sign-off, or formal phrasing the speaker didn't dictate.
    - Use light punctuation. A single short message does not need a \
    trailing period; multi-sentence messages do.
    - Preserve the speaker's tone, voice, and word choices verbatim.

    Return only the revised text.
    """

    static let emailPrompt = """
    Rewrite the transcript as if the speaker had typed it into an email. \
    Apply these transformations:

    - Remove filler words: um, uh, like, you know, sort of, kind of.
    - Remove disfluencies: false starts, restarts, repeated words, \
    trailing-off pauses.
    - Resolve self-corrections to the speaker's final intent and DROP the \
    correction phrase entirely.
    - Apply full punctuation, capitalization, and paragraph breaks where \
    the speaker pauses or shifts topic.
    - Do not invent a greeting or sign-off. If the speaker dictated one, \
    keep it; otherwise omit.
    - Preserve the speaker's tone, voice, and word choices — do not \
    formalize casual phrasing for style.

    Return only the revised text.
    """

    static let writingPrompt = """
    Rewrite the transcript as if the speaker had typed it into a \
    document. Apply these transformations:

    - Remove filler words: um, uh, like, you know, sort of, kind of.
    - Remove disfluencies: false starts, restarts, repeated words, \
    trailing-off pauses.
    - Resolve self-corrections to the speaker's final intent and DROP the \
    correction phrase entirely.
    - Apply full punctuation, capitalization, and paragraph structure. \
    Treat the output as written prose, not a chat snippet.
    - Preserve the speaker's tone, voice, and word choices — do not \
    formalize or paraphrase for style.

    Return only the revised text.
    """

    static let codePrompt = "Strip filler words only. Do not add punctuation, change capitalization, or rephrase. Return only the revised text."

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
