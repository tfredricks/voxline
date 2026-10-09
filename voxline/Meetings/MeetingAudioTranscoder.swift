import AVFoundation
import Foundation

protocol MeetingAudioTranscoding: Sendable {
    func transcode(pcm: URL, to m4a: URL) throws
}

/// AAC-LC, 16 kHz mono, 32 kbps: about 14 MB per track-hour.
struct AACTranscoder: MeetingAudioTranscoding {

    func transcode(pcm: URL, to m4a: URL) throws {
        try? FileManager.default.removeItem(at: m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioFormat.whisperSampleRate,
            AVNumberOfChannelsKey: AudioFormat.whisperChannelCount,
            AVEncoderBitRateKey: 32_000,
        ]
        let file = try AVAudioFile(forWriting: m4a, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try PCMTrackReader.forEachChunk(at: pcm, chunkSamples: 160_000) { samples in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
    }
}
