import AppKit
import Foundation

/// Why a capture was cancelled. `.shortcut` is the hotkey's silent discard of
/// a chord that turned out to start an OS shortcut.
enum CancelReason: Equatable, Sendable {
    case user, shortcut
}

/// Coordinates the hotkey → audio capture → streaming transcription → LLM
/// cleanup → text insert pipeline. Updates AppState along the way.
@MainActor
final class CapturePipeline {

    /// Recordings shorter than this end quietly, as a tap rather than speech.
    static let minimumAudioDuration: TimeInterval = 0.3

    /// The cloud fallback feeds retained audio to the on-device session in
    /// one-second chunks.
    static let fallbackChunkSamples = 16_000

    let state: AppState
    private let capture: AudioCapturing
    private let engines: TranscriptionEngineProviding
    let llm: LLMServing
    var modes: ModeRouter
    private let frontmost: FrontmostAppProviding
    private let fieldInspector: FocusedFieldInspecting
    let inserter: TextInserting
    let historyStore: DictationHistoryStore
    private let contextCapture: ContextCapturing
    /// The Cmd+C fallback behind `editContextReader`, for selections AX
    /// can't read.
    let selectionSnapshot: SelectionSnapshotting
    let editContextReader: EditContextReading
    let now: @Sendable () -> Date
    let metrics: DictationMetricsStore
    let llmModelID: @Sendable () -> String
    /// Commands use this model when set, else `llmModelID`.
    let commandModelID: @Sendable () -> String?
    let vocabulary: @Sendable () -> [String]
    private let skipShortUtterances: @Sendable () -> Bool
    /// Read at insert time; the release gate waits on the trigger's modifiers.
    let chords: @Sendable () -> ChordSet
    /// Holds the Cmd+C fallback until the trigger's modifiers are released.
    let releaseGate: ModifierReleaseGate
    /// Read at recording start. Off by default in a test host, so the suite
    /// never saves clips into the developer's real bake-off folder.
    private let saveBakeoffClips: @Sendable () -> Bool
    private let bakeoffClipSink: @Sendable (_ samples: [Float], _ reference: String) -> Void
    /// Told when a capture starts and when a dictation lands. Nil in tests
    /// that don't exercise Learning.
    let learning: (any LearningObserving)?

    /// Identifies the current recording or retry; `cancel()` bumps it too.
    /// Work resuming after an `await` compares it with the value it captured
    /// and drops its result when a cancel or a newer run has taken over.
    private(set) var generation: UInt64 = 0
    /// True from a recording's start until it is finalized or discarded.
    /// Owned here: `state.status` is written by others too, such as a
    /// permissions error landing mid-recording.
    private var isRecording = false
    /// `generation` as the last recording started. A preset or retry runs
    /// under a newer one.
    private var recordingGeneration: UInt64?
    private var live: LiveSession?
    private var startTasks: StartTasks?
    /// The command recording's EditContext and Cmd+C fallback, started at
    /// release. `cancel()` cancels it so a cancelled run stops waiting on
    /// the release gate and never force-clears modifiers.
    private var copyFallbackTask: Task<Result<ResolvedEditContext, EditContextRefusal>, Never>?
    /// The finalize or retry in flight, and the signal its caller awaits.
    /// `cancel()` cancels the one and fires the other, so the caller returns
    /// at once even when the engine or the provider ignores cancellation.
    private var finalizeWork: Task<Void, Never>?
    private var finalizeDone: OneShotSignal?
    /// Raw transcript of the dictation or retry being cleaned up, with the
    /// mode and context `cancel()` files it in history under.
    private var cancellableDictation: (transcript: String, mode: Mode, context: CapturedContext)?
    /// The previous run's transcripts, scrubbed from state at recording
    /// start. A silent `.shortcut` discard of the recording puts them back,
    /// since nothing was dictated; finalizing the recording drops them.
    private var scrubbedTranscripts: (last: String?, cleaned: String?, retry: String?)?

    /// True from `cancel()` until a `startRecording` that isn't refused, so
    /// the chord release that follows an Esc can skip the stop sound.
    private(set) var wasCancelled = false

    /// Fires on the main actor once the first audio of a recording has been
    /// captured, while it is still recording: the moment a start cue is
    /// honest. Never fires for a recording that failed to start.
    var onRecordingStarted: (() -> Void)?

