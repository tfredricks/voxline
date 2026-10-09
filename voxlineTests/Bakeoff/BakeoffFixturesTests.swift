import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import voxline

@Suite struct BakeoffFixturesTests {

    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "bakeoff-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeWav(_ url: URL, seconds: Double, rate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            channel[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        try file.write(from: buffer)
    }

    @Test func load_pairs_wavs_with_references_in_name_order_and_resamples_to_16k() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWav(dir.appending(path: "clip-02.wav"), seconds: 0.5, rate: 16_000)
        try "  second line \n".write(to: dir.appending(path: "clip-02.txt"), atomically: true, encoding: .utf8)
        try writeWav(dir.appending(path: "clip-01.wav"), seconds: 1, rate: 48_000)
        try "first line".write(to: dir.appending(path: "clip-01.txt"), atomically: true, encoding: .utf8)
        try writeWav(dir.appending(path: "orphan.wav"), seconds: 1, rate: 16_000)

        let loaded = try BakeoffFixtures.load(from: dir)

        #expect(loaded.clips.map(\.name) == ["clip-01", "clip-02"])
        #expect(loaded.clips.map(\.reference) == ["first line", "second line"])
        #expect(abs(loaded.clips[0].samples.count - 16_000) <= 16)
        #expect(loaded.clips[1].samples.count == 8_000)
        #expect((loaded.clips[0].samples.map { abs($0) }.max() ?? 0) > 0.3)
    }

    @Test func load_reads_terms_one_per_line_skipping_blanks() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "LangGraph\n\n  Argmax  \r\nKubernetes\n".write(to: dir.appending(path: "terms.txt"), atomically: true, encoding: .utf8)

        let loaded = try BakeoffFixtures.load(from: dir)

        #expect(loaded.clips.isEmpty)
        #expect(loaded.terms == ["LangGraph", "Argmax", "Kubernetes"])
    }

    @Test func load_without_a_terms_file_returns_no_terms() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try BakeoffFixtures.load(from: dir).terms.isEmpty)
    }

    @Test func suite_is_enabled_only_with_the_opt_in_and_fixtures() throws {
        let populated = try makeDirectory()
        let empty = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: populated)
            try? FileManager.default.removeItem(at: empty)
        }
        try writeWav(populated.appending(path: "clip-01.wav"), seconds: 0.2, rate: 16_000)
        try "hello".write(to: populated.appending(path: "clip-01.txt"), atomically: true, encoding: .utf8)

        let withFixtures = ["VOXLINE_BAKEOFF_DIR": populated.path]
        #expect(!BakeoffFixtures.isEnabled(environment: withFixtures))
        #expect(!BakeoffFixtures.isEnabled(environment: withFixtures.merging(["VOXLINE_BAKEOFF": "0"]) { $1 }))
        #expect(BakeoffFixtures.isEnabled(environment: withFixtures.merging(["VOXLINE_BAKEOFF": "1"]) { $1 }))
        #expect(!BakeoffFixtures.isEnabled(environment: ["VOXLINE_BAKEOFF_DIR": empty.path, "VOXLINE_BAKEOFF": "1"]))
    }
}
