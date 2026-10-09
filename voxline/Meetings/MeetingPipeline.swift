import Foundation

enum MeetingStage: Equatable, Sendable {
    case downloadingModels
    case transcribing(track: Int, of: Int)
    case identifyingSpeakers
    case writingNotes

    var label: String {
        switch self {
        case .downloadingModels:            return "Downloading speech models…"
        case .transcribing(let n, let of):  return "Transcribing \(n)/\(of)…"
        case .identifyingSpeakers:          return "Identifying speakers…"
        case .writingNotes:                 return "Writing notes…"
        }
    }
}

enum MeetingOutcome: Equatable {
    case written(URL)
    case nothingRecorded
    case failed(String)
}

struct MeetingPipelineSettings: Sendable {
    var notesFolder: URL
    var notesModel: String
    var vocabulary: [String]
    var retention: MeetingAudioRetention
    var modelsNeedDownload: Bool
}

/// `transcript.json`: what Regenerate Notes needs.
struct MeetingTranscriptFile: Codable, Equatable {
    var utterances: [MeetingUtterance]
    var warnings: [String]
}

@MainActor
protocol MeetingProcessing: AnyObject {
    var onStage: ((MeetingStage) -> Void)? { get set }
    func process(_ id: UUID) async -> MeetingOutcome
    func regenerateNotes(_ id: UUID) async -> MeetingOutcome
}

/// Recorded tracks → transcript → notes file. Call mode (system audio
/// present) labels the mic "Me" and diarizes the system track; otherwise
/// the mic track is diarized.
@MainActor
final class MeetingPipeline: MeetingProcessing {

    static let silencePeak: Float = 0.02

    static let silentSystemWarning = "System audio was silent, so this was processed as an in-person meeting. If this was a call, allow voxline under System Settings → Privacy & Security → Screen & System Audio Recording."

    static func speakersWarning(_ reason: String) -> String { "Speakers couldn't be separated: \(reason)" }
    static func micMissingWarning(_ reason: String) -> String { "Your microphone track couldn't be transcribed: \(reason)" }
    static func systemMissingWarning(_ reason: String) -> String { "The call audio couldn't be transcribed: \(reason)" }

    var onStage: ((MeetingStage) -> Void)?

    private let store: MeetingStore
    private let transcriber: MeetingTranscribing
    private let diarizer: MeetingDiarizing
    private let notes: MeetingNotesGenerating
    private let transcoder: MeetingAudioTranscoding
    private let settings: @MainActor () -> MeetingPipelineSettings
    private let timeZone: TimeZone

    init(
        store: MeetingStore,
        transcriber: MeetingTranscribing,
        diarizer: MeetingDiarizing,
        notes: MeetingNotesGenerating,
        transcoder: MeetingAudioTranscoding,
        settings: @escaping @MainActor () -> MeetingPipelineSettings,
        timeZone: TimeZone = .current
    ) {
        self.store = store
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.notes = notes
        self.transcoder = transcoder
        self.settings = settings
        self.timeZone = timeZone
    }

