import Testing
import Foundation
@testable import voxline

@Suite struct AudioFormatTests {

    @Test func whisperInputFormatIs16kHzMonoFloat() {
        #expect(AudioFormat.whisperSampleRate == 16_000)
        #expect(AudioFormat.whisperChannelCount == 1)
    }

    @Test func levelOfSilenceIsZero() {
        let silence = [Float](repeating: 0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: silence) == 0)
    }

    @Test func levelOfFullScaleIsOne() {
        let full = [Float](repeating: 1.0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: full) == 1.0)
    }

    @Test func levelOfNegativeFullScaleIsOne() {
        // Peak is absolute value.
        let negFull = [Float](repeating: -1.0, count: 1024)
        #expect(AudioFormat.peakLevel(samples: negFull) == 1.0)
    }

    @Test func levelOfEmptyArrayIsZero() {
        #expect(AudioFormat.peakLevel(samples: []) == 0)
    }
}
