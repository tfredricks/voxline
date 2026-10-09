@preconcurrency import AVFoundation
import Foundation

/// Microphone capture on its own engine, independent of dictation's
/// `AudioCaptureService`.
final class MicMeetingSource: MeetingAudioSource {

    private let preferredInputDeviceUID: String?
    private var engine: AVAudioEngine?
    private var delivery: SampleDelivery?
    private var once: FireOnce?
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
        let delivery: SampleDelivery
        do {
            delivery = SampleDelivery(converter: try CaptureConverter(inputFormat: format), onSamples: onSamples)
        } catch {
            throw MeetingAudioSourceError.unavailable("The microphone's audio format isn't supported.")
        }
        let once = FireOnce()
        engine.inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { buffer, _ in
            guard !once.hasFired else { return }
            _ = delivery.deliver(buffer)
        }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak engine] _ in
            guard let engine, !engine.isRunning else { return }
            if once.claim() { onFailure(.configurationChanged) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NotificationCenter.default.removeObserver(observer)
            engine.inputNode.removeTap(onBus: 0)
            throw MeetingAudioSourceError.unavailable(error.localizedDescription)
        }
        self.engine = engine
        self.delivery = delivery
        self.once = once
        self.observer = observer
    }

    func stop() {
        _ = once?.claim()
        once = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        delivery?.deliverTail()
        delivery = nil
        engine?.stop()
        engine = nil
    }
}
