import Foundation

/// An EditContext once the Cmd+C fallback, if it was needed, has run.
struct ResolvedEditContext: Sendable {
    var context: EditContext
    /// The selection came from Cmd+C, so a re-read must use Cmd+C too.
    var selectionFromCopy: Bool
}

extension CapturePipeline {

    /// What a command or preset run records, and the modifiers its synthetic
    /// keystrokes wait on.
    struct CommandRun {
        let kind: DictationMetrics.Kind
        /// History's raw transcript: the spoken instruction, or the preset name.
        let label: String
        let trigger: ModifierFamilies
        /// Key release for a command, the key press for a preset.
        let start: ContinuousClock.Instant
        let audioDuration: TimeInterval
        let captureTailMs: Int
        let transcribeMs: Int
        let engineID: String
        let firstPartialMs: Int?
        /// The focus snapshot taken at recording start; nil for presets.
        let snapshot: StartSnapshot?
    }

    // MARK: - Toasts

    static func toast(for refusal: EditContextRefusal) -> String {
        switch refusal {
        case .secureField: return "Command mode is off in password fields"
        case .notResponding: return "The app isn't responding — try again"
        case .selectionTooLong: return "Selection too long — 8,000 characters max"
        }
    }

    static func toast(for reason: NotInsertedReason) -> String {
        switch reason {
        case .secure: return "Command mode is off in password fields"
        case .notResponding: return "The app isn't responding — try again"
        case .fieldChanged, .focusMoved: return "Field changed — copied, ⌘V to apply"
        case .cannotTarget, .outcomeUnknown: return "Couldn't edit in place — copied, ⌘V to apply"
        }
    }

    // MARK: - Presets

    /// Runs `preset` against the selection, with no recording and no sounds.
    /// Ignored unless idle or showing an error.
    func runPreset(_ preset: PresetShortcut) async {
        switch state.status {
        case .idle, .error:
            break
        default:
            return
        }
        let start = ContinuousClock.now
        let generation = beginRun()
        state.status = .thinking
        state.isCancellable = true
        state.activityLabel = "\(preset.name)…"
        await runCancellable { [weak self] in
            await self?.runPresetWork(preset, start: start, generation: generation)
        }
    }

    private func runPresetWork(_ preset: PresetShortcut, start: ContinuousClock.Instant, generation: UInt64) async {
        let reader = editContextReader
        let read = await Task.detached(priority: .userInitiated) { reader.read() }.value
        guard generation == self.generation else { return }
        let resolved = await resolveCopyFallback(read, trigger: preset.combo.modifiers, generation: generation)
        guard generation == self.generation else { return }
        let target: ResolvedEditContext
        switch resolved {
        case .failure(let refusal):
            resetIdle()
            showToast(Self.toast(for: refusal))
            return
        case .success(let value):
            target = value
        }
        guard target.context.selection != nil else {
            resetIdle()
            showToast("Select text to transform")
            return
        }
        let request = CommandRequest(
            instruction: preset.instruction,
            context: target.context,
            actions: CommandAction.allowed(fieldReadable: target.context.field != nil, hasSelection: true, isPreset: true),
            vocabulary: vocabulary(),
            model: commandModelID() ?? llmModelID(),
            includesField: false
        )
        let run = CommandRun(
            kind: .preset, label: preset.name, trigger: preset.combo.modifiers, start: start,
            audioDuration: 0, captureTailMs: 0, transcribeMs: 0, engineID: "none", firstPartialMs: nil, snapshot: nil
        )
        await edit(request, target: target, run: run, generation: generation)
    }

    // MARK: - Commands

    /// Waits for the recording's EditContext read and, when it needs one,
    /// runs the Cmd+C fallback once `trigger` is released. Started at key
    /// release so the copy overlaps transcription.
    func resolveEditContext(_ read: Task<Result<EditContext, EditContextRefusal>, Never>,
                            trigger: ModifierFamilies,
                            generation: UInt64) -> Task<Result<ResolvedEditContext, EditContextRefusal>, Never> {
        Task { [weak self] in
            let result = await read.value
            guard let self else { return result.map { ResolvedEditContext(context: $0, selectionFromCopy: false) } }
            return await self.resolveCopyFallback(result, trigger: trigger, generation: generation)
        }
    }

