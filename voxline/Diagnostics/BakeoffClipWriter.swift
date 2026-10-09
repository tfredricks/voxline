import AVFoundation
import Foundation

/// Saves one dictation as a bake-off fixture: `<yyyyMMdd-HHmmss>.wav`
/// (16 kHz mono Float32) and a sibling `.txt` holding the reference text.
/// A second clip in the same second is named `-2`, then `-3`, and so on.
enum BakeoffClipWriter {

    enum WriteError: Error {
        case noAudio
        case bufferUnavailable
    }

    /// Creates `directory` if needed. Returns the `.wav` file's URL.
    static func write(samples: [Float], reference: String, to directory: URL, now: Date) throws -> URL {
        guard !samples.isEmpty else { throw WriteError.noAudio }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = unusedClipURL(in: directory, base: baseName(for: now))
        try writeAudio(samples, to: wav)
        try Data(reference.utf8).write(to: textURL(for: wav))
        return wav
    }

    private static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func unusedClipURL(in directory: URL, base: String) -> URL {
        let files = FileManager.default
        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base)-\(suffix)"
            let wav = directory.appending(path: "\(name).wav")
            if !files.fileExists(atPath: wav.path), !files.fileExists(atPath: textURL(for: wav).path) {
                return wav
            }
            suffix += 1
        }
    }

    private static func textURL(for wav: URL) -> URL {
        wav.deletingPathExtension().appendingPathExtension("txt")
    }

    private static func writeAudio(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFormat.whisperSampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw WriteError.bufferUnavailable }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: source.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioFormat.whisperSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        file.close()
    }
}
