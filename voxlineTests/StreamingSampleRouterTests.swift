import Testing
import Foundation
@testable import voxline

@Suite struct StreamingSampleRouterTests {

    @Test func forwards_pending_chunks_in_order_on_attach() {
        let router = StreamingSampleRouter(retainsAudio: false)
        router.append([1, 2])
        router.append([3])
        let session = FakeTranscriptionSession()
        router.attach(session)
        router.append([4])
        #expect(session.appended == [[1, 2], [3], [4]])
    }

    @Test func tallies_count_and_peak_synchronously() {
        let router = StreamingSampleRouter(retainsAudio: false)
        router.append([0.1, -0.5])
        router.append([0.2])
        #expect(router.sampleCount == 3)
        #expect(router.peak == 0.5)
    }

    @Test func peak_is_never_zero_when_nonzero_samples_were_counted() {
        let router = StreamingSampleRouter(retainsAudio: false)
        router.append([0.3])
        #expect(router.sampleCount > 0)
        #expect(router.peak > 0)
    }

    @Test func retains_audio_only_when_asked() {
        let retaining = StreamingSampleRouter(retainsAudio: true)
        retaining.append([1, 2])
        retaining.append([3])
        #expect(retaining.retainedAudio == [1, 2, 3])

        let discarding = StreamingSampleRouter(retainsAudio: false)
        discarding.append([1, 2])
        discarding.append([3])
        #expect(discarding.retainedAudio == [])
    }

    @Test func close_drops_further_input() {
        let router = StreamingSampleRouter(retainsAudio: false)
        let session = FakeTranscriptionSession()
        router.attach(session)
        router.append([1])
        router.close()
        router.append([2, 3])
        #expect(session.appended == [[1]])
        #expect(router.sampleCount == 1)
    }

    @Test func audioDuration_is_count_over_16k() {
        let router = StreamingSampleRouter(retainsAudio: false)
        router.append([Float](repeating: 0, count: 8_000))
        #expect(router.audioDuration == 0.5)
    }

    @Test func concurrent_appends_are_counted() {
        let router = StreamingSampleRouter(retainsAudio: false)
        let session = FakeTranscriptionSession()
        router.attach(session)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for _ in 0..<1_000 { router.append([0.25]) }
        }
        #expect(router.sampleCount == 8_000)
        #expect(session.appendedSampleCount == 8_000)
    }
}
