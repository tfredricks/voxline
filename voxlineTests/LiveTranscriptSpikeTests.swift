import Darwin
import Foundation
import Testing
@testable import voxline

/// Measurement gates from the live-transcript spec. Opt-in; results are
/// appended to the spec by hand.
@MainActor
@Suite(
    .tags(.integration),
    .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["VOXLINE_LIVE_SPIKE"] == "1",
        "Set TEST_RUNNER_VOXLINE_LIVE_SPIKE=1 to run the live transcript spike."
    )
)
struct LiveTranscriptSpikeTests {

    private static let sentences = [
        ("Samantha", "Let's review the quarterly numbers before the pricing call with Acme."),
        ("Daniel", "The onboarding funnel improved after we shipped the new checkout flow."),
        ("Samantha", "I think Priya should own the follow-up with the Argmax team."),
        ("Daniel", "We decided to postpone the migration until the second week of November."),
    ]
    private static let chunk = 1_600 // 100 ms at 16 kHz

    private static func clip() throws -> [Float] {
        try sentences.flatMap { voice, text in
            try SpeechClipFixture.synthesize(text + " [[slnc 800]]", voice: voice)
        }
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : .nan
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Gate 1: an hour of audio through one session at 4x real time. Finals
    /// must keep arriving in the last five minutes and memory must stay flat.
    @Test(.timeLimit(.minutes(30)))
    func hour_long_session_keeps_finalizing() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let clip = try Self.clip()
        let clipSeconds = Double(clip.count) / 16_000
        let repeats = Int((3_600 / clipSeconds).rounded(.up))

        let session = try await engine.openSession(SessionConfig())
        let stableLengthByMinute = LockedBox<[Int: Int]>([:])
        let fedSamples = LockedBox<Int>(0)
        let collector = Task {
            for await partial in session.partials {
                let minute = fedSamples.read() / (16_000 * 60)
                stableLengthByMinute.mutate { $0[minute] = partial.stable.count }
            }
        }

        let memoryAtStart = Self.residentMB()
        let wallStart = Date()
        for _ in 0..<repeats {
            var offset = 0
            while offset < clip.count {
                let end = min(offset + Self.chunk, clip.count)
                session.append(Array(clip[offset..<end]))
                fedSamples.mutate { $0 += end - offset }
                offset = end
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        let feedSeconds = Date().timeIntervalSince(wallStart)
        try await Task.sleep(for: .seconds(5))
        let memoryAtEnd = Self.residentMB()
        let cancelStart = Date()
        session.cancel()
        await collector.value
        let cancelMs = Date().timeIntervalSince(cancelStart) * 1_000

        let byMinute = stableLengthByMinute.read()
        let lastFiveMinutes = (55...60).compactMap { byMinute[$0] }
        let before = byMinute.filter { $0.key < 55 }.values.max() ?? 0
        print("[spike] fed \(feedSeconds.rounded()) s wall for 3600 s audio; memory \(memoryAtStart.rounded()) → \(memoryAtEnd.rounded()) MB; cancel \(cancelMs.rounded()) ms")
        print("[spike] stable length by minute: \(byMinute.sorted { $0.key < $1.key })")
        #expect((lastFiveMinutes.max() ?? 0) > before, "no new final text in the last five minutes")
        #expect(memoryAtEnd - memoryAtStart < 100, "resident memory grew \(memoryAtEnd - memoryAtStart) MB")
        #expect(cancelMs < 2_000)
    }

    /// Gate 2: two sessions at real time for five minutes beside a recorder
    /// writing the same audio. CPU under a quarter of one core; no samples lost.
    @Test(.timeLimit(.minutes(10)))
    func two_sessions_real_time_cost() async throws {
        let engine = AppleSpeechEngine(locale: Locale(identifier: "en-US"))
        try await engine.prepare { _ in }
        let fullClip = try Self.clip()
        let clip = Array(fullClip.prefix(fullClip.count / Self.chunk * Self.chunk))
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let mic = FakeMeetingSource()
        let system = FakeMeetingSource()
        let recorder = MeetingRecorder(mic: mic, system: system, directory: MeetingDirectory(url: url))
        let micSession = try await engine.openSession(SessionConfig())
        let systemSession = try await engine.openSession(SessionConfig())
        let drains = [micSession, systemSession].map { session in Task { for await _ in session.partials {} } }
        try recorder.start()

        let cpuStart = Self.cpuSeconds()
        let wallStart = Date()
        var fed = 0
        var offset = 0
        var ticks = 0
        while Date().timeIntervalSince(wallStart) < 300 {
            let end = min(offset + Self.chunk, clip.count)
            let batch = Array(clip[offset..<end])
            mic.emit(batch)
            system.emit(batch)
            micSession.append(batch)
            systemSession.append(batch)
            fed += batch.count
            offset = end == clip.count ? 0 : end
            ticks += 1
            let wait = wallStart.addingTimeInterval(Double(ticks) * 0.1).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        }
        let cpuFraction = (Self.cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart)
        recorder.stop()
        micSession.cancel()
        systemSession.cancel()
        for drain in drains { await drain.value }

        print("[spike] two sessions + recorder: CPU \(Int(cpuFraction * 100)) % of one core over 5 min")
        #expect(cpuFraction < 0.25)
        #expect(PCMTrackReader.sampleCount(at: MeetingDirectory(url: url).micPCM) == fed)
        #expect(PCMTrackReader.sampleCount(at: MeetingDirectory(url: url).systemPCM) == fed)
    }
}
