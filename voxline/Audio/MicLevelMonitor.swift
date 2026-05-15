import AVFoundation
import CoreAudio
import Observation

/// Settings-only audio level tap. Publishes peak amplitude in [0, 1] while
/// active. Independent of `AudioCaptureService` — Settings opens its own
/// engine so a live meter works without interfering with real recordings.
/// Callers must `stop()` before a production recording starts.
@MainActor
@Observable
final class MicLevelMonitor {

    /// Most recent peak level [0, 1]. 0 when stopped or no audio.
    private(set) var level: Float = 0

    /// Optional CoreAudio UID for the preferred input device. nil = system default.
    var preferredInputDeviceUID: String?

    private let engine = AVAudioEngine()
    private var running = false

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

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

        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        // ~50 ms buffer — slower meter updates than recording capture, easier on the eye.
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * 0.05))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let count = Int(buffer.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channelData, count: count))
            let display = AudioFormat.displayLevel(fromPeak: AudioFormat.peakLevel(samples: chunk))
            Task { @MainActor [weak self] in
                self?.publishLevel(display)
            }
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        running = true
    }

    func stop() {
        // Unconditional removeTap + stop makes stop() idempotent — safe to call when not running.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
    }

    private func publishLevel(_ raw: Float) {
        guard raw.isFinite else { level = 0; return }
        level = max(0, min(1, raw))
    }

    // Test hooks — internal access; do not call from production code.
    func _publishLevelForTesting(_ v: Float) { publishLevel(v) }
}
