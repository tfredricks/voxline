import Foundation
@preconcurrency import AVFoundation
@testable import voxline

/// Reads the bake-off clips: `<name>.wav` (anything `AVAudioFile` opens) with
/// a sibling `<name>.txt` holding the reference text, plus an optional
/// `terms.txt` of dictionary terms, one per line. Fixtures are never committed.
enum BakeoffFixtures {

    struct Clip {
        let name: String
        let samples: [Float]
        let reference: String
    }

    enum LoadError: Error, CustomStringConvertible {
        case unreadableAudio(String)

        var description: String {
            switch self {
            case .unreadableAudio(let name): return "Could not convert \(name) to 16 kHz mono."
            }
        }
    }

    static var directory: URL { directory(environment: ProcessInfo.processInfo.environment) }

    static func directory(environment: [String: String]) -> URL {
        if let override = environment["VOXLINE_BAKEOFF_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appending(path: "voxline/bakeoff", directoryHint: .isDirectory)
    }

    static var isPresent: Bool { !clipURLs(in: directory).isEmpty }

    /// The bake-off runs real-time engines and rewrites the report, so having
    /// fixtures on disk is not enough: `VOXLINE_BAKEOFF=1` must also be set.
    static var isEnabled: Bool { isEnabled(environment: ProcessInfo.processInfo.environment) }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment["VOXLINE_BAKEOFF"] == "1" && !clipURLs(in: directory(environment: environment)).isEmpty
    }

    static func load(from directory: URL = BakeoffFixtures.directory) throws -> (clips: [Clip], terms: [String]) {
        let clips = try clipURLs(in: directory).map { audioURL -> Clip in
            let name = audioURL.deletingPathExtension().lastPathComponent
            let reference = try String(contentsOf: audioURL.deletingPathExtension().appendingPathExtension("txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Clip(name: name, samples: try samples16kMono(at: audioURL), reference: reference)
        }
        let termsFile = directory.appending(path: "terms.txt")
        let terms = ((try? String(contentsOf: termsFile, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (clips, terms)
    }

    private static func clipURLs(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "wav" }
            .filter { FileManager.default.fileExists(atPath: $0.deletingPathExtension().appendingPathExtension("txt").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func samples16kMono(at url: URL) throws -> [Float] {
        let name = url.lastPathComponent
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard file.length > 0,
              let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioFormat.whisperSampleRate,
                channels: 1,
                interleaved: false
              ),
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw LoadError.unreadableAudio(name) }
        try file.read(into: input)

        if sourceFormat.sampleRate == target.sampleRate, sourceFormat.channelCount == 1,
           let channel = input.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        }

        let capacity = AVAudioFrameCount((Double(input.frameLength) * target.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 1_024
        guard let converter = AVAudioConverter(from: sourceFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { throw LoadError.unreadableAudio(name) }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let channel = output.floatChannelData?[0] else {
            throw conversionError ?? LoadError.unreadableAudio(name)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
