import Foundation

struct MeetingDirectory: Equatable, Sendable {
    let url: URL
    var meta: URL { url.appending(path: "meta.json") }
    var micPCM: URL { url.appending(path: "mic.pcm") }
    var systemPCM: URL { url.appending(path: "system.pcm") }
    var transcript: URL { url.appending(path: "transcript.json") }
    var micM4A: URL { url.appending(path: "mic.m4a") }
    var systemM4A: URL { url.appending(path: "system.m4a") }
    var audioFiles: [URL] { [micPCM, systemPCM, micM4A, systemM4A] }
}

/// Meeting directories under `root`. Unreadable directories are skipped by
/// every listing, never deleted by them.
struct MeetingStore: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    static func standard() throws -> MeetingStore {
        MeetingStore(root: try AppPaths.meetingsDirectory())
    }

    func directory(for id: UUID) -> MeetingDirectory {
        MeetingDirectory(url: root.appending(path: id.uuidString, directoryHint: .isDirectory))
    }

    func create(id: UUID = UUID(), startedAt: Date, systemTapStarted: Bool) throws -> MeetingMeta {
        try FileManager.default.createDirectory(at: directory(for: id).url, withIntermediateDirectories: true)
        let meta = MeetingMeta(
            id: id, state: .recording, startedAt: startedAt, durationSeconds: 0,
            systemTapStarted: systemTapStarted, title: nil, notesPath: nil, failureReason: nil
        )
        try save(meta)
        return meta
    }

    func save(_ meta: MeetingMeta) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: directory(for: meta.id).meta, options: .atomic)
    }

    func load(_ id: UUID) throws -> MeetingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeetingMeta.self, from: Data(contentsOf: directory(for: id).meta))
    }

    /// Newest first.
    func all() -> [MeetingMeta] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .compactMap { try? load($0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func unfinished() -> [MeetingMeta] {
        all().filter { $0.state.isUnfinished }
    }

    func regenerable(limit: Int = 10) -> [MeetingMeta] {
        Array(all().filter { FileManager.default.fileExists(atPath: directory(for: $0.id).transcript.path) }.prefix(limit))
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id).url)
    }

    func deleteAudio(_ id: UUID) {
        for url in directory(for: id).audioFiles {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes `done` and `failed` meetings older than the retention's
    /// directory lifetime. Unfinished meetings are never deleted here.
    @discardableResult
    func applyRetention(_ retention: MeetingAudioRetention, now: Date) -> [UUID] {
        guard let lifetime = retention.directoryLifetime else { return [] }
        let expired = all().filter { !$0.state.isUnfinished && now.timeIntervalSince($0.startedAt) > lifetime }
        for meta in expired { delete(meta.id) }
        if !expired.isEmpty { AppLog.meetings.info("retention removed \(expired.count) meeting(s)") }
        return expired.map(\.id)
    }
}
