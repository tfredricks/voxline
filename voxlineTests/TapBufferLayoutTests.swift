@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct TapBufferLayoutTests {

    private static let interleavedStereo = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
    )!
    private static let planarStereo = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
    )!

    /// Builds an input list from `(channels, samples)` pairs, one per buffer,
    /// and hands it to `body`.
    private func withInput<R>(_ buffers: [(UInt32, [Float])], _ body: (UnsafePointer<AudioBufferList>) -> R) -> R {
        let list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        var storage: [UnsafeMutablePointer<Float>] = []
        for (index, (channels, samples)) in buffers.enumerated() {
            let memory = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            memory.initialize(from: samples, count: samples.count)
            storage.append(memory)
            list[index] = AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(memory)
            )
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        return body(list.unsafePointer)
    }

    private func interleavedSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let audio = buffer.audioBufferList.pointee.mBuffers
        let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: audio.mData!.assumingMemoryBound(to: Float.self), count: count))
    }

    @Test func picks_the_tap_buffer_after_a_headset_mic_stream() throws {
        let layout = TapBufferLayout(format: Self.interleavedStereo, leadingBuffers: 1)
        let mic: [Float] = [9, 9, 9]
        let tap: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        let buffer = try #require(withInput([(1, mic), (2, tap)]) { layout.tapAudio(in: $0) })
        #expect(buffer.frameLength == 3)
        #expect(interleavedSamples(buffer) == tap)
    }

    @Test func reads_a_tap_only_list() throws {
        let layout = TapBufferLayout(format: Self.interleavedStereo, leadingBuffers: 0)
        let tap: [Float] = [0.1, -0.1, 0.2, -0.2]
        let buffer = try #require(withInput([(2, tap)]) { layout.tapAudio(in: $0) })
        #expect(buffer.frameLength == 2)
        #expect(interleavedSamples(buffer) == tap)
    }

    @Test func picks_planar_tap_buffers_after_the_device_streams() throws {
        let layout = TapBufferLayout(format: Self.planarStereo, leadingBuffers: 1)
        let left: [Float] = [0.1, 0.2]
        let right: [Float] = [0.3, 0.4]
        let buffer = try #require(withInput([(1, [9, 9]), (1, left), (1, right)]) { layout.tapAudio(in: $0) })
        let channels = try #require(buffer.floatChannelData)
        #expect(buffer.frameLength == 2)
        #expect(Array(UnsafeBufferPointer(start: channels[0], count: 2)) == left)
        #expect(Array(UnsafeBufferPointer(start: channels[1], count: 2)) == right)
    }

    @Test func rejects_an_unexpected_buffer_count() {
        let layout = TapBufferLayout(format: Self.interleavedStereo, leadingBuffers: 0)
        let result = withInput([(1, [9, 9]), (2, [0.1, 0.2])]) { layout.tapAudio(in: $0) }
        #expect(result == nil)
    }

    @Test func rejects_a_channel_count_mismatch() {
        let layout = TapBufferLayout(format: Self.interleavedStereo, leadingBuffers: 1)
        let result = withInput([(2, [9, 9]), (1, [0.1, 0.2])]) { layout.tapAudio(in: $0) }
        #expect(result == nil)
    }
}
