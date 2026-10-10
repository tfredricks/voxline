@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures audio from the system input device, resamples to Whisper's format
/// (16 kHz mono Float32), and hands each converted chunk to `onSamples` on the
/// audio thread as it arrives. stop() flushes the resampler's tail through the
/// same path before it returns, then leaves the engine running for
/// `CaptureWarmth.keepWarmDuration` so the next capture starts from its first
/// tap buffer; nothing is delivered while it idles.
///
/// Audio is *never* written to disk, and this service keeps none of it: each
/// chunk lives only as long as `onSamples` holds it.
@MainActor
final class AudioCaptureService {

    /// Optional CoreAudio UID for the preferred input device. nil, or a
    /// device that is gone, means the system default. A running engine keeps
    /// its device, so a change stops the idle engine at once, or the running
    /// one when its capture stops.
    var preferredInputDeviceUID: String? {
        didSet {
            guard preferredInputDeviceUID != oldValue, inputBound else { return }
            if isCapturing {
                inputChangedDuringCapture = true
            } else {
                apply(warmth.handle(.inputChanged))
            }
        }
    }

    /// Called periodically (~60 Hz) with the current peak level [0, 1] of the
    /// most recently captured chunk. Used by the recording pill's waveform.
    var onLevel: ((Float) -> Void)?

    /// Receives every converted 16 kHz chunk, synchronously and in order, on
    /// the audio tap thread; the flushed tail arrives on the main actor inside
    /// stop(). Read once per start(). Must be cheap and must never wait on the
    /// main actor: stop() takes the same lock and waits for an in-flight
    /// delivery to finish.
    var onSamples: (@Sendable ([Float]) -> Void)?

    /// Fires on the main actor when an input configuration change (device
    /// unplugged, Bluetooth mic dropped, sample rate switched) has stopped the
    /// engine during a capture; no more audio arrives until the next start().
    /// Configuration changes that leave the engine running are ignored.
    var onInterrupted: (() -> Void)?

    private let engine = AVAudioEngine()
    private var delivery: SampleDelivery?
    private var configurationObserver: (any NSObjectProtocol)?

    /// Bumped on every start() and stop(). Level and tap-callback hops that
    /// reach the main actor after stop() see a stale epoch and discard
    /// themselves, so a finished recording can't move the next one's meter.
    private var currentEpoch: UInt64 = 0

    /// True between a successful start() and the matching stop(). Guards
    /// stopPrewarm() so a disarm edge can never kill a live recording.
    private var isCapturing = false

    private var warmth = CaptureWarmth()
    private var keepWarmStop: Task<Void, Never>?

    /// True once `inputNode` has been read, which binds the input device
    /// and can block on the microphone permission prompt. Until then a new
    /// preferred device has nothing to re-route.
    private var inputBound = false
    private var inputChangedDuringCapture = false

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Binds the input to the preferred device, or to the system default when
    /// none is set or it is gone. Never call it on a running engine. A device
    /// change only lands on an uninitialized unit, so the engine is stopped
    /// (which drops its preparation) only when the device actually changes.
    private func routeInput() {
        let input = engine.inputNode
        inputBound = true
        guard let target = AudioDeviceEnumerator.inputDeviceID(preferring: preferredInputDeviceUID),
              target != AudioDeviceEnumerator.currentDevice(of: input) else { return }
        engine.stop()
        AudioDeviceEnumerator.setCurrentDevice(target, of: input)
    }

    /// Binds the input device and pre-allocates the engine ahead of the first
    /// capture, so neither cost lands on the first keypress after launch.
    /// Reading `inputNode` can block on the microphone permission prompt, so
    /// callers gate this on permission already granted. No-op while the
    /// engine runs.
    func warmUp() {
        guard !engine.isRunning else { return }
        routeInput()
        _ = engine.inputNode.inputFormat(forBus: 0)
        engine.prepare()
    }

