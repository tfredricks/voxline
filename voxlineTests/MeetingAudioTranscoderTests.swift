import AVFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct MeetingAudioTranscoderTests {

    @Test func transcodes_to_16k_mono_aac_of_matching_length() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pcm = dir.appending(path: "t.pcm")
        let m4a = dir.appending(path: "t.m4a")
        let writer = try PCMTrackWriter(url: pcm)
        writer.append((0..<16_000).map { Float(sin(Double($0) * 2 * .pi * 440 / 16_000)) * 0.5 })
        writer.close()

        try AACTranscoder().transcode(pcm: pcm, to: m4a)

        let file = try AVAudioFile(forReading: m4a)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(Int(file.length) - 16_000) < 4_096)
    }
}
