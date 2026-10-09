import Foundation
import Testing
@testable import voxline

@Suite struct PCMTrackIOTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).pcm")
    }

    @Test func round_trips_samples_within_int16_precision() throws {
        let url = tempURL()
        let writer = try PCMTrackWriter(url: url)
        writer.append([0, 0.5, -0.5, 1, -1, 2])
        writer.close()
        let read = try PCMTrackReader.samples(at: url)
        #expect(read.count == 6)
        for (a, b) in zip(read, [0, 0.5, -0.5, 1, -1, 1] as [Float]) {
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test func tracks_count_and_peak() throws {
        let writer = try PCMTrackWriter(url: tempURL())
        writer.append([0.1, -0.4])
        writer.append([0.2])
        #expect(writer.sampleCount == 3)
        #expect(abs(writer.peak - 0.4) < 0.0001)
    }

    @Test func pads_silence_up_to_target_only() throws {
        let url = tempURL()
        let writer = try PCMTrackWriter(url: url)
        writer.append([0.5, 0.5])
        writer.padSilence(toSampleCount: 5)
        writer.padSilence(toSampleCount: 3)
        writer.close()
        #expect(try PCMTrackReader.samples(at: url).count == 5)
    }

    @Test func reopening_appends() throws {
        let url = tempURL()
        let first = try PCMTrackWriter(url: url)
        first.append([0.1, 0.1])
        first.close()
        let second = try PCMTrackWriter(url: url)
        #expect(second.sampleCount == 2)
        second.append([0.2])
        second.close()
        #expect(PCMTrackReader.sampleCount(at: url) == 3)
    }

    @Test func missing_file_reads_empty() throws {
        let url = tempURL()
        #expect(try PCMTrackReader.samples(at: url).isEmpty)
        #expect(try PCMTrackReader.peak(at: url) == 0)
        #expect(PCMTrackReader.sampleCount(at: url) == 0)
    }

    @Test func chunks_cover_the_file() throws {
        let url = tempURL()
        let writer = try PCMTrackWriter(url: url)
        writer.append([Float](repeating: 0.25, count: 10))
        writer.close()
        var sizes: [Int] = []
        try PCMTrackReader.forEachChunk(at: url, chunkSamples: 4) { sizes.append($0.count) }
        #expect(sizes == [4, 4, 2])
    }
}
