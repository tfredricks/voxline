@preconcurrency import AVFoundation
import Foundation

/// Resamples hardware-rate input to Whisper's format (16 kHz mono Float32).
///
/// Safe to call from the tap thread and the main actor at the same time: every
/// conversion runs under one lock, so the underlying AVAudioConverter is never
/// used concurrently. `flushAndClose()` ends the stream; afterwards both methods
/// return [] and a new converter is needed for the next capture.
final class CaptureConverter: @unchecked Sendable {

    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private var isClosed = false
    private var hasLoggedConversionError = false

    init(inputFormat: AVAudioFormat) throws {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw AudioCaptureError.targetFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: target) else {
            throw AudioCaptureError.cannotConvertFormat
        }
        self.converter = converter
        self.target = target
    }

    /// Converts one hardware buffer and returns everything the resampler can
    /// emit for it; only the filter's few frames of look-ahead wait for the
    /// next call or for `flushAndClose()`. Returns [] once closed.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.withLock {
            guard !isClosed else { return [] }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
            var converted: [Float] = []
            var offset: AVAudioFrameCount = 0
            while let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) {
                var error: NSError?
                // The converter parks any frames beyond the count it asks for
                // and only works them off when later input arrives, so handing
                // over a whole 100 ms tap buffer leaves up to ~70 ms stuck
                // inside it. Hand the buffer over in slices no larger than each
                // request instead.
                let status = converter.convert(to: output, error: &error) { requested, statusOut in
                    guard let slice = Self.slice(of: buffer, from: offset, maxFrames: requested) else {
                        // Must be .noDataNow, never .endOfStream. .endOfStream
                        // permanently terminates the converter's stream and every
                        // subsequent convert() call (i.e. every later tap buffer)
                        // silently fails.
                        statusOut.pointee = .noDataNow
                        return nil
                    }
                    offset += slice.frameLength
                    statusOut.pointee = .haveData
                    return slice
                }
                if status == .error {
                    if !hasLoggedConversionError {
                        hasLoggedConversionError = true
                        AppLog.audio.error("audio conversion failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                    }
                    break
                }
                converted.append(contentsOf: Self.samples(in: output))
                guard status == .haveData, output.frameLength == output.frameCapacity else { break }
            }
            return converted
        }
    }

    /// Ends the stream and returns every frame the resampler was still
    /// holding. Calling it again returns [].
    func flushAndClose() -> [Float] {
        lock.withLock {
            guard !isClosed else { return [] }
            isClosed = true
            var tail: [Float] = []
            while let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 1024) {
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, statusOut in
                    statusOut.pointee = .endOfStream
                    return nil
                }
                if status == .error {
                    AppLog.audio.error("audio converter flush failed: \(error?.localizedDescription ?? "unknown error", privacy: .public)")
                    break
                }
                tail.append(contentsOf: Self.samples(in: output))
                if status == .endOfStream || output.frameLength == 0 {
                    break
                }
            }
            return tail
        }
    }

    private static func slice(
        of buffer: AVAudioPCMBuffer,
        from offset: AVAudioFrameCount,
        maxFrames: AVAudioPacketCount
    ) -> AVAudioPCMBuffer? {
        guard offset < buffer.frameLength, maxFrames > 0 else { return nil }
        let count = min(maxFrames, buffer.frameLength - offset)
        if offset == 0 && count == buffer.frameLength { return buffer }
        guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
            return nil
        }
        slice.frameLength = count
        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let src = from.mData, let dst = to.mData else { return nil }
            memcpy(dst, src.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
        }
        return slice
    }

    private static func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
