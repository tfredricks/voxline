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

    /// True between a successful start() and the matching stop(). Guards
    /// stopPrewarm() so a disarm edge can never kill a live recording.
    private var isCapturing = false

    /// Route the engine's input AU to the preferred device, when set and still
    /// present. Falls through silently to the system default otherwise.
    private func applyPreferredDevice() {
        guard let uid = preferredInputDeviceUID,
              let deviceID = AudioDeviceEnumerator.deviceID(forUID: uid),
              let au = engine.inputNode.audioUnit else { return }
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

    /// Best-effort engine spin-up on the chord's armed edge (one modifier
    /// down). Starting AVAudioEngine is the expensive part of start() —
    /// hundreds of ms on Bluetooth inputs — so paying it before the second
    /// modifier lands means the recording captures from the first syllable.
    /// No tap is installed and the sample buffer is untouched. Errors are
    /// swallowed here and surface properly from start() if the user completes
    /// the chord.
    func prewarm() {
        guard !engine.isRunning else { return }
        applyPreferredDevice()
        // Touch the input format so the engine builds its input graph before
        // start — an engine started with no configured input does not open
        // the microphone and would prewarm nothing.
        let hwFormat = engine.inputNode.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else { return }
        do {
            try engine.start()
        } catch {
            AppLog.audio.debug("prewarm failed; start() will retry: \(error.localizedDescription)")
        }
    }

    /// Stop an engine that was prewarmed but never used (armed edge released
    /// without completing the chord, or recording was refused). No-op while a
    /// real capture is running.
    func stopPrewarm() {
        guard !isCapturing else { return }
        engine.stop()
    }

    /// Begin capture. Throws if the input device is unavailable or sample-rate
    /// negotiation fails.
    func start() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // When prewarm already has the engine running, the preferred device was
        // applied on the armed edge milliseconds ago — don't reconfigure a
        // running engine. Cold path applies it as before.
        if !engine.isRunning {
            applyPreferredDevice()
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

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw error
            }
        }
        isCapturing = true

        // Device-name resolution enumerates every CoreAudio device (an IPC
        // round trip per device) — that cost does not belong between keypress
        // and first captured sample. Log from a background task instead.
        let uid = preferredInputDeviceUID
        let hwRate = Int(hwFormat.sampleRate)
        Task.detached(priority: .utility) {
            let inputs = AudioDeviceEnumerator.inputDevices()
            let name = uid.flatMap { u in inputs.first(where: { $0.uid == u })?.name }
                ?? inputs.first(where: { $0.isDefault })?.name
                ?? "(unknown)"
            AppLog.audio.info("capture started: device='\(name)', \(hwRate)Hz → \(Int(AudioFormat.whisperSampleRate))Hz")
        }
    }

    /// Stop capture. Removes the tap and stops the engine so the system mic
    /// indicator turns off.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
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
