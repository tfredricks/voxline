import Testing
import Foundation
@preconcurrency import AVFoundation
@testable import voxline

/// Tag for slow live integration tests. Re-declared here because the
/// original declaration lived in the deleted VocabPipelineIntegrationTests.
extension Tag {
    @Tag static var integration: Self
}

/// Live end-to-end integration test for the cleanup-layer vocab biasing
/// path. Synthesized speech runs through the real `TranscriptionService`
/// (WhisperKit) and then through the real `LLMService.cleanup` against the
/// configured provider's live API. Skips with a printed `[integration]`
/// note when the WhisperKit model is not cached locally OR the configured
/// provider's API key is missing from the Keychain.
///
/// See `docs/superpowers/specs/2026-05-12-vocab-cleanup-only-pivot-design.md`
/// for context on why the Whisper-prompt biasing channel was removed.
///
/// Disabled by default: live-API tests are environment-dependent (model
/// cache present, network reachable, provider credentials accepted) and
/// flake the green-suite invariant when any of those conditions slip. Opt
/// in by setting `VOXLINE_RUN_INTEGRATION=1` in the test invocation's env.
/// When opted in, failures are real signals — fix the environment or the
/// code, don't add another silent skip.
@Suite(
    .tags(.integration),
    .disabled(
        if: ProcessInfo.processInfo.environment["VOXLINE_RUN_INTEGRATION"] == nil,
        "Set VOXLINE_RUN_INTEGRATION=1 to run live integration tests."
    )
)
@MainActor
struct VocabCleanupIntegrationTests {

    private enum IntegrationError: Error {
        case targetFormatUnavailable
        case converterUnavailable
        case conversionFailed(NSError?)
        case emptyAudio
        case voiceUnavailable
    }

    /// Phrase designed to produce phonetic near-misses for three vocab terms.
    /// 'lang graph' and 'arg max' exercise casing/concatenation; 'vox line'
    /// exercises the word-segmentation path (Whisper-on-synth-speech reliably
    /// renders the user's app name as two words) which is the case the spec's
    /// first worked example was written to cover.
    private static let phrase = "Please use lang graph, arg max, and vox line in the daily report"

