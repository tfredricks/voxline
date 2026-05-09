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

    /// Optional debug observer — fires once per AVAudioEngine tap callback
    /// with the buffer's frame count. Lets the Debug window distinguish
    /// "engine stalled after one buffer" from "many buffers but converter
    /// is dropping samples".
    var onTapCallback: ((Int) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []

    /// Begin capture. Throws if the input device is unavailable or sample-rate
    /// negotiation fails. Stops and restarts the engine on each cycle — the
    /// previous "keep engine running between captures" optimization caused the
    /// engine to stall after delivering ~1 buffer (the engine has no output
    /// node, so without a fresh prepare()/start() it doesn't reliably pump
    /// input). The system mic indicator (orange dot) also stays lit forever
    /// when the engine is always running, which is its own problem.
    func start() throws {
        // Lifecycle per press: stop -> removeTap -> reconfigure -> installTap
        // -> start. Engine instance is reused but fully stopped between
        // recordings (the always-running pattern stalls input on Sequoia/26.x
        // and keeps the system mic indicator lit).
        if engine.isRunning {
            engine.stop()
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // CRITICAL: use inputFormat(forBus: 0), NOT outputFormat. On macOS
        // 26.x, outputFormat goes stale on input nodes and AVAudioEngine
        // delivers exactly one tap buffer then stalls. This was voxline's
        // "0.1s of audio per chord" bug. Reference: GhostPepper does the
        // same thing — comment in their code explicitly calls this out.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // Whisper target format (16 kHz mono Float32).
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.targetFormatUnavailable
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: target) else {
            throw AudioCaptureError.cannotConvertFormat
        }
        converter = conv

        samples.removeAll(keepingCapacity: true)

        // ~20 ms buffer at the hardware sample rate (e.g. 960 frames at 48 kHz).
        // Short buffers keep the stop-time tail flush cheap.
        let bufferDuration = 0.02
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * bufferDuration))

        let convLocal = conv
        let targetFmt = target
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            Task { @MainActor [weak self] in self?.onTapCallback?(frames) }
            self.handleInputNonisolated(buffer: buffer, converter: convLocal, target: targetFmt)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    /// Stop capture. Removes the tap and stops the engine so the system mic
    /// indicator turns off and CoreAudio releases the input device.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
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
