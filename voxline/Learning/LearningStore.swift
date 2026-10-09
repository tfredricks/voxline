import Foundation
import Observation

struct FinalText: Equatable, Sendable {
    var text: String
    var bundleID: String?
    var date: Date
}

struct StylePair: Equatable, Sendable {
    var before: String
    var after: String
    var date: Date
}

struct CategoryLearning: Equatable, Sendable {
    /// nil until the first refresh or edit.
    var note: String?
    var noteEditedByUser = false
    var noteUpdatedAt: Date?
    /// Newest last.
    var recentTexts: [FinalText] = []
    /// Newest last.
    var stylePairs: [StylePair] = []
    var sinceRefresh = 0
}

struct LearningData: Equatable, Sendable {
    var version = 1
    var categories: [ModeCategory: CategoryLearning] = [:]
    /// Newest last.
    var rejectedWords: [String] = []
}

extension FinalText: Codable {
    private enum CodingKeys: String, CodingKey { case text, bundleID, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
    }
}

extension StylePair: Codable {
    private enum CodingKeys: String, CodingKey { case before, after, date }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        before = try c.decodeIfPresent(String.self, forKey: .before) ?? ""
        after = try c.decodeIfPresent(String.self, forKey: .after) ?? ""
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
    }
}

extension CategoryLearning: Codable {
    private enum CodingKeys: String, CodingKey {
        case note, noteEditedByUser, noteUpdatedAt, recentTexts, stylePairs, sinceRefresh
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        noteEditedByUser = try c.decodeIfPresent(Bool.self, forKey: .noteEditedByUser) ?? false
        noteUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .noteUpdatedAt)
        recentTexts = try c.decodeIfPresent([FinalText].self, forKey: .recentTexts) ?? []
        stylePairs = try c.decodeIfPresent([StylePair].self, forKey: .stylePairs) ?? []
        sinceRefresh = try c.decodeIfPresent(Int.self, forKey: .sinceRefresh) ?? 0
    }
}

extension LearningData: Codable {
    private enum CodingKeys: String, CodingKey { case version, categories, rejectedWords }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        let raw = try c.decodeIfPresent([String: CategoryLearning].self, forKey: .categories) ?? [:]
        categories = Dictionary(uniqueKeysWithValues: raw.compactMap { key, value in
            ModeCategory(rawValue: key).map { ($0, value) }
        })
        rejectedWords = try c.decodeIfPresent([String].self, forKey: .rejectedWords) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(Dictionary(uniqueKeysWithValues: categories.map { ($0.key.rawValue, $0.value) }), forKey: .categories)
        try c.encode(rejectedWords, forKey: .rejectedWords)
    }
}

/// Learning's style data and rejected words, in `learning.json`. Caps are
/// applied on write. A file that fails to decode is moved aside to
/// `learning.corrupt.json` and learning starts empty.
@Observable
@MainActor
final class LearningStore {

    nonisolated static let maxTexts = 20
    nonisolated static let maxPairs = 10
    nonisolated static let textCap = 600
    nonisolated static let pairSideCap = 500
    nonisolated static let noteCap = 600
    nonisolated static let maxRejected = 200
    nonisolated static let refreshEvery = 20
    nonisolated static let exampleMinimumLength = 20

    private(set) var data: LearningData

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date

    /// `fileURL` nil keeps everything in memory.
    init(fileURL: URL?, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        self.data = fileURL.map(Self.load) ?? LearningData()
    }

    static func standard() -> LearningStore {
        do {
            return LearningStore(fileURL: try AppPaths.learningFile())
        } catch {
            AppLog.learning.error("learning store unavailable, keeping it in memory: \(error.localizedDescription, privacy: .public)")
            return LearningStore(fileURL: nil)
        }
    }

    func category(_ category: ModeCategory) -> CategoryLearning {
        data.categories[category] ?? CategoryLearning()
    }

