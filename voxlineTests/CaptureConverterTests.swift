import AVFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct CaptureConverterTests {

    private func makeConverter() throws -> CaptureConverter {
        try CaptureConverter(inputFormat: try TestAudio.hardwareFormat())
    }

    private func sineBuffer(frames: AVAudioFrameCount, startingAt offset: Int = 0) throws -> AVAudioPCMBuffer {
        try TestAudio.sineBuffer(frames: frames, startingAt: offset)
    }

    @Test func converts_48k_to_16k_at_one_third_rate() throws {
        let converter = try makeConverter()
        var total = 0
        for index in 0..<10 {
            total += converter.convert(try sineBuffer(frames: 4_800, startingAt: index * 4_800)).count
        }
        total += converter.flushAndClose().count
        #expect(abs(total - 16_000) <= 32)
    }

    @Test func convert_keeps_pace_with_input() throws {
        let converter = try makeConverter()
        var produced = 0
        for index in 0..<10 {
            produced += converter.convert(try sineBuffer(frames: 4_800, startingAt: index * 4_800)).count
            #expect((index + 1) * 1_600 - produced <= 32, "held back after buffer \(index)")
        }
    }

    @Test func output_does_not_depend_on_tap_buffer_size() throws {
        func convertOneSecond(inBuffersOf frames: Int) throws -> [Float] {
            let converter = try makeConverter()
            var output: [Float] = []
            for index in 0..<(48_000 / frames) {
                output += converter.convert(
                    try sineBuffer(frames: AVAudioFrameCount(frames), startingAt: index * frames)
                )
            }
            return output + converter.flushAndClose()
        }
        let large = try convertOneSecond(inBuffersOf: 4_800)
        let small = try convertOneSecond(inBuffersOf: 960)
        #expect(large.count == small.count)
        #expect(large == small)
    }

    @Test func flush_returns_the_converter_tail() throws {
        let converter = try makeConverter()
        let convertedCount = converter.convert(try sineBuffer(frames: 4_800)).count
        let flushedCount = converter.flushAndClose().count
        #expect(flushedCount > 0 || convertedCount >= 1_580)
        #expect(convertedCount + flushedCount >= 1_590)
    }

    @Test func convert_after_close_returns_empty() throws {
        let converter = try makeConverter()
        _ = converter.convert(try sineBuffer(frames: 4_800))
        _ = converter.flushAndClose()
        #expect(converter.convert(try sineBuffer(frames: 4_800, startingAt: 4_800)).isEmpty)
    }

    @Test func a_multichannel_input_is_mixed_so_a_mic_on_input_two_is_heard() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: TestAudio.hardwareRate, channels: 2))
        let converter = try CaptureConverter(inputFormat: format)
        let mono = try sineBuffer(frames: 4_800)
        let stereo = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        stereo.frameLength = 4_800
        let left = try #require(stereo.floatChannelData?[0])
        let right = try #require(stereo.floatChannelData?[1])
        let signal = try #require(mono.floatChannelData?[0])
        for i in 0..<4_800 {
            left[i] = 0
            right[i] = signal[i]
        }

        let output = converter.convert(stereo) + converter.flushAndClose()

        #expect(!output.isEmpty)
        #expect(AudioFormat.peakLevel(samples: output) > 0.1)
    }

    @Test func flush_twice_returns_empty_second_time() throws {
        let converter = try makeConverter()
        _ = converter.convert(try sineBuffer(frames: 4_800))
        _ = converter.flushAndClose()
        #expect(converter.flushAndClose().isEmpty)
    }
}
