@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures audio from the system input device, resamples to Whisper's format
/// (16 kHz mono Float32), and accumulates the converted samples in memory.
///
/// Audio is *never* written to disk. Buffers are released when stop() is called
/// after the consumer has drained them via takeSamples().
@MainActor
final class AudioCaptureService {

    /// Optional CoreAudio UID for the preferred input device. nil = system default.
    /// AppCoordinator applies this from AppSettings before each capture.
    var preferredInputDeviceUID: String?

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

    /// Bumped on every start() and stop(). Tap-callback Tasks that arrive on
    /// MainActor after a stop+takeSamples cycle see a stale epoch and discard
    /// themselves, so they can't prefix the next recording with leftover audio.
    private var currentEpoch: UInt64 = 0

    /// Begin capture. Throws if the input device is unavailable or sample-rate
    /// negotiation fails.
    func start() throws {
        if engine.isRunning {
            engine.stop()
        }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // Apply the preferred device. If the UID no longer resolves (mic unplugged
        // since Settings save) or AudioUnitSetProperty fails, fall through to the
        // system default — don't throw.
        if let uid = preferredInputDeviceUID,
           let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid),
           let au = engine.inputNode.audioUnit {
            var mutableID = deviceID
            _ = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Use inputFormat(forBus:), not outputFormat. On macOS 26.x,
        // outputFormat on input nodes goes stale and the tap delivers one
        // buffer then stalls.
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
        currentEpoch &+= 1
        let epoch = currentEpoch

        // ~20 ms buffer at the hardware sample rate (e.g. 960 frames at 48 kHz).
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * 0.02))

        let convLocal = conv
        let targetFmt = target
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            Task { @MainActor [weak self] in
                guard let self, self.currentEpoch == epoch else { return }
                self.onTapCallback?(frames)
            }
            self.handleInputNonisolated(buffer: buffer, converter: convLocal, target: targetFmt, epoch: epoch)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        let deviceName = resolvedInputDeviceName()
        AppLog.audio.info("capture started: device='\(deviceName)', \(Int(hwFormat.sampleRate))Hz → \(Int(AudioFormat.whisperSampleRate))Hz")
    }

    private func resolvedInputDeviceName() -> String {
        let inputs = AudioDeviceEnumerator.inputDevices()
        if let uid = preferredInputDeviceUID,
           let match = inputs.first(where: { $0.uid == uid }) {
            return match.name
        }
        return inputs.first(where: { $0.isDefault })?.name ?? "(unknown)"
    }

    /// Stop capture. Removes the tap and stops the engine so the system mic
    /// indicator turns off.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        // Invalidate any tap-callback Tasks that have not yet hopped to
        // MainActor — they would otherwise append into the buffer the next
        // recording is about to use.
        currentEpoch &+= 1
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
        target: AVAudioFormat,
        epoch: UInt64
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

        guard status != .error, let channel = outBuffer.floatChannelData?[0] else {
            return
        }

        let count = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))

        Task { @MainActor [weak self] in
            guard let self, self.currentEpoch == epoch else { return }
            self.samples.append(contentsOf: chunk)
            let level = AudioFormat.displayLevel(fromPeak: AudioFormat.peakLevel(samples: chunk))
            self.onLevel?(level)
        }
    }
}

enum AudioCaptureError: Error {
    case noInputDevice
    case targetFormatUnavailable
    case cannotConvertFormat
}