    /// Best-effort engine spin-up on the chord's armed edge (one modifier
    /// down). Starting AVAudioEngine is the expensive part of start() —
    /// hundreds of ms on Bluetooth inputs — so paying it before the second
    /// modifier lands means the recording captures from the first syllable.
    /// No tap is installed and nothing is delivered. Errors are
    /// swallowed here and surface properly from start() if the user completes
    /// the chord. A warm engine stays running while the chord is armed.
    func prewarm() {
        apply(warmth.handle(.prewarmRequested))
        guard !engine.isRunning else { return }
        routeInput()
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
    /// real capture is running, and while a keep-warm window is open: that
    /// engine stops when the window ends, or here if it ended while armed.
    func stopPrewarm() {
        guard !isCapturing else { return }
        apply(warmth.handle(.prewarmCancelled))
    }

    /// Begin capture. Throws if the input device is unavailable or sample-rate
    /// negotiation fails.
    func start() throws {
        apply(warmth.handle(.captureStarted))
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        if !engine.isRunning {
            routeInput()
        }

        // Use inputFormat(forBus:), not outputFormat. On macOS 26.x,
        // outputFormat on input nodes goes stale and the tap delivers one
        // buffer then stalls.
        let hwFormat = input.inputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        let delivery = SampleDelivery(
            converter: try CaptureConverter(inputFormat: hwFormat),
            onSamples: onSamples
        )
        self.delivery = delivery
        currentEpoch &+= 1
        let epoch = currentEpoch

        // ~20 ms buffer at the hardware sample rate (e.g. 960 frames at 48 kHz).
        let bufferSize = max(1, AVAudioFrameCount(hwFormat.sampleRate * 0.02))

        input.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            let chunk = delivery.deliver(buffer)
            let level = chunk.isEmpty
                ? nil
                : AudioFormat.displayLevel(fromPeak: AudioFormat.peakLevel(samples: chunk))
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.currentEpoch == epoch else { return }
                if let level {
                    self.onLevel?(level)
                }
            }
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

    /// Stop capture. Removes the tap and flushes the resampler's tail to
    /// `onSamples`; every converted sample has been delivered when this
    /// returns. The engine keeps running for the keep-warm window, and the
    /// system mic indicator turns off when that ends.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        delivery?.deliverTail()
        delivery = nil
        isCapturing = false
        currentEpoch &+= 1
        apply(warmth.handle(.captureStopped))
        if inputChangedDuringCapture {
            inputChangedDuringCapture = false
            apply(warmth.handle(.inputChanged))
        }
    }

    // MARK: - Private

    private func apply(_ actions: [CaptureWarmth.Action]) {
        for action in actions {
            switch action {
            case .scheduleKeepWarmStop:
                keepWarmStop?.cancel()
                keepWarmStop = Task { [weak self] in
                    try? await Task.sleep(for: CaptureWarmth.keepWarmDuration)
                    guard !Task.isCancelled, let self else { return }
                    self.keepWarmStop = nil
                    self.apply(self.warmth.handle(.keepWarmElapsed))
                }
            case .cancelKeepWarmStop:
                keepWarmStop?.cancel()
                keepWarmStop = nil
            case .stopEngine:
                engine.stop()
                if inputBound {
                    routeInput()
                }
                // A prepared engine starts in about half the time.
                engine.prepare()
            }
        }
    }

    private func handleConfigurationChange() {
        guard isCapturing else { return }
        guard !engine.isRunning else {
            AppLog.audio.debug("input configuration change ignored; engine still running")
            return
        }
        AppLog.audio.error("input configuration changed during capture")
        onInterrupted?()
    }
}

/// Serializes conversion with delivery for one capture. A single lock spans
/// convert-then-deliver on the tap thread and flush-then-deliver in stop(), so
/// the tail always reaches `onSamples` after the last tap chunk, and nothing is
/// delivered once the converter is closed.
final class SampleDelivery: @unchecked Sendable {

    private let lock = NSLock()
    private let converter: CaptureConverter
    private let onSamples: (@Sendable ([Float]) -> Void)?

    init(converter: CaptureConverter, onSamples: (@Sendable ([Float]) -> Void)?) {
        self.converter = converter
        self.onSamples = onSamples
    }

    func deliver(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.withLock { publish(converter.convert(buffer)) }
    }

    @discardableResult
    func deliverTail() -> [Float] {
        lock.withLock { publish(converter.flushAndClose()) }
    }

    private func publish(_ chunk: [Float]) -> [Float] {
        guard !chunk.isEmpty else { return chunk }
        onSamples?(chunk)
        return chunk
    }
}

enum AudioCaptureError: LocalizedError {
    case noInputDevice
    case targetFormatUnavailable
    case cannotConvertFormat

    var errorDescription: String? {
        switch self {
        case .noInputDevice:           return "No microphone input is available."
        case .targetFormatUnavailable: return "Couldn't set up audio conversion."
        case .cannotConvertFormat:     return "The microphone's audio format isn't supported."
        }
    }
}
