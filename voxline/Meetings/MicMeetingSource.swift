@preconcurrency import AVFoundation
import Foundation

/// Microphone capture on its own engine, independent of dictation's
/// `AudioCaptureService`.
final class MicMeetingSource: MeetingAudioSource {

    private let preferredInputDeviceUID: String?
    private var engine: AVAudioEngine?
    private var converter: CaptureConverter?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var observer: (any NSObjectProtocol)?

    init(preferredInputDeviceUID: String?) {
        self.preferredInputDeviceUID = preferredInputDeviceUID
    }

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void
    ) throws {
        stop()
        let engine = AVAudioEngine()
        if let uid = preferredInputDeviceUID {
            AudioDeviceEnumerator.route(engine.inputNode, toDeviceUID: uid)
        }
        let format = engine.inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw MeetingAudioSourceError.unavailable("No microphone input is available.")
        }
        let converter: CaptureConverter
        do {
            converter = try CaptureConverter(inputFormat: format)
        } catch {
            throw MeetingAudioSourceError.unavailable("The microphone's audio format isn't supported.")
        }
        let once = FireOnce()
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { buffer, _ in
            guard !once.hasFired else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { _ in
            if once.claim() { onFailure(.configurationChanged) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            throw MeetingAudioSourceError.unavailable(error.localizedDescription)
        }
        self.engine = engine
        self.converter = converter
        self.onSamples = onSamples
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if let tail = converter?.flushAndClose(), !tail.isEmpty { onSamples?(tail) }
        converter = nil
        onSamples = nil
    }
}
