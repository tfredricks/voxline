@preconcurrency import AVFoundation
import Foundation

/// Resamples hardware-rate input to Whisper's format (16 kHz mono Float32).
///
/// Safe to call from the tap thread and the main actor at the same time: every
/// conversion runs under one lock, so the underlying AVAudioConverter is never
/// used concurrently. `flushAndClose()` ends the stream; afterwards both methods
/// return [] and a new converter is needed for the next capture.
final class CaptureConverter: @unchecked Sendable {

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var isClosed = false

    init(inputFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.targetFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.cannotConvertFormat
        }
        self.converter = converter
        self.target = target
    }

    /// Converts one hardware buffer and returns whatever the resampler can emit
    /// now. It may hold some audio back for a later call; only
    /// `flushAndClose()` is guaranteed to release the remainder. Returns []
    /// once closed.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.withLock {
            guard !isClosed else { return [] }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                return []
            }
            var error: NSError?
            var consumed = false
            let status = converter.convert(to: output, error: &error) { _, statusOut in
                if consumed {
                    // Must be .noDataNow, never .endOfStream. .endOfStream
                    // permanently terminates the converter's stream and every
                    // subsequent convert() call (i.e. every later tap buffer)
                    // silently fails.
                    statusOut.pointee = .noDataNow
                    return nil
                }
                consumed = true
                statusOut.pointee = .haveData
                return buffer
            }
            guard status != .error else { return [] }
            return Self.samples(in: output)
        }
    }

    /// Ends the stream and returns every frame the resampler was still
    /// holding. Calling it again returns [].
    func flushAndClose() -> [Float] {
        lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            var tail: [Float] = []
            while let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, statusOut in
                    statusOut.pointee = .endOfStream
                    return nil
                }
                tail.append(contentsOf: Self.samples(in: output))
                if status == .endOfStream || status == .error || output.frameLength == 0 {
                    break
                }
            }
            return tail
        }
    }

    private static func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
