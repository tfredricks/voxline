import Foundation

/// Appends 16 kHz mono samples to a headerless Int16 little-endian file.
/// Every append is written through before it returns, so a crash loses
/// nothing already appended. Safe to call from any thread. After the first
/// write error, later writes are ignored and `onFailure` has fired once.
final class PCMTrackWriter: @unchecked Sendable {

    private let lock = NSLock()
    private let handle: FileHandle
    private let onFailure: @Sendable (Error) -> Void
    private let performWrite: @Sendable (FileHandle, Data) throws -> Void
    private var count: Int
    private var maxPeak: Float = 0
    private var failed = false
    private var closed = false

    init(
        url: URL,
        onFailure: @escaping @Sendable (Error) -> Void = { _ in },
        write: @escaping @Sendable (FileHandle, Data) throws -> Void = { try $0.write(contentsOf: $1) }
    ) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
        }
        handle = try FileHandle(forWritingTo: url)
        let size = Int(try handle.seekToEnd())
        count = size / 2
        if size % 2 != 0 {
            try handle.truncate(atOffset: UInt64(count * 2))
            try handle.seek(toOffset: UInt64(count * 2))
        }
        self.onFailure = onFailure
        self.performWrite = write
    }

    var sampleCount: Int { lock.withLock { count } }
    var peak: Float { lock.withLock { maxPeak } }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                out[i] = Int16((sample.isNaN ? 0 : max(-1, min(1, sample)) * 32_767).rounded()).littleEndian
            }
        }
        write { _ in (data, samples.count, AudioFormat.peakLevel(samples: samples)) }
    }

    func padSilence(toSampleCount target: Int) {
        write { current in
            let missing = target - current
            return missing > 0 ? (Data(count: missing * 2), missing, 0) : nil
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            try? handle.close()
        }
    }

    private func write(_ make: (Int) -> (Data, Int, Float)?) {
        let error: Error? = lock.withLock {
            guard !failed, !closed, let chunk = make(count) else { return nil }
            let (data, samples, peak) = chunk
            do {
                try performWrite(handle, data)
                count += samples
                maxPeak = max(maxPeak, peak)
                return nil
            } catch {
                failed = true
                return error
            }
        }
        if let error {
            AppLog.meetings.error("track write failed: \(error.localizedDescription, privacy: .public)")
            onFailure(error)
        }
    }
}

enum PCMTrackReader {

    static func sampleCount(at url: URL) -> Int {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
        return size / 2
    }

    static func samples(at url: URL) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(sampleCount(at: url))
        try forEachChunk(at: url, chunkSamples: 1_600_000) { out += $0 }
        return out
    }

    static func peak(at url: URL) throws -> Float {
        var peak: Float = 0
        try forEachChunk(at: url, chunkSamples: 1_600_000) { peak = max(peak, AudioFormat.peakLevel(samples: $0)) }
        return peak
    }

    static func forEachChunk(at url: URL, chunkSamples: Int, _ body: ([Float]) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: chunkSamples * 2), !data.isEmpty {
            let samples = data.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_767 }
            }
            if !samples.isEmpty { try body(samples) }
        }
    }
}
