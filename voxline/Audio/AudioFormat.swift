import Foundation

enum AudioFormat {
    /// Whisper expects 16 kHz audio.
    static let whisperSampleRate: Double = 16_000

    /// Whisper expects mono.
    static let whisperChannelCount: UInt32 = 1

    /// Sample count for a duration at Whisper's sample rate. Negative durations clamp to 0.
    static func sampleCount(forSeconds seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return Int(seconds * whisperSampleRate)
    }

    /// Peak absolute amplitude of a Float32 PCM buffer, clamped to [0, 1].
    /// Used as a proxy for the recording-pill waveform meter.
    static func peakLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        for s in samples {
            let m = abs(s)
            if m > peak { peak = m }
        }
        return min(peak, 1.0)
    }
}
