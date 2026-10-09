import AVFoundation
import Foundation
import Testing
@testable import voxline

@Suite struct SampleDeliveryTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[Float]] = []
        var chunks: [[Float]] { lock.withLock { recorded } }
        func record(_ chunk: [Float]) { lock.withLock { recorded.append(chunk) } }
    }

    private func makeDelivery(recorder: Recorder) throws -> SampleDelivery {
        SampleDelivery(
            converter: try CaptureConverter(inputFormat: try TestAudio.hardwareFormat()),
            onSamples: { recorder.record($0) }
        )
    }

    @Test func delivers_chunks_in_order_with_the_tail_last() throws {
        let recorder = Recorder()
        let delivery = try makeDelivery(recorder: recorder)
        var expected: [[Float]] = []
        for index in 0..<5 {
            let chunk = delivery.deliver(try TestAudio.sineBuffer(frames: 4_800, startingAt: index * 4_800))
            if !chunk.isEmpty { expected.append(chunk) }
        }
        let tail = delivery.deliverTail()
        try #require(!tail.isEmpty)
        expected.append(tail)

        #expect(recorder.chunks == expected)
        #expect(recorder.chunks.last == tail)
    }

    @Test func deliver_after_the_tail_is_a_no_op() throws {
        let recorder = Recorder()
        let delivery = try makeDelivery(recorder: recorder)
        _ = delivery.deliver(try TestAudio.sineBuffer(frames: 4_800))
        delivery.deliverTail()
        let deliveredBefore = recorder.chunks.count

        #expect(delivery.deliver(try TestAudio.sineBuffer(frames: 4_800, startingAt: 4_800)).isEmpty)
        #expect(delivery.deliverTail().isEmpty)
        #expect(recorder.chunks.count == deliveredBefore)
    }
}
