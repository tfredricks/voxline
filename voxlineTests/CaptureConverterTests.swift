import AVFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct CaptureConverterTests {

    private static let hardwareRate: Double = 48_000

    private func makeConverter() throws -> CaptureConverter {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.hardwareRate, channels: 1))
        return try CaptureConverter(inputFormat: format)
    }

    private func sineBuffer(frames: AVAudioFrameCount, startingAt offset: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.hardwareRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            let t = Double(offset + i) / Self.hardwareRate
            channel[i] = Float(0.5 * sin(2 * Double.pi * 440 * t))
        }
        return buffer
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

    @Test func flush_twice_returns_empty_second_time() throws {
        let converter = try makeConverter()
        _ = converter.convert(try sineBuffer(frames: 4_800))
        _ = converter.flushAndClose()
        #expect(converter.flushAndClose().isEmpty)
    }
}
