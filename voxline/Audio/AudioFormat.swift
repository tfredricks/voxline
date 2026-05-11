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

    /// Maps a linear peak amplitude in [0, 1] to a perceptual meter value in
    /// [0, 1] on a dBFS scale (-50 dBFS → 0, 0 dBFS → 1). Floor is set above
    /// typical room ambient (~-45 dBFS) so the bar reads near-zero at idle.
    static func displayLevel(fromPeak peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let dbfs = 20 * log10f(peak)
        let floor: Float = -50
        return max(0, min(1, (dbfs - floor) / -floor))
    }
}
