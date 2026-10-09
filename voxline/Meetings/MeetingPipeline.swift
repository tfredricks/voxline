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
        let outcome = await run(id)
        await transcriber.release()
        await diarizer.release()
        return outcome
    }

    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    private func run(_ id: UUID) async -> MeetingOutcome {
        guard var meta = try? store.load(id) else { return .failed("This meeting's files are missing.") }
        let dir = store.directory(for: id)
        meta.state = .processing
        try? store.save(meta)
        let clock = ContinuousClock()
        let began = clock.now

        do {
            let micURL = dir.micPCM
            let systemURL = dir.systemPCM
            let (micPeak, systemPeak, sampleCount) = try await Self.offMain {
                (
                    try PCMTrackReader.peak(at: micURL),
                    try PCMTrackReader.peak(at: systemURL),
                    max(PCMTrackReader.sampleCount(at: micURL), PCMTrackReader.sampleCount(at: systemURL))
                )
            }
            if meta.durationSeconds <= 0 {
                meta.durationSeconds = Double(sampleCount) / AudioFormat.whisperSampleRate
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
            if config.modelsNeedDownload {
                onStage?(.downloadingModels)
                do {
                    try await transcriber.prepare()
                } catch {
                    throw MeetingPipelineError.transcriptionFailed(error.localizedDescription)
                }
            }

            let trackCount = (micHasSpeech ? 1 : 0) + (callMode ? 1 : 0)
            var trackIndex = 0
            var micSamples: [Float]?
            var micTranscript: TrackTranscript?
            var systemSamples: [Float]?
            var systemTranscript: TrackTranscript?
            var firstError: String?
            var micMs = 0
            var systemMs = 0

            if micHasSpeech {
                trackIndex += 1
                onStage?(.transcribing(track: trackIndex, of: trackCount))
                let samples = try await Self.offMain { try PCMTrackReader.samples(at: micURL) }
                let t0 = clock.now
                do {
                    micTranscript = try await transcriber.transcribe(samples)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                    warnings.append(Self.micMissingWarning(error.localizedDescription))
                }
                micMs = Self.milliseconds(clock.now - t0)
                if !callMode { micSamples = samples }
            }
            if callMode {
                trackIndex += 1
                onStage?(.transcribing(track: trackIndex, of: trackCount))
                let samples = try await Self.offMain { try PCMTrackReader.samples(at: systemURL) }
                let t0 = clock.now
                do {
                    systemTranscript = try await transcriber.transcribe(samples)
                } catch {
                    firstError = firstError ?? error.localizedDescription
                    warnings.append(Self.systemMissingWarning(error.localizedDescription))
                }
                systemMs = Self.milliseconds(clock.now - t0)
                systemSamples = samples
            }
            await transcriber.release()
            guard micTranscript != nil || systemTranscript != nil else {
                throw MeetingPipelineError.transcriptionFailed(firstError ?? "unknown error")
            }

            onStage?(.identifyingSpeakers)
            let diarizeStart = clock.now
            let others: [SpeakerSegmentText]
            if callMode {
                others = await diarized(systemSamples ?? [], systemTranscript, warnings: &warnings)
            } else {
                others = await diarized(micSamples ?? [], micTranscript, warnings: &warnings)
            }
            micSamples = nil
            systemSamples = nil
            await diarizer.release()
            let diarizeMs = Self.milliseconds(clock.now - diarizeStart)

            let mergeStart = clock.now
            let utterances = callMode
                ? TranscriptMerger.merge(mic: micTranscript?.segments ?? [], others: others, unattributedLabel: "Them")
                : TranscriptMerger.merge(mic: [], others: others, unattributedLabel: "Speaker")
            let mergeMs = Self.milliseconds(clock.now - mergeStart)
            guard !utterances.isEmpty else {
                if let firstError { throw MeetingPipelineError.transcriptionFailed(firstError) }
                store.delete(id)
                AppLog.meetings.info("transcript was empty; meeting discarded")
                return .nothingRecorded
            }

            try JSONEncoder().encode(MeetingTranscriptFile(utterances: utterances, warnings: warnings)).write(to: dir.transcript, options: .atomic)

            onStage?(.writingNotes)
            let notesStart = clock.now
            let (generated, failure) = await generateNotes(utterances, meta: meta, config: config)
            let notesMs = Self.milliseconds(clock.now - notesStart)
            let url = try writeNotes(
                MeetingDocument(startedAt: meta.startedAt, duration: meta.durationSeconds, utterances: utterances,
                                notes: generated, notesFailure: failure, warnings: warnings),
                startedAt: meta.startedAt, folder: config.notesFolder, suffix: nil
            )
            await finishAudio(id, retention: config.retention)

            meta.state = .done
            meta.title = generated?.title
            meta.notesPath = url.path
            meta.failureReason = nil
            try? store.save(meta)
            let speakers = Set(utterances.map(\.speaker)).count
            let transcriptTokens = utterances.reduce(0) { $0 + $1.text.utf8.count } / 4
            AppLog.meetings.info("""
                processed meeting: duration \(Int(meta.durationSeconds)) s, systemAudio \(callMode), \
                transcribeMic \(micMs) ms, transcribeSystem \(systemMs) ms, diarize \(diarizeMs) ms, merge \(mergeMs) ms, notes \(notesMs) ms, \
                speakers \(speakers), transcriptTokens ~\(transcriptTokens), notes \(generated == nil ? "failed" : "ok", privacy: .public), \
                total \(clock.now - began, privacy: .public)
                """)
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
        guard let generated else { return .failed(failure ?? "Notes could not be generated.") }
        do {
            let url = try writeNotes(
                MeetingDocument(startedAt: meta.startedAt, duration: meta.durationSeconds, utterances: file.utterances,
                                notes: generated, notesFailure: nil, warnings: file.warnings),
                startedAt: meta.startedAt, folder: config.notesFolder, suffix: "regenerated"
            )
            meta.title = generated.title
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
            try await diarizer.prepare()
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

    private func finishAudio(_ id: UUID, retention: MeetingAudioRetention) async {
        guard retention.keepsAudio else {
            store.deleteAudio(id)
            return
        }
        let dir = store.directory(for: id)
        let transcoder = transcoder
        for (pcm, m4a) in [(dir.micPCM, dir.micM4A), (dir.systemPCM, dir.systemM4A)] {
            do {
                let transcoded = try await Self.offMain {
                    guard PCMTrackReader.sampleCount(at: pcm) > 0 else { return false }
                    try transcoder.transcode(pcm: pcm, to: m4a)
                    return true
                }
                if transcoded { try? FileManager.default.removeItem(at: pcm) }
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
