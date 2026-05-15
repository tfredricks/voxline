import Foundation
import Observation

/// One entry in the dictation history. Stores cleaned text only — no raw
/// transcript, no target app, no model. Smaller storage footprint and less
/// to worry about for privacy. Future feature #15 controls can wrap recording
/// with a no-op without touching this type.
struct DictationHistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let cleanedText: String
    /// Display name of the resolved Mode's category (e.g. "Chat", "Email").
    /// Nil only for rows persisted before category capture existed.
    let modeCategoryName: String?
    /// Localized name of the frontmost app, from `CapturedContext.appName`.
    /// Nil when AX denied capture or no app was frontmost.
    let appName: String?
    /// Bundle ID of the frontmost app, from `CapturedContext.bundleID`.
    let appBundleID: String?
}

/// In-memory list (max 25, newest first) of recent cleaned dictations,
/// JSON-encoded into UserDefaults. Same persistence pattern as `HotkeyChord`.
@Observable
@MainActor
final class DictationHistoryStore {

    static let key = "voxline.history.dictations"
    private static let maxItems = 25

    private(set) var items: [DictationHistoryItem] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = Self.load(defaults: defaults)
    }

    /// Prepend a new entry for a successful dictation. Pulls the resolved mode
    /// and frontmost-app fields so the history window can show context per row.
    /// Whitespace-only text is ignored. Caps at 25 by dropping the oldest entries.
    func record(cleanedText: String, mode: Mode, context: CapturedContext) {
        // Trim is a record-or-skip filter only; the stored text is the raw
        // cleanedText so history matches what was pasted into the focused app.
        guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let item = DictationHistoryItem(
            id: UUID(),
            timestamp: Date(),
            cleanedText: cleanedText,
            modeCategoryName: mode.category.displayName,
            appName: context.appName,
            appBundleID: context.bundleID
        )
        var next = [item] + items
        if next.count > Self.maxItems {
            next = Array(next.prefix(Self.maxItems))
        }
        items = next
        persist()
    }

    /// Wipe the list and persist the empty state.
    func clear() {
        items = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(defaults: UserDefaults) -> [DictationHistoryItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DictationHistoryItem].self, from: data)) ?? []
    }
}