    private func resolveCopyFallback(_ read: Result<EditContext, EditContextRefusal>,
                                     trigger: ModifierFamilies,
                                     generation: UInt64) async -> Result<ResolvedEditContext, EditContextRefusal> {
        guard case .success(var context) = read else {
            return read.map { ResolvedEditContext(context: $0, selectionFromCopy: false) }
        }
        guard context.needsCopyFallback else {
            return .success(ResolvedEditContext(context: context, selectionFromCopy: false))
        }
        let copied = await copySelection(trigger: trigger, generation: generation)
        context.selection = copied.map { SelectionInfo(text: $0, range: nil) }
        context.needsCopyFallback = false
        if let copied, copied.utf16.count > EditContextPolicy.default.selectionMax {
            AppLog.pipeline.info("command: copied selection too long (\(copied.utf16.count) units)")
            return .failure(.selectionTooLong)
        }
        return .success(ResolvedEditContext(context: context, selectionFromCopy: true))
    }

    /// Cmd+C, after `trigger` is released and after any earlier paste has put
    /// the user's clipboard back: snapshotting voxline's own promised item
    /// would later restore pasted text over the user's clipboard. Nil once a
    /// cancel or a newer run has taken over.
    private func copySelection(trigger: ModifierFamilies, generation: UInt64) async -> String? {
        try? await releaseGate.wait(for: trigger)
        await inserter.waitForClipboardRestore()
        guard generation == self.generation, !Task.isCancelled else { return nil }
        return await selectionSnapshot.readSelection()
    }

    /// Edits the field or selection the EditContext describes, as `instruction`
    /// asks. Owns its terminal state.
    func runCommand(instruction: String,
                    context: Task<Result<ResolvedEditContext, EditContextRefusal>, Never>,
                    snapshot: StartSnapshot,
                    generation: UInt64,
                    timing: PipelineTiming) async {
        let resolved = await context.value
        guard generation == self.generation else { return }
        let target: ResolvedEditContext
        switch resolved {
        case .failure(let refusal):
            resetIdle()
            showToast(Self.toast(for: refusal))
            return
        case .success(let value):
            target = value
        }
        let ctx = target.context
        let request = CommandRequest(
            instruction: instruction,
            context: ctx,
            actions: CommandAction.allowed(fieldReadable: ctx.field != nil, hasSelection: ctx.selection != nil, isPreset: false),
            vocabulary: vocabulary(),
            model: commandModelID() ?? llmModelID(),
            includesField: true
        )
        let run = CommandRun(
            kind: .command, label: instruction, trigger: chords().command?.families ?? [], start: timing.release,
            audioDuration: state.lastRecordingDuration ?? 0, captureTailMs: timing.captureTailMs,
            transcribeMs: timing.transcribeMs, engineID: timing.engineID, firstPartialMs: timing.firstPartialMs,
            snapshot: snapshot
        )
        await edit(request, target: target, run: run, generation: generation)
    }

    // MARK: - Shared edit

    private func edit(_ request: CommandRequest, target: ResolvedEditContext, run: CommandRun, generation: UInt64) async {
        state.pipelinePhase = .editing
        state.isCancellable = true
        let llmStart = ContinuousClock.now
        let result: CommandResult
        do {
            result = try await llm.command(request)
            guard generation == self.generation else { return }
        } catch let e as LLMError {
            guard generation == self.generation else { return }
            return setError("\(e.errorDescription ?? "Command failed.") Nothing was changed.")
        } catch {
            guard generation == self.generation else { return }
            return setError("Command failed: \(error.localizedDescription) Nothing was changed.")
        }
        let llmMs = Self.milliseconds(llmStart.duration(to: .now))
        state.isCancellable = false
        let isPreset = run.kind == .preset
        let plan = EditPlanner.plan(result: result, context: target.context, isPreset: isPreset)
        let performed = PerformedEdit(
            request: request, target: target, run: run, llmMs: llmMs,
            action: (isPreset ? CommandAction.replaceSelection : result.action).rawValue
        )
        await act(plan, performed, generation: generation)
    }

    private struct PerformedEdit {
        let request: CommandRequest
        let target: ResolvedEditContext
        let run: CommandRun
        let llmMs: Int
        let action: String
        var context: EditContext { target.context }
    }

    private func act(_ plan: PlannedEdit, _ edit: PerformedEdit, generation: UInt64) async {
        switch plan {
        case .nothing(let message):
            recordCommandMetrics(edit, insertMs: 0, strategy: .none, text: "")
            resetIdle()
            showToast(message)
        case .copy(let text):
            transcriptFallback(text)
            recordCommandHistory(text, edit)
            recordCommandMetrics(edit, insertMs: 0, strategy: .copy, text: text)
            resetIdle()
            showToast("Copied — no text field focused")
        case .replace(let range, let expected, let text):
            await insert(text, at: .range(range, expected: expected), edit, generation: generation)
        case .insertAtCaret(let text):
            await insert(text, at: .liveSelection, edit, generation: generation)
        case .replaceLiveSelection(let text):
            await insertAtLiveSelection(text, at: .liveSelection, edit, generation: generation)
        case .insertAfterLiveSelection(let text):
            await insertAtLiveSelection(text, at: .afterLiveSelection, edit, generation: generation)
        }
    }

