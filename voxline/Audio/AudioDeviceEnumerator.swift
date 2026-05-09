// voxline/Audio/AudioDeviceEnumerator.swift
import CoreAudio
import Foundation

struct AudioDevice: Equatable {
    /// Stable UID across reboots. Stored in AppSettings.audioInputDeviceUID.
    let uid: String
    /// Human-readable name shown in the picker.
    let name: String
    /// True if this is the system's current default input device.
    let isDefault: Bool
}

enum AudioDeviceEnumerator {

    /// Returns the current list of input-capable CoreAudio devices.
    /// Returns [] on CoreAudio failure — callers should surface "System default" as a fallback.
    static func inputDevices() -> [AudioDevice] {
        let allIDs = systemDeviceIDs()
        let defaultID = defaultInputDeviceID()
        var result: [AudioDevice] = []
        for id in allIDs where hasInputStreams(id) {
            guard
                let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID, scope: kAudioObjectPropertyScopeGlobal),
                let name = stringProperty(id, selector: kAudioObjectPropertyName, scope: kAudioObjectPropertyScopeGlobal)
            else { continue }
            result.append(AudioDevice(uid: uid, name: name, isDefault: id == defaultID))
        }
        return result
    }

    // MARK: - CoreAudio plumbing

    private static func systemDeviceIDs() -> [AudioDeviceID] {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sizeStatus = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return status == noErr ? ids : []
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(
        _ id: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfString: CFString? = nil
        let status = withUnsafeMutablePointer(to: &cfString) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cfString as String? else { return nil }
        return s
    }

    /// Look up the AudioDeviceID for a UID stored in AppSettings.
    /// Returns nil if the device is no longer present (e.g., USB mic unplugged).
    ///
    /// CoreAudio's kAudioHardwarePropertyDeviceForUID requires mInputData to be a
    /// pointer to a CFStringRef, not a raw UTF-8 buffer. The nested
    /// withUnsafeMutablePointer calls ensure both pointers remain valid for the
    /// duration of the C call.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDeviceForUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status: OSStatus = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            withUnsafeMutablePointer(to: &deviceID) { devPtr in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(uidPtr),
                    mInputDataSize: UInt32(MemoryLayout<CFString>.size),
                    mOutputData: UnsafeMutableRawPointer(devPtr),
                    mOutputDataSize: UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &addr, 0, nil, &size, &translation
                )
            }
        }
        return status == noErr && deviceID != 0 ? deviceID : nil
    }
}