    /// Set when the recording cap stopped the current recording. The finalize
    /// that follows says so once it ends, unless it showed a toast of its own.
    var capHit = false

    /// The pipeline's one copy path: the raw transcript when LLM cleanup
    /// fails, and the text when it can't be inserted. The default writes the
    /// general pasteboard through `PasteboardWriter.writeHinted`, whose hint
    /// types keep clipboard managers from archiving it (dictated speech can
    /// be sensitive). Settable so tests observe without touching
    /// NSPasteboard.general.
    var transcriptFallback: (String) -> Void = { text in
        PasteboardWriter.writeHinted(text)
    }

    init(
        state: AppState,
        capture: AudioCapturing,
        engines: TranscriptionEngineProviding,
        llm: LLMServing,
        modes: ModeRouter,
        frontmost: FrontmostAppProviding,
        fieldInspector: FocusedFieldInspecting,
        inserter: TextInserting,
        historyStore: DictationHistoryStore,
        contextCapture: ContextCapturing,
        selectionSnapshot: SelectionSnapshotting = DefaultSelectionSnapshot(),
        editContextReader: EditContextReading = EditContextReader(),
        metrics: DictationMetricsStore = DictationMetricsStore(),
        llmModelID: @escaping @Sendable () -> String = { AppSettings().llmModel },
        commandModelID: @escaping @Sendable () -> String? = { AppSettings().commandModel },
        vocabulary: @escaping @Sendable () -> [String] = { CustomVocabularyStore().load() },
        skipShortUtterances: @escaping @Sendable () -> Bool = { AppSettings().skipShortUtterances },
        chords: @escaping @Sendable () -> ChordSet = { AppSettings().chords },
        releaseGate: ModifierReleaseGate = ModifierReleaseGate(),
        saveBakeoffClips: @escaping @Sendable () -> Bool = { !LaunchEnvironment.isRunningTests && AppSettings().saveBakeoffClips },
        bakeoffClipSink: @escaping @Sendable (_ samples: [Float], _ reference: String) -> Void = { CapturePipeline.writeBakeoffClip($0, reference: $1) },
        learning: (any LearningObserving)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.state = state
        self.capture = capture
        self.engines = engines
        self.llm = llm
        self.modes = modes
        self.frontmost = frontmost
        self.fieldInspector = fieldInspector
        self.inserter = inserter
        self.historyStore = historyStore
        self.contextCapture = contextCapture
        self.selectionSnapshot = selectionSnapshot
        self.editContextReader = editContextReader
        self.metrics = metrics
        self.llmModelID = llmModelID
        self.commandModelID = commandModelID
        self.vocabulary = vocabulary
        self.skipShortUtterances = skipShortUtterances
        self.chords = chords
        self.releaseGate = releaseGate
        self.saveBakeoffClips = saveBakeoffClips
        self.bakeoffClipSink = bakeoffClipSink
        self.learning = learning
        self.now = now

        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                self?.state.audioLevel = level
            }
        }
    }

    /// Begin a new recording. Caller must ensure we're not already recording.
    /// A `.command` recording reads the EditContext here, at start, in place
    /// of the dictation context capture. Neither kind touches the clipboard
    /// while recording.
    func startRecording(kind: CaptureKind = .dictation) {
        // Reject re-entry while a recording or its post-recording pipeline
        // (transcribe → LLM → paste) is still in flight. `.thinking` covers
        // the entire await chain in finalizeRecording — `state.status` is set
        // to `.thinking` synchronously before any await, so a second call
        // landing on MainActor sees it.
        //
        // Permissions errors are sticky: clearing them on a chord-press
        // would mask a real "tap is uninstalled" condition. Pipeline and
        // modelPrep errors are clearable by the user retrying.
        switch state.status {
        case .recording, .thinking, .downloadingModel, .preparingModel, .permissionsError:
            // A prewarmed engine must not be left running when recording is
            // refused — stopPrewarm is a no-op unless the engine is idling warm.
            capture.stopPrewarm()
            return
        case .idle, .error:
            break
        }
        wasCancelled = false
        learning?.captureWillStart()
        generation &+= 1
        capHit = false
        // Scrub the prior dictation's text so it doesn't linger in process
        // memory for the lifetime of the app. Spoken content can include
        // passwords / 2FA codes / private notes; defensible-by-default hygiene.
        // Done before capture starts, so a failed start can't leave the old
        // text behind to be offered for Retry.
        let scrubbed = (last: state.lastTranscript, cleaned: state.lastCleanedText, retry: state.retryTranscript)
        state.lastTranscript = nil
        state.lastCleanedText = nil
        state.retryTranscript = nil
        self.live?.discard()
        let live = LiveSession(
            engine: engines.current,
            config: SessionConfig(vocabularyHints: vocabulary()),
            savesBakeoffClip: saveBakeoffClips()
        )
        let generation = self.generation
        let firstChunk = OnceFlag()
        capture.onSamples = { [router = live.router, weak self] samples in
            router.append(samples)
            guard firstChunk.trySet() else { return }
            Task { @MainActor [weak self] in
                self?.noteFirstAudio(generation: generation)
            }
        }
        do {
            try capture.start()
        } catch {
            // A failed start must not strand a prewarmed engine — stopPrewarm
            // is a no-op unless the engine is idling warm. On the warm path,
            // AudioCaptureService.start() can throw AFTER the
            // engine-is-running check (noInputDevice / targetFormatUnavailable
            // / cannotConvertFormat), leaving the engine running with nothing
            // left to stop it.
            capture.stopPrewarm()
            setError("Audio capture failed: \(error.localizedDescription)")
            return
        }
        self.live = live
        isRecording = true
        recordingGeneration = generation
        scrubbedTranscripts = scrubbed
        state.recordingStartedAt = Date()
        state.audioLevel = 0
        state.lastTranscribeDuration = nil
        state.lastCleanupDuration = nil
        state.liveTranscript = nil
        state.pipelinePhase = nil
        state.isCancellable = true
        state.recordingKind = kind
        state.status = .recording
        live.open { [weak self] partial in
            guard let self, self.generation == generation else { return }
            self.state.liveTranscript = partial
        }

        switch kind {
        case .dictation:
            startTasks = StartTasks(snapshot: snapshotFocus(), editContext: nil)
        case .command:
            let reader = editContextReader
            let editContextTask = Task.detached(priority: .userInitiated) { reader.read() }
            startTasks = StartTasks(snapshot: snapshotFocus(capturesContext: false), editContext: editContextTask)
        }
    }

    private func noteFirstAudio(generation: UInt64) {
        guard generation == self.generation, case .recording = state.status else { return }
        onRecordingStarted?()
    }

    /// Called when one chord modifier goes down (the "armed" edge). Warms the
    /// audio engine so a completed chord records from the first syllable.
    /// Gated on the same states startRecording accepts, so a prewarm can't
    /// light the mic indicator while recording would be refused anyway
    /// (model download, permissions error, pipeline in flight).
    func prewarmCapture() {
        switch state.status {
        case .idle, .error:
            capture.prewarm()
        default:
            break
        }
    }

    /// Called when the armed modifier is released without completing the chord.
    func cancelCapturePrewarm() {
        capture.stopPrewarm()
    }

    /// The input device went away mid-recording: finish with what was
    /// captured, as if the hotkey had been released. The real release later
    /// finds status past `.recording` and returns immediately.
    func handleCaptureInterrupted() {
        guard case .recording = state.status else { return }
        showToast("Microphone disconnected — stopped recording")
        let generation = self.generation
        Task { [weak self] in
            guard let self, self.generation == generation else { return }
            await self.finalizeRecording()
        }
    }

    /// Stop capture, finish the transcription session, run LLM cleanup against
    /// the active mode's prompt, and paste the result into the focused field.
    /// Returns as soon as `cancel()` abandons the work. A command recording
    /// that finalizes after command mode was turned off is discarded
    /// silently, before the Cmd+C fallback or the model runs. A recording
    /// whose status someone else replaced meanwhile, as a permissions error
    /// does, is discarded and that status left showing.
    func finalizeRecording() async {
        // A spurious finalize while an earlier one is mid-flight, or with no
        // recording at all, would race with the in-flight pipeline.
        guard isRecording, let live else { return }
        guard case .recording = state.status else {
            AppLog.pipeline.info("recording discarded: status changed while recording")
            discardRecording()
            scrubbedTranscripts = nil
            capHit = false
            clearRecordingState()
            return
        }
        isRecording = false
        let generation = self.generation
        let startTasks = self.startTasks
        self.startTasks = nil
        scrubbedTranscripts = nil
        let release = ContinuousClock.now
        capture.stop()
        let captureTailMs = Self.milliseconds(release.duration(to: .now))
        state.status = .thinking
        state.pipelinePhase = .transcribing
        state.lastRecordingDuration = live.router.audioDuration
        let recording = ReleasedRecording(live: live, startTasks: startTasks, release: release, captureTailMs: captureTailMs)
        await runCancellable { [weak self] in
            await self?.runFinalize(generation: generation, recording: recording)
            self?.announceCapIfHit(generation: generation)
        }
    }

    /// Esc. While recording, discards the recording. While transcribing or
    /// cleaning up, abandons the work and returns to idle at once: the raw
    /// transcript of a dictation or retry whose mode was resolved goes to
    /// history and stays retryable, and any late result is dropped. Ignored once insert has begun, and when
    /// nothing is running. A `.shortcut` discard of a recording shows no
    /// toast and keeps the previous dictation retryable; while thinking it
    /// acts as `.user` on the recording's own run, and is ignored during a
    /// preset or retry, whose chord press started no recording.
    func cancel(reason: CancelReason = .user) {
        var silent = false
        switch state.status {
        case .recording:
            discardRecording()
            silent = reason == .shortcut
            if silent, let scrubbed = scrubbedTranscripts {
                state.lastTranscript = scrubbed.last
                state.lastCleanedText = scrubbed.cleaned
                state.retryTranscript = scrubbed.retry
            }
            scrubbedTranscripts = nil
        case .thinking where state.isCancellable:
            if reason == .shortcut, generation != recordingGeneration { return }
            generation &+= 1
            finalizeWork?.cancel()
            finalizeWork = nil
            copyFallbackTask?.cancel()
            copyFallbackTask = nil
            live?.discard()
            if let dictation = cancellableDictation, !dictation.transcript.isEmpty {
                historyStore.record(cleanedText: dictation.transcript, rawTranscript: dictation.transcript, mode: dictation.mode, context: dictation.context)
            }
        default:
            return
        }
        wasCancelled = true
        capHit = false
        resetIdle()
        if !silent { showToast("Cancelled") }
        finalizeDone?.fire()
        finalizeDone = nil
    }

    /// Stops capture and drops the recording's session and start tasks;
    /// bumps `generation` so nothing late from them lands.
    private func discardRecording() {
        isRecording = false
        generation &+= 1
        capture.stop()
        live?.discard()
        startTasks?.cancel()
        startTasks = nil
    }

    /// Cleans up and inserts the last dictation's raw transcript again, for
    /// the app focused now. Records history but no metrics, and keeps
    /// `retryTranscript`, so a paste into the wrong field can be retried again.
    func retryLastDictation() async {
        guard state.canRetryLastDictation, let transcript = state.retryTranscript else { return }
        let generation = beginRun()
        state.status = .thinking
        state.pipelinePhase = .cleaning
        state.isCancellable = true
        state.liveTranscript = TranscriptPartial(stable: transcript)
        await runCancellable { [weak self] in
            await self?.runRetry(transcript: transcript, generation: generation)
        }
    }

    /// Starts a run that supersedes the current one; returns its token.
    func beginRun() -> UInt64 {
        learning?.captureWillStart()
        generation &+= 1
        return generation
    }

    /// Runs `work` as the job `cancel()` can abandon. Returns when the work
    /// ends, or at once when it is cancelled.
    func runCancellable(_ work: @escaping @MainActor () async -> Void) async {
        let done = OneShotSignal()
        finalizeDone = done
        finalizeWork = Task {
            await work()
            done.fire()
        }
        await done.wait()
    }

    private func runFinalize(generation: UInt64, recording: ReleasedRecording) async {
        let live = recording.live
        let startTasks = recording.startTasks
        var commandContext: Task<Result<ResolvedEditContext, EditContextRefusal>, Never>?
        defer {
            startTasks?.cancel()
            commandContext?.cancel()
            if let commandContext, copyFallbackTask == commandContext { copyFallbackTask = nil }
        }
        guard generation == self.generation else { return }
        if startTasks?.editContext != nil, chords().command == nil {
            AppLog.pipeline.info("command: command mode was turned off while recording; discarded")
            live.discard()
            resetIdle()
            return
        }
        let router = live.router

        // Neither path waits for the session to open (a cloud connect or a
        // model load can take seconds); `discard` cancels it once it does.
        if router.sampleCount == 0 || router.audioDuration < Self.minimumAudioDuration {
            live.discard()
            resetIdle()
            return
        }

        // Silent-capture detector: audio arrived but every sample was zero.
        // Almost always means Microphone permission is denied or a muted
        // device was selected.
        if router.peak == 0 {
            live.discard()
            return setError("No audio captured. Check that Microphone permission is granted and the input device isn't muted.")
        }

        if let editContext = startTasks?.editContext {
            commandContext = resolveEditContext(editContext, trigger: chords().command?.families ?? [], generation: generation)
            copyFallbackTask = commandContext
        }

        guard let transcription = await transcribe(live, generation: generation) else { return }
        let transcript = transcription.text
        let bakeoffAudio = live.savesBakeoffClip && commandContext == nil ? router.retainedAudio : nil
        endLiveSession()
        state.lastTranscribeDuration = Self.seconds(transcription.duration)
        state.lastTranscript = transcript
        if state.recordingKind != .command, !transcript.isEmpty {
            state.retryTranscript = transcript
        }

        if transcript.isEmpty {
            // Nothing to clean / paste — quietly idle out.
            resetIdle()
            return
        }
        state.liveTranscript = TranscriptPartial(stable: transcript)
        let timing = PipelineTiming(
            release: recording.release,
            captureTailMs: recording.captureTailMs,
            transcribeMs: Self.milliseconds(transcription.duration),
            engineID: transcription.engineID,
            firstPartialMs: transcription.firstPartial.map(Self.milliseconds)
        )

        // Mode resolution uses the frontmost app and focused field as they
        // were at recording start, not wherever focus drifted since.
        let snapshot = await startTasks?.snapshot.value ?? .empty
        guard generation == self.generation else { return }

        if let commandContext {
            await runCommand(instruction: transcript, context: commandContext, snapshot: snapshot, generation: generation, timing: timing)
            return
        }
        // Speech meant for a password field never reaches the LLM, History,
        // or Retry.
        if snapshot.field?.kind == .secure {
            state.lastTranscript = nil
            state.retryTranscript = nil
            return refuseSecureField()
        }
        guard let mode = modes.mode(for: snapshot.bundleID, field: snapshot.field) else {
            return setError(Self.noModeMessage(bundleID: snapshot.bundleID))
        }
        cancellableDictation = (transcript, mode, snapshot.context)
        await performDictation(transcript: transcript, mode: mode, snapshot: snapshot, timing: timing, bakeoffAudio: bakeoffAudio, generation: generation)
    }

    /// Finishes the recording's session. A cloud session that fails to open
    /// or finish is redone on-device from the retained audio. Returns nil
    /// once a cancel has taken over or an error is showing.
    private func transcribe(_ live: LiveSession, generation: UInt64) async -> Transcription? {
        let session: any TranscriptionSession
        do {
            session = try await live.session()
        } catch {
            let unavailableReason = await cloudUnavailableReason(live.engine, after: error)
            guard generation == self.generation else { return nil }
            if let unavailableReason {
                setError(unavailableReason)
                return nil
            }
            let message = "Couldn't start \(live.engine.id.shortName): \(error.localizedDescription)"
            return await transcribeOnDevice(after: error, live: live, start: .now, failureMessage: message, generation: generation)
        }
        guard generation == self.generation else { return nil }

        let start = ContinuousClock.now
        do {
            let text = try await session.finish()
            guard generation == self.generation else { return nil }
            return Transcription(text: text, engineID: live.engine.metricsID, duration: start.duration(to: .now), firstPartial: live.timeToFirstPartial)
        } catch {
            guard generation == self.generation else { return nil }
            let message = "Transcription failed. Try again or pick a different engine in Settings → Dictation."
            return await transcribeOnDevice(after: error, live: live, start: start, failureMessage: message, generation: generation)
        }
    }

    /// Why a cloud engine whose session failed to open can't run at all, such
    /// as OpenAI without a key or with a keychain it can't read. That is
    /// setup to fix, so it is shown as is: the fallback would hide it on
    /// every dictation.
    private func cloudUnavailableReason(_ engine: any TranscriptionEngine, after error: Error) async -> String? {
        guard engine.capabilities.contains(.sendsAudioOffDevice), !(error is CancellationError),
              case .unavailable(let reason) = await engine.readiness() else { return nil }
        return reason
    }

    /// The cloud fallback. Shows `failureMessage` instead when the engine is
    /// on-device, the session was cancelled, the on-device engine isn't ready
    /// right now (a fallback never downloads or installs a model), or the
    /// fallback fails as well.
    private func transcribeOnDevice(after error: Error, live: LiveSession, start: ContinuousClock.Instant, failureMessage: String, generation: UInt64) async -> Transcription? {
        guard live.engine.capabilities.contains(.sendsAudioOffDevice), !(error is CancellationError) else {
            setError(failureMessage)
            return nil
        }
        let local = engines.engine(for: .onDeviceDefault)
        let localIsReady = await local.readiness() == .ready
        guard generation == self.generation else { return nil }
        guard localIsReady else {
            AppLog.pipeline.error("cloud transcription failed, \(local.id.rawValue, privacy: .public) not ready to fall back: \(Self.logDescription(of: error), privacy: .public)")
            setError(failureMessage)
            return nil
        }
        AppLog.pipeline.error("cloud transcription failed, fell back: \(Self.logDescription(of: error), privacy: .public)")
        do {
            let session = try await local.openSession(live.config)
            guard generation == self.generation else {
                session.cancel()
                return nil
            }
            let audio = live.router.retainedAudio
            for chunkStart in stride(from: 0, to: audio.count, by: Self.fallbackChunkSamples) {
                session.append(Array(audio[chunkStart..<min(chunkStart + Self.fallbackChunkSamples, audio.count)]))
            }
            let text = try await withTaskCancellationHandler {
                try await session.finish()
            } onCancel: {
                session.cancel()
            }
            guard generation == self.generation else { return nil }
            showToast("Cloud transcription failed — used on-device")
            return Transcription(text: text, engineID: local.metricsID, duration: start.duration(to: .now), firstPartial: nil)
        } catch {
            guard generation == self.generation else { return nil }
            AppLog.pipeline.error("on-device fallback failed: \(Self.logDescription(of: error), privacy: .public)")
            setError(failureMessage)
            return nil
        }
    }

    /// The error's type and description; never audio or transcript text.
    private static func logDescription(of error: Error) -> String {
        "\(type(of: error)): \(error.localizedDescription)"
    }

    private func runRetry(transcript: String, generation: UInt64) async {
        let snapshot = await snapshotFocus().value
        guard generation == self.generation else { return }
        guard snapshot.field?.kind != .secure else { return refuseSecureField() }
        guard let mode = modes.mode(for: snapshot.bundleID, field: snapshot.field) else {
            return setError(Self.noModeMessage(bundleID: snapshot.bundleID))
        }
        cancellableDictation = (transcript, mode, snapshot.context)
        await performDictation(transcript: transcript, mode: mode, snapshot: snapshot, timing: nil, bakeoffAudio: nil, generation: generation)
    }

    private func announceCapIfHit(generation: UInt64) {
        guard capHit, generation == self.generation else { return }
        capHit = false
        guard state.toastMessage == nil else { return }
        showToast("Stopped at 5 minutes")
    }

    private func refuseSecureField() {
        AppLog.pipeline.info("dictation: secure field focused; refused before cleanup")
        setError(TextInsertionError.secureFieldUnsupported.errorDescription!)
    }

    private static func noModeMessage(bundleID: String?) -> String {
        "No mode for app '\(bundleID ?? "unknown")' and no '*' fallback in modes.json. Add a '*' mode, or delete ~/Library/Application Support/voxline/modes.json and relaunch Voxline to restore the defaults."
    }

    /// Clean up the transcript (or pass it through on the fast path) and
    /// paste it. Owns its terminal state. Records metrics only with `timing`,
    /// and a bake-off clip only with `bakeoffAudio`, once the paste succeeds.
    private func performDictation(transcript: String, mode: Mode, snapshot: StartSnapshot, timing: PipelineTiming?, bakeoffAudio: [Float]?, generation: UInt64) async {
        var context = snapshot.context
        context.customVocabulary = vocabulary()
        context.learnedStyle = learning?.style(for: mode.category, bundleID: snapshot.bundleID)
        state.pipelinePhase = .cleaning
        if !context.captureNotes.isEmpty {
            AppLog.context.info("context partial: notes=\(context.captureNotes.joined(separator: ",")) durationMs=\(context.captureDurationMs)")
        }
        let skippedCleanup = skipShortUtterances() && CleanupFastPath.shouldSkip(transcript)
        let cleaned: String
        let cleanupMs: Int
        if skippedCleanup {
            cleaned = transcript
            cleanupMs = 0
            state.lastCleanupDuration = 0
        } else {
            let cleanupStart = ContinuousClock.now
            do {
                let result = try await llm.cleanup(transcript: transcript, mode: mode, context: context)
                guard generation == self.generation else { return }
                cleaned = result
            } catch let e as LLMError {
                guard generation == self.generation else { return }
                transcriptFallback(transcript)
                return setError("\(e.errorDescription ?? "LLM cleanup failed.") Raw transcript copied to the clipboard — paste to recover it.")
            } catch {
                guard generation == self.generation else { return }
                transcriptFallback(transcript)
                return setError("LLM cleanup failed: \(error.localizedDescription) Raw transcript copied to the clipboard — paste to recover it.")
            }
            let cleanupDuration = cleanupStart.duration(to: .now)
            state.lastCleanupDuration = Self.seconds(cleanupDuration)
            cleanupMs = Self.milliseconds(cleanupDuration)
        }
        state.lastCleanedText = cleaned
        historyStore.record(cleanedText: cleaned, rawTranscript: transcript, mode: mode, context: context)
        state.isCancellable = false
        state.pipelinePhase = .inserting

        guard snapshot.field?.isEditable ?? true else {
            transcriptFallback(cleaned)
            recordMetrics(kind: .dictation, timing: timing, cleanupMs: cleanupMs, insertMs: 0, skippedCleanup: skippedCleanup, insertStrategy: .copy, mode: mode, text: cleaned)
            resetIdle()
            showToast("No text field focused — copied")
            return
        }

        let insertStart = ContinuousClock.now
        let outcome = await inserter.insert(cleaned, at: .liveSelection, expectedElement: nil,
                                            bundleID: snapshot.bundleID, trigger: chords().dictation.families)
        guard generation == self.generation else { return }
        switch outcome {
        case .inserted(let strategy, _):
            recordMetrics(kind: .dictation, timing: timing, cleanupMs: cleanupMs, insertMs: Self.milliseconds(insertStart.duration(to: .now)), skippedCleanup: skippedCleanup, insertStrategy: .init(strategy), mode: mode, text: cleaned)
            if let bakeoffAudio {
                bakeoffClipSink(bakeoffAudio, cleaned)
            }
            resetIdle()
            learning?.didInsert(InsertedDictation(text: cleaned, bundleID: snapshot.bundleID, category: mode.category))
        case .notInserted(.secure):
            setError(TextInsertionError.secureFieldUnsupported.errorDescription!)
        case .notInserted(let reason):
            transcriptFallback(cleaned)
            recordMetrics(kind: .dictation, timing: timing, cleanupMs: cleanupMs, insertMs: 0, skippedCleanup: skippedCleanup, insertStrategy: .copy, mode: mode, text: cleaned)
            resetIdle()
            showToast(reason == .notResponding ? "Field isn't responding — copied" : "Couldn't insert — copied, ⌘V to paste")
        case .failed(let error):
            setError(error.errorDescription ?? "Text insertion failed.", permissions: error == .accessibilityNotGranted)
        }
    }

    // MARK: - Snapshot and metrics

    /// Frontmost app, focused field, and (unless `capturesContext` is false)
    /// context, read off the main actor.
    private func snapshotFocus(capturesContext: Bool = true) -> Task<StartSnapshot, Never> {
        let captor = contextCapture
        let frontmost = frontmost
        let fieldInspector = fieldInspector
        return Task.detached(priority: .userInitiated) {
            let bundleID = frontmost.frontmostBundleID()
            let field = fieldInspector.inspect()
            let context = capturesContext ? await captor.capture() : .empty
            return StartSnapshot(context: context, bundleID: bundleID, field: field)
        }
    }

    /// Work started alongside a recording. Finalize takes ownership before its
    /// first await, so it can never cancel or clear a later recording's tasks.
    private struct StartTasks {
        let snapshot: Task<StartSnapshot, Never>
        /// Set for a command recording only.
        let editContext: Task<Result<EditContext, EditContextRefusal>, Never>?

        func cancel() {
            snapshot.cancel()
            editContext?.cancel()
        }
    }

    /// A recording whose capture has stopped, handed from `finalizeRecording`
    /// to its work task together with ownership of the start tasks.
    private struct ReleasedRecording {
        let live: LiveSession
        let startTasks: StartTasks?
        let release: ContinuousClock.Instant
        let captureTailMs: Int
    }

    struct StartSnapshot: Sendable {
        let context: CapturedContext
        let bundleID: String?
        let field: FocusedField?

        static let empty = StartSnapshot(context: .empty, bundleID: nil, field: nil)
    }

    /// A finished transcript and the engine that produced it.
    private struct Transcription {
        let text: String
        let engineID: String
        let duration: Duration
        /// Recording start → first partial from the session that produced the
        /// text; nil after a fallback, whose partials came from the failed session.
        let firstPartial: Duration?
    }

    struct PipelineTiming {
        let release: ContinuousClock.Instant
        let captureTailMs: Int
        let transcribeMs: Int
        let engineID: String
        let firstPartialMs: Int?
    }

    private func recordMetrics(kind: DictationMetrics.Kind, timing: PipelineTiming?, cleanupMs: Int, insertMs: Int, skippedCleanup: Bool = false, insertStrategy: DictationMetrics.InsertStrategyTag, editAction: String? = nil, mode: Mode, text: String) {
        guard let timing else { return }
        metrics.record(DictationMetrics(
            timestamp: now(),
            kind: kind,
            audioDuration: state.lastRecordingDuration ?? 0,
            captureTailMs: timing.captureTailMs,
            transcribeMs: timing.transcribeMs,
            cleanupMs: cleanupMs,
            insertMs: insertMs,
            totalMs: Self.milliseconds(timing.release.duration(to: .now)),
            engineID: timing.engineID,
            modelID: mode.model ?? llmModelID(),
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            firstPartialMs: timing.firstPartialMs,
            skippedCleanup: skippedCleanup,
            insertStrategy: insertStrategy,
            editAction: editAction
        ))
    }

    /// Saves the clip off the main actor and logs its file name.
    nonisolated static func writeBakeoffClip(_ samples: [Float], reference: String) {
        Task.detached(priority: .utility) {
            do {
                let wav = try BakeoffClipWriter.write(samples: samples, reference: reference, to: AppPaths.bakeoffDirectory(), now: .now)
                AppLog.pipeline.info("saved bake-off clip \(wav.lastPathComponent, privacy: .public)")
            } catch {
                AppLog.pipeline.error("bake-off clip not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Truncates, so stage times never sum past the total measured around them.
    static func milliseconds(_ duration: Duration) -> Int {
        Int(duration / .milliseconds(1))
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        duration / .seconds(1)
    }

    // MARK: - Terminal states

    func showToast(_ message: String) {
        state.flashToast(message)
    }

    /// Leaves a permissions error showing: it is sticky, and only the
    /// coordinator's permission check clears it.
    func resetIdle() {
        clearRecordingState()
        guard !showsPermissionsError else { return }
        state.status = .idle
    }

    /// A plain error never replaces a permissions error showing.
    func setError(_ message: String, permissions: Bool = false) {
        if permissions {
            state.status = .permissionsError(message)
        } else if !showsPermissionsError {
            state.status = .error(message)
        }
        clearRecordingState()
    }

    private var showsPermissionsError: Bool {
        if case .permissionsError = state.status { return true }
        return false
    }

    /// Stops feeding and observing the current session, which must already be
    /// finished or cancelled, and lets go of its router.
    private func endLiveSession() {
        live?.close()
        live = nil
        capture.onSamples = nil
    }

    /// Shared by idle and error. `retryTranscript` survives both.
    private func clearRecordingState() {
        isRecording = false
        endLiveSession()
        state.recordingStartedAt = nil
        state.audioLevel = 0
        state.liveTranscript = nil
        state.pipelinePhase = nil
        state.activityLabel = nil
        state.recordingKind = nil
        state.isCancellable = false
        cancellableDictation = nil
    }
}
