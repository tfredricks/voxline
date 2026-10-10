import Foundation
import Testing
@testable import voxline

@Suite struct AudioCaptureErrorTests {

    @Test func a_mac_with_no_microphone_gets_a_plain_message() {
        #expect(AudioCaptureError.noInputDevice.localizedDescription == "No microphone input is available.")
    }

    @Test func format_failures_say_what_went_wrong() {
        #expect(AudioCaptureError.cannotConvertFormat.localizedDescription == "The microphone's audio format isn't supported.")
        #expect(AudioCaptureError.targetFormatUnavailable.localizedDescription == "Couldn't set up audio conversion.")
    }
}
