@preconcurrency import AVFoundation
import CoreAudio
import Foundation

/// All system audio output except voxline's own, through a private Core
/// Audio process tap wrapped in a private aggregate device. A denied System
/// Audio Recording permission is not an error here: the tap delivers
/// silence, and `MeetingPipeline` treats an all-zero track as no system
/// audio.
final class SystemAudioTap: MeetingAudioSource {

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var converter: CaptureConverter?
    private var onSamples: (@Sendable ([Float]) -> Void)?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "voxline.meetings.system-tap", qos: .userInitiated)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    func start(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void
    ) throws {
        stop()
        do {
            try startTap(onSamples: onSamples, onFailure: onFailure)
        } catch {
            stop()
            throw error
        }
    }

    private func startTap(
        onSamples: @escaping @Sendable ([Float]) -> Void,
        onFailure: @escaping @Sendable (MeetingAudioSourceError) -> Void
    ) throws {
        let own = Self.processObjectID(pid: getpid())
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create the system audio tap")
        tapID = tap

        let outputUID = try Self.defaultOutputDeviceUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "voxline meeting capture",
            kAudioAggregateDeviceUIDKey: "com.voxline.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the capture device")
        aggregateID = device

        var streamDescription = try Self.tapFormat(tap)
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw MeetingAudioSourceError.unavailable("The system audio format isn't supported.")
        }
        let converter: CaptureConverter
        do {
            converter = try CaptureConverter(inputFormat: format)
        } catch {
            throw MeetingAudioSourceError.unavailable("The system audio format isn't supported.")
        }
        self.converter = converter
        self.onSamples = onSamples

        let once = FireOnce()
        var proc: AudioDeviceIOProcID?
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            guard !once.hasFired,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
            else { return }
            let samples = converter.convert(buffer)
            if !samples.isEmpty { onSamples(samples) }
        }, "start system audio capture")
        procID = proc
        try Self.check(AudioDeviceStart(device, proc), "start system audio capture")

        let listener: AudioObjectPropertyListenerBlock = { _, _ in
            if once.claim() { onFailure(.configurationChanged) }
        }
        var address = Self.defaultOutputAddress
        try Self.check(
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener),
            "watch the output device"
        )
        outputListener = listener
    }

    func stop() {
        if let listener = outputListener {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
        outputListener = nil
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if let tail = converter?.flushAndClose(), !tail.isEmpty { onSamples?(tail) }
        converter = nil
        onSamples = nil
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            AppLog.meetings.error("system tap: couldn't \(action, privacy: .public) (\(status))")
            throw MeetingAudioSourceError.unavailable("Couldn't \(action) (error \(status)).")
        }
    }

    private static func processObjectID(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputDeviceUID() throws -> String {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var outputAddress = defaultOutputAddress
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &outputAddress, 0, nil, &size, &device), "find the output device")
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "read the output device")
        guard let uid else { throw MeetingAudioSourceError.unavailable("The output device has no identifier.") }
        return uid.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format), "read the system audio format")
        return format
    }
}
