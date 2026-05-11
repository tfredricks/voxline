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

    init(id: UUID = UUID(), timestamp: Date = Date(), cleanedText: String) {
        self.id = id
        self.timestamp = timestamp
        self.cleanedText = cleanedText
    }
}

/// In-memory list (max 10, newest first) of recent cleaned dictations,
/// JSON-encoded into UserDefaults. Same persistence pattern as `HotkeyChord`.
@Observable
@MainActor
final class DictationHistoryStore {

    static let key = "voxline.history.dictations"
    private static let maxItems = 10

    private(set) var items: [DictationHistoryItem] = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.items = Self.load(defaults: defaults)
    }

    /// Prepend a new entry. Whitespace-only text is ignored. Caps at 10 by
    /// dropping the oldest entries.
    func record(cleanedText: String) {
        // Trim is a record-or-skip filter only; the stored text is the raw
        // cleanedText so history matches what was pasted into the focused app.
        guard !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let item = DictationHistoryItem(cleanedText: cleanedText)
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
        do {
            let data = try JSONEncoder().encode(items)
            defaults.set(data, forKey: Self.key)
        } catch {
            // Encoding can't realistically fail for this shape, but if it
            // ever does we'd rather lose history-on-disk than crash.
        }
    }

    private static func load(defaults: UserDefaults) -> [DictationHistoryItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DictationHistoryItem].self, from: data)) ?? []
    }
}
