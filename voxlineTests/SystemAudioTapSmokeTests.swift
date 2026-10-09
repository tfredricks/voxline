import Foundation
import Testing
@testable import voxline

/// Real Core Audio tap. The first run shows macOS's System Audio Recording
/// prompt; allow it and rerun.
/// `TEST_RUNNER_VOXLINE_SYSTEM_TAP_SMOKE=1 xcodebuild test ... -only-testing:voxlineTests/SystemAudioTapSmokeTests`
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOXLINE_SYSTEM_TAP_SMOKE"] == "1"))
struct SystemAudioTapSmokeTests {

    @Test @MainActor func tap_hears_a_system_sound() async throws {
        let peak = LockedBox<Float>(0)
        let count = LockedBox<Int>(0)
        let tap = SystemAudioTap()
        try tap.start(onSamples: { samples in
            peak.mutate { $0 = max($0, AudioFormat.peakLevel(samples: samples)) }
            count.mutate { $0 += samples.count }
        }, onFailure: { _ in })

        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["/System/Library/Sounds/Glass.aiff"]
        try player.run()
        try await Task.sleep(for: .seconds(2))
        tap.stop()

        #expect(count.read() > 16_000)
        #expect(peak.read() > 0.02)
    }
}
