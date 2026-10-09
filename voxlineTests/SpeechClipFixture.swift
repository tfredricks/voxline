import Testing
import Foundation
@preconcurrency import AVFoundation

/// Synthesized speech for engine integration tests: `say` renders `text` to a
/// temporary file, which is read back as 16 kHz mono Float32 and deleted.
enum SpeechClipFixture {
    static func synthesize(_ text: String, voice: String? = nil) throws -> [Float] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "voxline-speech-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "clip.wav")

        let say = Process()
        say.executableURL = URL(filePath: "/usr/bin/say")
        say.arguments = (voice.map { ["-v", $0] } ?? []) + ["-o", url.path, "--data-format=LEF32@16000", text]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        let file = try AVAudioFile(forReading: url)
        try #require(file.processingFormat.sampleRate == 16_000)
        try #require(file.processingFormat.channelCount == 1)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }
}
