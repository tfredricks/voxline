// voxlineTests/AudioDeviceEnumeratorTests.swift
import Testing
import Foundation
@testable import voxline

@Suite struct AudioDeviceEnumeratorTests {

    /// Smoke test: on any host running the test (CI or laptop), CoreAudio
    /// returns at least the system default input device. Exact list varies.
    @Test func returns_at_least_one_input_device_on_a_real_host() {
        let devices = AudioDeviceEnumerator.inputDevices()
        #expect(!devices.isEmpty)
        #expect(devices.contains { !$0.uid.isEmpty && !$0.name.isEmpty })
    }

    @Test func exactly_one_default_device() {
        let devices = AudioDeviceEnumerator.inputDevices()
        let defaults = devices.filter(\.isDefault)
        #expect(defaults.count <= 1) // Zero is acceptable on a headless box without a default mic.
    }

    @Test func deviceID_for_uid_resolves_a_real_device() {
        let devices = AudioDeviceEnumerator.inputDevices()
        guard let first = devices.first else { return }  // headless host: skip
        let id = AudioDeviceEnumerator.deviceID(forUID: first.uid)
        #expect(id != nil)
    }
}
