import AVFoundation
import Foundation

/// Captures audio from the system input device, resamples to Whisper's format
/// (16 kHz mono Float32), and accumulates the converted samples in memory.
///
/// Audio is *never* written to disk. Buffers are released when stop() is called
/// after the consumer has drained them via takeSamples().
@MainActor
final class AudioCaptureService {

    /// Called periodically (~60 Hz) with the current peak level [0, 1] of the
    /// most recently captured chunk. Used by the recording pill's waveform.
    var onLevel: ((Float) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var convertedFormat: AVAudioFormat?
    private var samples: [Float] = []

    /// Begin capture. Throws if the input device is unavailable or sample-rate negotiation fails.
    func start() throws {
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // Whisper input format.
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.targetFormatUnavailable
        }
        convertedFormat = target

        guard let conv = AVAudioConverter(from: hardwareFormat, to: target) else {
            throw AudioCaptureError.cannotConvertFormat
        }
        converter = conv

        samples.removeAll(keepingCapacity: true)

        // Capture locally before tap closure to avoid main-actor isolation issues.
        let convLocal = conv
        let targetFmt = target
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.handleInputNonisolated(buffer: buffer, converter: convLocal, target: targetFmt)
        }

        try engine.start()
    }

    /// Stop capture. Returns immediately; samples remain available via takeSamples().
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Drain and return the converted samples buffered so far. Subsequent calls return [].
    func takeSamples() -> [Float] {
        defer { samples.removeAll(keepingCapacity: false) }
        return samples
    }

    // MARK: - Private

    nonisolated private func handleInputNonisolated(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        target: AVAudioFormat
    ) {
        // Allocate a scratch buffer big enough for any reasonable conversion result.
        // 16k * (hardware/target ratio) — pad generously.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)

        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: target,
            frameCapacity: estimatedFrames
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return buffer
        }

        guard status != .error, let channel = outBuffer.floatChannelData?[0] else {
            return
        }

        let count = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.samples.append(contentsOf: chunk)
            let level = AudioFormat.peakLevel(samples: chunk)
            self.onLevel?(level)
        }
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
    case targetFormatUnavailable
    case cannotConvertFormat
}