    /// Re-reads the selection the way it was first read; a different
    /// selection means the field changed while the model was working.
    private func insertAtLiveSelection(_ text: String, at target: InsertTarget, _ edit: PerformedEdit, generation: UInt64) async {
        state.pipelinePhase = .inserting
        let mismatch: NotInsertedReason?
        if edit.target.selectionFromCopy {
            let live = await copySelection(trigger: edit.run.trigger, generation: generation)
            guard generation == self.generation else { return }
            mismatch = live == edit.context.selection?.text ? nil : .fieldChanged
        } else {
            let reader = editContextReader
            let read = await Task.detached(priority: .userInitiated) { reader.read() }.value
            guard generation == self.generation else { return }
            switch read {
            case .success(let live):
                mismatch = live.selection?.text == edit.context.selection?.text ? nil : .fieldChanged
            case .failure(.secureField):
                mismatch = .secure
            case .failure(.notResponding):
                mismatch = .notResponding
            case .failure(.selectionTooLong):
                mismatch = .fieldChanged
            }
        }
        if let mismatch {
            AppLog.pipeline.info("command: live selection re-read differs (\(String(describing: mismatch), privacy: .public))")
            finishInsert(.notInserted(mismatch), text: text, insertMs: 0, edit)
            return
        }
        await insert(text, at: target, edit, generation: generation)
    }

    private func insert(_ text: String, at target: InsertTarget, _ edit: PerformedEdit, generation: UInt64) async {
        state.pipelinePhase = .inserting
        let insertStart = ContinuousClock.now
        let outcome = await inserter.insert(text, at: target, expectedElement: edit.context.element,
                                            bundleID: edit.context.bundleID, trigger: edit.run.trigger)
        guard generation == self.generation else { return }
        finishInsert(outcome, text: text, insertMs: Self.milliseconds(insertStart.duration(to: .now)), edit)
    }

    private func finishInsert(_ outcome: InsertOutcome, text: String, insertMs: Int, _ edit: PerformedEdit) {
        switch outcome {
        case .inserted(let strategy, _):
            recordCommandHistory(text, edit)
            recordCommandMetrics(edit, insertMs: insertMs, strategy: .init(strategy), text: text)
            resetIdle()
        case .notInserted(let reason) where reason == .secure || reason == .notResponding:
            resetIdle()
            showToast(Self.toast(for: reason))
        case .notInserted(let reason):
            transcriptFallback(text)
            recordCommandMetrics(edit, insertMs: 0, strategy: .copy, text: text)
            recordCommandHistory(text, edit)
            resetIdle()
            showToast(Self.toast(for: reason))
        case .failed(let error):
            setError(error.errorDescription ?? "Text insertion failed.", permissions: error == .accessibilityNotGranted)
        }
    }

    // MARK: - History and metrics

    /// Records the inserted or copied text under the instruction or preset
    /// name. Never stores field text: the context carries only app and role.
    private func recordCommandHistory(_ text: String, _ edit: PerformedEdit) {
        let ctx = edit.context
        let bundleID = ctx.bundleID ?? edit.run.snapshot?.bundleID
        let field = ctx.role != nil || ctx.subrole != nil
            ? FocusedField(role: ctx.role, subrole: ctx.subrole)
            : edit.run.snapshot?.field
        guard let mode = modes.mode(for: bundleID, field: field) else { return }
        var context = CapturedContext.empty
        context.appName = ctx.appName
        context.bundleID = bundleID
        context.windowTitle = ctx.windowTitle
        context.fieldRole = ctx.role
        context.fieldSubrole = ctx.subrole
        historyStore.record(cleanedText: text, rawTranscript: edit.run.label, mode: mode, context: context)
    }

    private func recordCommandMetrics(_ edit: PerformedEdit, insertMs: Int, strategy: DictationMetrics.InsertStrategyTag, text: String) {
        let run = edit.run
        metrics.record(DictationMetrics(
            timestamp: now(),
            kind: run.kind,
            audioDuration: run.audioDuration,
            captureTailMs: run.captureTailMs,
            transcribeMs: run.transcribeMs,
            cleanupMs: edit.llmMs,
            insertMs: insertMs,
            totalMs: Self.milliseconds(run.start.duration(to: .now)),
            engineID: run.engineID,
            modelID: edit.request.model,
            wordCount: text.split(whereSeparator: \.isWhitespace).count,
            firstPartialMs: run.firstPartialMs,
            skippedCleanup: false,
            insertStrategy: strategy,
            editAction: edit.action
        ))
    }
}