    /// Appends `text`, cut to `textCap`, and counts it toward a refresh.
    /// Returns true once `refreshEvery` texts have been recorded since the
    /// last refresh. Blank text records nothing.
    @discardableResult
    func recordFinalText(_ text: String, bundleID: String?, category: ModeCategory) -> Bool {
        guard !text.isBlank else { return false }
        var due = false
        update(category) { entry in
            entry.recentTexts.append(FinalText(text: Self.capped(text, Self.textCap), bundleID: bundleID, date: now()))
            if entry.recentTexts.count > Self.maxTexts {
                entry.recentTexts.removeFirst(entry.recentTexts.count - Self.maxTexts)
            }
            entry.sinceRefresh += 1
            due = entry.sinceRefresh >= Self.refreshEvery
        }
        return due
    }

    /// Dropped when either side is over `pairSideCap` units: cutting each
    /// side separately would misalign them.
    func recordStylePair(before: String, after: String, category: ModeCategory) {
        guard before.utf16.count <= Self.pairSideCap, after.utf16.count <= Self.pairSideCap else { return }
        update(category) { entry in
            entry.stylePairs.append(StylePair(before: before, after: after, date: now()))
            if entry.stylePairs.count > Self.maxPairs {
                entry.stylePairs.removeFirst(entry.stylePairs.count - Self.maxPairs)
            }
        }
    }

    /// Stores `note` cut to `noteCap`. A refresh result (`editedByUser`
    /// false) also restarts the count; a user edit only marks the note as theirs.
    func setNote(_ note: String, category: ModeCategory, editedByUser: Bool) {
        update(category) { entry in
            entry.note = Self.capped(note, Self.noteCap)
            entry.noteEditedByUser = editedByUser
            entry.noteUpdatedAt = now()
            if !editedByUser { entry.sinceRefresh = 0 }
        }
    }

    func restartRefreshCount(_ category: ModeCategory) {
        update(category) { $0.sinceRefresh = 0 }
    }

    func isRejected(_ word: String) -> Bool {
        data.rejectedWords.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
    }

    func reject(_ words: [String]) {
        guard !words.isEmpty else { return }
        data.rejectedWords.removeAll { existing in
            words.contains { existing.caseInsensitiveCompare($0) == .orderedSame }
        }
        data.rejectedWords.append(contentsOf: words)
        if data.rejectedWords.count > Self.maxRejected {
            data.rejectedWords.removeFirst(data.rejectedWords.count - Self.maxRejected)
        }
        save()
    }

    func unreject(_ word: String) {
        guard isRejected(word) else { return }
        data.rejectedWords.removeAll { $0.caseInsensitiveCompare(word) == .orderedSame }
        save()
    }

    /// Up to `limit` final texts from `bundleID` in any category, newest
    /// first, skipping any under `exampleMinimumLength` characters.
    func examples(bundleID: String, limit: Int = 2) -> [String] {
        data.categories.values
            .flatMap(\.recentTexts)
            .filter { $0.bundleID == bundleID && $0.text.count >= Self.exampleMinimumLength }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(\.text)
    }

    func reset() {
        data = LearningData()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// The first `limit` UTF-16 units of `text`, never splitting a composed character.
    nonisolated static func capped(_ text: String, _ limit: Int) -> String {
        let ns = text as NSString
        guard ns.length > limit else { return text }
        return ns.substring(to: ns.composedBoundary(atOrBefore: limit))
    }

    private func update(_ category: ModeCategory, _ body: (inout CategoryLearning) -> Void) {
        var entry = data.categories[category] ?? CategoryLearning()
        body(&entry)
        data.categories[category] = entry
        save()
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(data).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.learning.error("learning.json not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(_ url: URL) -> LearningData {
        guard let bytes = try? Data(contentsOf: url) else { return LearningData() }
        do {
            return try JSONDecoder().decode(LearningData.self, from: bytes)
        } catch {
            let aside = url.deletingLastPathComponent().appending(path: "learning.corrupt.json")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            AppLog.learning.error("learning.json unreadable; moved aside and starting empty")
            return LearningData()
        }
    }
}