    func process(_ id: UUID) async -> MeetingOutcome {
        guard var meta = try? store.load(id) else { return .failed("This meeting's files are missing.") }
        let dir = store.directory(for: id)
        meta.state = .processing
        try? store.save(meta)
        let clock = ContinuousClock()
        let began = clock.now

        do {
            let micPeak = try PCMTrackReader.peak(at: dir.micPCM)
            let systemPeak = try PCMTrackReader.peak(at: dir.systemPCM)
            if meta.durationSeconds <= 0 {
                let samples = max(PCMTrackReader.sampleCount(at: dir.micPCM), PCMTrackReader.sampleCount(at: dir.systemPCM))
                meta.durationSeconds = Double(samples) / AudioFormat.whisperSampleRate
            }
            let callMode = systemPeak >= Self.silencePeak
            let micHasSpeech = micPeak >= Self.silencePeak
            guard callMode || micHasSpeech else {
                store.delete(id)
                AppLog.meetings.info("nothing recorded; meeting discarded")
                return .nothingRecorded
            }

            let config = settings()
            var warnings: [String] = []
            if meta.systemTapStarted && systemPeak == 0 { warnings.append(Self.silentSystemWarning) }
            if config.modelsNeedDownload { onStage?(.downloadingModels) }

            let trackCount = (micHasSpeech ? 1 : 0) + (callMode ? 1 : 0)
            var trackIndex = 0
            var micSamples: [Float] = []
            var micTranscript: TrackTranscript?
            var systemSamples: [Float] = []
            var systemTranscript: TrackTranscript?
            var firstError: String?

            if micHasSpeech {
                trackIndex += 1
                onStage?(.transcribing(track: trackIndex, of: trackCount))
                micSamples = try PCMTrackReader.samples(at: dir.micPCM)
                do {
                    micTranscript = try await transcriber.transcribe(micSamples)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                    warnings.append(Self.micMissingWarning(error.localizedDescription))
                }
            }
            if callMode {
                trackIndex += 1
                onStage?(.transcribing(track: trackIndex, of: trackCount))
                systemSamples = try PCMTrackReader.samples(at: dir.systemPCM)
                do {
                    systemTranscript = try await transcriber.transcribe(systemSamples)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                    warnings.append(Self.systemMissingWarning(error.localizedDescription))
                }
            }
            await transcriber.release()
            guard micTranscript != nil || systemTranscript != nil else {
                throw MeetingPipelineError.transcriptionFailed(firstError ?? "unknown error")
            }

            onStage?(.identifyingSpeakers)
            let utterances: [MeetingUtterance]
            if callMode {
                micSamples = []
                let others = await diarized(systemSamples, systemTranscript, warnings: &warnings)
                utterances = TranscriptMerger.merge(mic: micTranscript?.segments ?? [], others: others, unattributedLabel: "Them")
            } else {
                let others = await diarized(micSamples, micTranscript, warnings: &warnings)
                utterances = TranscriptMerger.merge(mic: [], others: others, unattributedLabel: "Speaker")
            }
            await diarizer.release()
            guard !utterances.isEmpty else {
                store.delete(id)
                return .nothingRecorded
            }

            try JSONEncoder().encode(MeetingTranscriptFile(utterances: utterances, warnings: warnings)).write(to: dir.transcript, options: .atomic)

            onStage?(.writingNotes)
            let (generated, failure) = await generateNotes(utterances, meta: meta, config: config)
            let url = try writeNotes(
                MeetingDocument(startedAt: meta.startedAt, duration: meta.durationSeconds, utterances: utterances,
                                notes: generated, notesFailure: failure, warnings: warnings),
                startedAt: meta.startedAt, folder: config.notesFolder, suffix: nil
            )
            finishAudio(id, retention: config.retention)

            meta.state = .done
            meta.title = generated?.title
            meta.notesPath = url.path
            meta.failureReason = nil
            try? store.save(meta)
            AppLog.meetings.info("processed \(Int(meta.durationSeconds)) s meeting in \(clock.now - began, privacy: .public); call mode \(callMode); notes \(generated == nil ? "failed" : "ok", privacy: .public)")
            return .written(url)
        } catch {
            meta.state = .failed
            meta.failureReason = error.localizedDescription
            try? store.save(meta)
            AppLog.meetings.error("processing failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    func regenerateNotes(_ id: UUID) async -> MeetingOutcome {
        guard var meta = try? store.load(id),
              let data = try? Data(contentsOf: store.directory(for: id).transcript),
              let file = try? JSONDecoder().decode(MeetingTranscriptFile.self, from: data)
        else { return .failed("This meeting's transcript is no longer available.") }
        let config = settings()
        onStage?(.writingNotes)
        let (generated, failure) = await generateNotes(file.utterances, meta: meta, config: config)
        do {
            let url = try writeNotes(
                MeetingDocument(startedAt: meta.startedAt, duration: meta.durationSeconds, utterances: file.utterances,
                                notes: generated, notesFailure: failure, warnings: file.warnings),
                startedAt: meta.startedAt, folder: config.notesFolder, suffix: "regenerated"
            )
            if let generated { meta.title = generated.title }
            meta.notesPath = url.path
            try? store.save(meta)
            return .written(url)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func diarized(_ samples: [Float], _ transcript: TrackTranscript?, warnings: inout [String]) async -> [SpeakerSegmentText] {
        guard let transcript else { return [] }
        let unattributed = transcript.segments.map { SpeakerSegmentText(speakerID: nil, start: $0.start, end: $0.end, text: $0.text) }
        do {
            let segments = try await diarizer.diarize(samples, transcript: transcript)
            return segments.isEmpty ? unattributed : segments
        } catch {
            warnings.append(Self.speakersWarning(error.localizedDescription))
            return unattributed
        }
    }

    private func generateNotes(_ utterances: [MeetingUtterance], meta: MeetingMeta, config: MeetingPipelineSettings) async -> (MeetingNotes?, String?) {
        let request = MeetingNotesRequest(
            model: config.notesModel, utterances: utterances, startedAt: meta.startedAt,
            duration: meta.durationSeconds, vocabulary: config.vocabulary
        )
        do {
            return (try await notes.meetingNotes(request), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func writeNotes(_ document: MeetingDocument, startedAt: Date, folder: URL, suffix: String?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = MeetingFileNamer.fileName(
            startedAt: startedAt, title: document.notes?.title ?? MeetingMarkdown.untitled, suffix: suffix, timeZone: timeZone
        )
        let url = MeetingFileNamer.uniqueURL(in: folder, fileName: name) { FileManager.default.fileExists(atPath: $0.path) }
        try MeetingMarkdown.render(document, timeZone: timeZone).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func finishAudio(_ id: UUID, retention: MeetingAudioRetention) {
        guard retention.keepsAudio else {
            store.deleteAudio(id)
            return
        }
        let dir = store.directory(for: id)
        for (pcm, m4a) in [(dir.micPCM, dir.micM4A), (dir.systemPCM, dir.systemM4A)] where PCMTrackReader.sampleCount(at: pcm) > 0 {
            do {
                try transcoder.transcode(pcm: pcm, to: m4a)
                try? FileManager.default.removeItem(at: pcm)
            } catch {
                AppLog.meetings.error("transcode failed; keeping raw audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

enum MeetingPipelineError: LocalizedError {
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .transcriptionFailed(let reason): return "Transcription failed: \(reason)"
        }
    }
}
