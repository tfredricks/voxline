import AVFoundation
import Testing

/// Synthetic hardware-rate input for converter and delivery tests: 48 kHz
/// mono Float32 buffers of a 440 Hz sine, phase-continuous across buffers.
enum TestAudio {
    static let hardwareRate: Double = 48_000

    static func hardwareFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 1))
    }

    static func sineBuffer(frames: AVAudioFrameCount, startingAt offset: Int = 0) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: try hardwareFormat(), frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            let t = Double(offset + i) / hardwareRate
            channel[i] = Float(0.5 * sin(2 * Double.pi * 440 * t))
        }
        return buffer
    }
}
