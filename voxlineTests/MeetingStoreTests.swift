import Foundation
import Testing
@testable import voxline

@Suite struct MeetingStoreTests {

    private func makeStore() -> MeetingStore {
        MeetingStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    @Test func create_writes_recording_meta() throws {
        let store = makeStore()
        let meta = try store.create(startedAt: Date(timeIntervalSince1970: 100), systemTapStarted: true)
        let loaded = try store.load(meta.id)
        #expect(loaded.state == .recording)
        #expect(loaded.systemTapStarted)
        #expect(loaded.startedAt == Date(timeIntervalSince1970: 100))
    }

    @Test func directory_layout() {
        let store = makeStore()
        let id = UUID()
        let dir = store.directory(for: id)
        #expect(dir.url.lastPathComponent == id.uuidString)
        #expect(dir.meta.lastPathComponent == "meta.json")
        #expect(dir.micPCM.lastPathComponent == "mic.pcm")
        #expect(dir.systemPCM.lastPathComponent == "system.pcm")
        #expect(dir.transcript.lastPathComponent == "transcript.json")
        #expect(dir.micM4A.lastPathComponent == "mic.m4a")
        #expect(dir.systemM4A.lastPathComponent == "system.m4a")
    }

    @Test func unfinished_lists_recording_recorded_and_processing() throws {
        let store = makeStore()
        var states: [MeetingState: UUID] = [:]
        for state in [MeetingState.recording, .recorded, .processing, .done, .failed] {
            var meta = try store.create(startedAt: .now, systemTapStarted: false)
            meta.state = state
            try store.save(meta)
            states[state] = meta.id
        }
        let ids = Set(store.unfinished().map(\.id))
        #expect(ids == [states[.recording]!, states[.recorded]!, states[.processing]!])
    }

    @Test func regenerable_needs_transcript_and_is_newest_first() throws {
        let store = makeStore()
        let old = try store.create(startedAt: Date(timeIntervalSince1970: 1), systemTapStarted: false)
        let new = try store.create(startedAt: Date(timeIntervalSince1970: 2), systemTapStarted: false)
        _ = try store.create(startedAt: Date(timeIntervalSince1970: 3), systemTapStarted: false)
        for id in [old.id, new.id] {
            try Data("[]".utf8).write(to: store.directory(for: id).transcript)
        }
        #expect(store.regenerable().map(\.id) == [new.id, old.id])
        #expect(store.regenerable(limit: 1).map(\.id) == [new.id])
    }

    @Test func retention_deletes_finished_meetings_past_their_lifetime_only() throws {
        let store = makeStore()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        var oldDone = try store.create(startedAt: now.addingTimeInterval(-15 * 86_400), systemTapStarted: false)
        oldDone.state = .done
        try store.save(oldDone)
        var oldRecording = try store.create(startedAt: now.addingTimeInterval(-15 * 86_400), systemTapStarted: false)
        oldRecording.state = .recorded
        try store.save(oldRecording)
        var recentDone = try store.create(startedAt: now.addingTimeInterval(-2 * 86_400), systemTapStarted: false)
        recentDone.state = .done
        try store.save(recentDone)

        let deleted = store.applyRetention(.days14, now: now)

        #expect(deleted == [oldDone.id])
        #expect(Set(store.all().map(\.id)) == [oldRecording.id, recentDone.id])
    }

    @Test func forever_never_deletes() throws {
        let store = makeStore()
        var meta = try store.create(startedAt: .distantPast, systemTapStarted: false)
        meta.state = .done
        try store.save(meta)
        #expect(store.applyRetention(.forever, now: .now).isEmpty)
    }

    @Test func delete_audio_keeps_meta_and_transcript() throws {
        let store = makeStore()
        let meta = try store.create(startedAt: .now, systemTapStarted: false)
        let dir = store.directory(for: meta.id)
        for url in [dir.micPCM, dir.systemPCM, dir.micM4A, dir.systemM4A, dir.transcript] {
            try Data([1]).write(to: url)
        }
        store.deleteAudio(meta.id)
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.micPCM.path))
        #expect(!fm.fileExists(atPath: dir.systemM4A.path))
        #expect(fm.fileExists(atPath: dir.transcript.path))
        #expect(fm.fileExists(atPath: dir.meta.path))
    }

    @Test func retention_lifetimes() {
        #expect(MeetingAudioRetention.default == .days14)
        #expect(MeetingAudioRetention.dontKeep.keepsAudio == false)
        #expect(MeetingAudioRetention.dontKeep.directoryLifetime == 14 * 86_400.0)
        #expect(MeetingAudioRetention.days7.directoryLifetime == 7 * 86_400.0)
        #expect(MeetingAudioRetention.days30.keepsAudio)
        #expect(MeetingAudioRetention.forever.directoryLifetime == nil)
    }
}