    @Test
    func cleanup_normalizes_phonetic_misses_to_canonical_terms() async throws {
        guard try await Self.modelIsAvailable() else { return }
        guard try Self.providerKeyIsAvailable() else { return }

        // 1. Real Whisper transcription on synthesized audio.
        let service = TranscriptionService(model: .default)
        try await service.prewarm()
        let samples = try await Self.synthesizeSpeechSamples(Self.phrase)
        let transcript = try await service.transcribe(samples: samples)
        #expect(transcript.count > 5, "expected non-empty raw transcript, got '\(transcript)'")
        print("[integration] transcript=\(transcript)")

        // 2. Real LLM cleanup with vocab injected via CapturedContext.
        let settings = AppSettings()
        let llm = LLMService(settings: settings)
        var context = CapturedContext.empty
        context.customVocabulary = ["LangGraph", "Argmax", "Voxline"]
        let mode = Mode(
            bundleID: "*",
            displayName: "Test",
            prompt: "Concise. Preserve the speaker's word choice.",
            model: nil,
            temperature: 0.0,
            fieldKind: nil
        )
        let cleaned = try await llm.cleanup(transcript: transcript, mode: mode, context: context, refinement: nil)
        print("[integration] cleaned=\(cleaned)")

        // 3. The cleanup preamble (LLMService.transcriptionPreamble) instructs
        // the model to snap phonetic near-misses to the canonical spelling.
        // We assert case-sensitively on all three canonical terms.
        #expect(cleaned.contains("LangGraph"),
                "expected cleaned output to contain canonical 'LangGraph'; got '\(cleaned)'")
        #expect(cleaned.contains("Argmax"),
                "expected cleaned output to contain canonical 'Argmax'; got '\(cleaned)'")
        #expect(cleaned.contains("Voxline"),
                "expected cleaned output to contain canonical 'Voxline'; got '\(cleaned)'")
    }

    // MARK: - Skip gates

    private static func modelIsAvailable() async throws -> Bool {
        if TranscriptionService.isModelCached(.default) {
            return true
        }
        print("[integration] skipping VocabCleanupIntegrationTests — WhisperKit model not cached. Run the app once to download the default model and re-run.")
        return false
    }

    /// Returns true if the configured provider's Keychain key is present.
    /// Otherwise prints a skip note and returns false. Matches `LLMService`'s
    /// production resolution: read `AppSettings.llmProvider`, look up the
    /// matching account.
    private static func providerKeyIsAvailable() throws -> Bool {
        let settings = AppSettings()
        let provider = settings.llmProvider
        let account: String
        switch provider {
        case .anthropic: account = KeychainAccount.anthropic
        case .openai:    account = KeychainAccount.openai
        }
        let key = try DataProtectionKeychain().string(forKey: account)
        if let key, !key.isEmpty {
            return true
        }
        print("[integration] skipping VocabCleanupIntegrationTests — no API key in Keychain for provider \(provider). Add a key in Settings → API Keys.")
        return false
    }

    // MARK: - Audio synthesis

    /// Synthesizes `text` via AVSpeechSynthesizer and resamples the result to
    /// 16 kHz mono Float32 — Whisper's expected input format. See the
    /// callback contract: the write block delivers a sequence of PCM buffers
    /// terminated by an empty (frameLength == 0) buffer.
    /// https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
    @MainActor
    private static func synthesizeSpeechSamples(_ text: String) async throws -> [Float] {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.en-US.Samantha")
            ?? AVSpeechSynthesisVoice.speechVoices().first { $0.language.hasPrefix("en") }
        guard utterance.voice != nil else {
            throw IntegrationError.voiceUnavailable
        }

        final class Box: @unchecked Sendable {
            var buffers: [AVAudioPCMBuffer] = []
            var resumed = false
        }
        let box = Box()

        let samples: [Float] = try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard !box.resumed else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    box.resumed = true
                    do {
                        let out = try resampleToWhisper(box.buffers)
                        continuation.resume(returning: out)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                    return
                }
                if let copy = pcm.deepCopy() {
                    box.buffers.append(copy)
                } else {
                    box.buffers.append(pcm)
                }
            }
        }

        guard !samples.isEmpty else { throw IntegrationError.emptyAudio }
        _ = synthesizer
        return samples
    }

    /// Concatenates the synthesizer's PCM buffers and converts to 16 kHz
    /// mono Float32. Mirrors the converter shape used in `AudioCaptureService`.
    private static func resampleToWhisper(_ buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        guard let first = buffers.first else { return [] }
        let sourceFormat = first.format
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.whisperSampleRate,
            channels: AudioFormat.whisperChannelCount,
            interleaved: false
        ) else {
            throw IntegrationError.targetFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw IntegrationError.converterUnavailable
        }

        let totalFrames = buffers.reduce(AVAudioFrameCount(0)) { $0 + $1.frameLength }
        guard totalFrames > 0,
              let combined = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalFrames) else {
            throw IntegrationError.emptyAudio
        }
        combined.frameLength = 0
        for buffer in buffers {
            appendBuffer(buffer, into: combined)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(combined.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw IntegrationError.converterUnavailable
        }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return combined
        }

        guard status != .error, error == nil, let channel = outBuffer.floatChannelData?[0] else {
            throw IntegrationError.conversionFailed(error)
        }
        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    private static func appendBuffer(_ src: AVAudioPCMBuffer, into dst: AVAudioPCMBuffer) {
        let frames = src.frameLength
        guard frames > 0, dst.frameCapacity - dst.frameLength >= frames else { return }
        let channels = Int(src.format.channelCount)
        let bytesPerFrame = Int(src.format.streamDescription.pointee.mBytesPerFrame)
        let bytesPerChannelFrame = bytesPerFrame / max(1, channels)
        if let srcFloats = src.floatChannelData, let dstFloats = dst.floatChannelData {
            for ch in 0..<channels {
                let srcPtr = srcFloats[ch]
                let dstPtr = dstFloats[ch].advanced(by: Int(dst.frameLength))
                dstPtr.update(from: srcPtr, count: Int(frames))
            }
        } else if let srcInts = src.int16ChannelData, let dstInts = dst.int16ChannelData {
            for ch in 0..<channels {
                let srcPtr = srcInts[ch]
                let dstPtr = dstInts[ch].advanced(by: Int(dst.frameLength))
                dstPtr.update(from: srcPtr, count: Int(frames))
            }
        } else {
            let srcList = src.audioBufferList.pointee
            let dstList = dst.mutableAudioBufferList.pointee
            if let sData = srcList.mBuffers.mData, let dData = dstList.mBuffers.mData {
                let offset = Int(dst.frameLength) * bytesPerChannelFrame * channels
                memcpy(dData.advanced(by: offset), sData, Int(frames) * bytesPerFrame)
            }
        }
        dst.frameLength += frames
    }
}

private extension AVAudioPCMBuffer {
    /// Returns an independent buffer with the same format and frame
    /// contents. AVSpeechSynthesizer may reuse its internal buffer across
    /// callbacks, so we copy on every delivery.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            return nil
        }
        copy.frameLength = frameLength
        let channels = Int(format.channelCount)
        if let srcFloats = floatChannelData, let dstFloats = copy.floatChannelData {
            for ch in 0..<channels {
                dstFloats[ch].update(from: srcFloats[ch], count: Int(frameLength))
            }
            return copy
        }
        if let srcInts = int16ChannelData, let dstInts = copy.int16ChannelData {
            for ch in 0..<channels {
                dstInts[ch].update(from: srcInts[ch], count: Int(frameLength))
            }
            return copy
        }
        return nil
    }
}
