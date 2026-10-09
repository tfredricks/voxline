import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import voxline

@Suite struct BakeoffClipWriterTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "voxline-bakeoff-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// 2026-10-08 14:30:05 local time.
    private func clipTime() throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 14, minute: 30, second: 5)))
    }

    private static let samples: [Float] = (0..<24_000).map { Float(sin(Double($0) * 0.05) * 0.4) }

    @Test func writes_a_16k_mono_wav_and_its_reference_text() throws {
        let directory = temporaryDirectory().appending(path: "nested", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

        let wav = try BakeoffClipWriter.write(samples: Self.samples, reference: "Ship it on Friday.", to: directory, now: try clipTime())

        #expect(wav.lastPathComponent == "20261008-143005.wav")
        #expect(wav.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
        let file = try AVAudioFile(forReading: wav)
        #expect(file.fileFormat.commonFormat == .pcmFormatFloat32)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == AVAudioFramePosition(Self.samples.count))

        let text = wav.deletingPathExtension().appendingPathExtension("txt")
        #expect(text.lastPathComponent == "20261008-143005.txt")
        #expect(try String(contentsOf: text, encoding: .utf8) == "Ship it on Friday.")
    }

    @Test func a_second_clip_in_the_same_second_gets_a_suffix() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = try clipTime()

        let first = try BakeoffClipWriter.write(samples: Self.samples, reference: "one", to: directory, now: now)
        let second = try BakeoffClipWriter.write(samples: Self.samples, reference: "two", to: directory, now: now)
        let third = try BakeoffClipWriter.write(samples: Self.samples, reference: "three", to: directory, now: now)

        #expect(first.lastPathComponent == "20261008-143005.wav")
        #expect(second.lastPathComponent == "20261008-143005-2.wav")
        #expect(third.lastPathComponent == "20261008-143005-3.wav")
        #expect(try String(contentsOf: first.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) == "one")
        #expect(try String(contentsOf: second.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) == "two")
        #expect(try String(contentsOf: third.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8) == "three")
    }

    /// Also checks every sample survives the round trip, tail included.
    @Test func written_clips_load_as_bakeoff_fixtures() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try BakeoffClipWriter.write(samples: Self.samples, reference: "Deploy the Voxline build.", to: directory, now: try clipTime())

        let fixtures = try BakeoffFixtures.load(from: directory)
        #expect(fixtures.clips.map(\.name) == ["20261008-143005"])
        let clip = try #require(fixtures.clips.first)
        #expect(clip.reference == "Deploy the Voxline build.")
        #expect(clip.samples.count == Self.samples.count)
        #expect(clip.samples == Self.samples)
    }
}
