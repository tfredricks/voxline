import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import voxline

@Suite(.timeLimit(.minutes(1))) @MainActor struct CapturePipelineCommandTests {

    typealias FakeCapture = CapturePipelineTests.FakeCapture
    typealias FakeLLM = CapturePipelineTests.FakeLLM
    typealias LockedFrontmost = CapturePipelineStreamingTests.LockedFrontmost
    typealias LockedFieldInspector = CapturePipelineStreamingTests.LockedFieldInspector

    nonisolated static let notes = "com.apple.Notes"
    nonisolated static let instruction = "make it a dog"
    nonisolated static let fieldText = "the cat sat"
    nonisolated static let cat = UTF16Range(location: 4, length: 3)
    nonisolated static let element = AXElementRef(element: AXUIElementCreateApplication(4242))
    static let commandFamilies = ChordSet.default.command!.families
    static let makeConcise = PresetShortcut.defaults[1]

    /// The Cmd+C fallback: answers from `copies` in order, then repeats the
    /// last one (nil when empty), and logs each read.
    final class CopySnapshot: SelectionSnapshotting, @unchecked Sendable {
        private let copies: LockedBox<[String?]>
        let log: LockedBox<[String]>
        let reads = LockedBox(0)
        init(_ copies: [String?], log: LockedBox<[String]>) {
            self.copies = LockedBox(copies)
            self.log = log
        }
        func readSelection() async -> String? {
            reads.mutate { $0 += 1 }
            log.mutate { $0.append("copy") }
            var next: String?
            copies.mutate { queue in
                guard let first = queue.first else { return }
                next = first
                if queue.count > 1 { queue.removeFirst() }
            }
            return next
        }
    }

    struct Harness {
        let pipe: CapturePipeline
        let state: AppState
        let capture: FakeCapture
        let session: FakeTranscriptionSession
        let llm: FakeLLM
        let inserter: FakeTextInserter
        let reader: FakeEditContextReader
        let copies: CopySnapshot
        let history: DictationHistoryStore
        let context: FakeContextCapture
        let copied: LockedBox<[String]>
        let log: LockedBox<[String]>
    }

    static let defaultModes = [
        Mode(bundleID: notes, displayName: "Notes", prompt: "notes-prompt", model: nil, temperature: nil, category: .writing),
        Mode(bundleID: "*", displayName: "Default", prompt: "default-prompt", model: nil, temperature: nil, category: .general)
    ]

    private func makeHarness(
        reader: FakeEditContextReader,
        copies: [String?] = [],
        gate: ModifierReleaseGate = .released,
        log: LockedBox<[String]> = LockedBox([]),
        commandModel: String? = nil,
        modes: [Mode] = defaultModes
    ) -> Harness {
        let state = AppState()
        let capture = FakeCapture()
        let engine = FakeTranscriptionEngine()
        let session = FakeTranscriptionSession()
        session.finishResult = .success(Self.instruction)
        engine.nextSessions = [session]
        let llm = FakeLLM()
        let inserter = FakeTextInserter()
        let copySnapshot = CopySnapshot(copies, log: log)
        let context = FakeContextCapture()
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let history = DictationHistoryStore(defaults: defaults)
        let pipe = CapturePipeline(
            state: state,
            capture: capture,
            engines: FakeEngineProvider(engine),
            llm: llm,
            modes: ModeRouter(modes: modes),
            frontmost: LockedFrontmost(Self.notes),
            fieldInspector: LockedFieldInspector(nil),
            inserter: inserter,
            historyStore: history,
            contextCapture: context,
            selectionSnapshot: copySnapshot,
            editContextReader: reader,
            llmModelID: { "test-model" },
            commandModelID: { commandModel },
            vocabulary: { ["Voxline"] },
            skipShortUtterances: { false },
            chords: { .default },
            releaseGate: gate
        )
        let copied = LockedBox<[String]>([])
        pipe.transcriptFallback = { text in copied.mutate { $0.append(text) } }
        llm.onCommand = { log.mutate { $0.append("command") } }
        inserter.onClipboardRestoreWait = { log.mutate { $0.append("clipboard") } }
        return Harness(
            pipe: pipe, state: state, capture: capture, session: session, llm: llm, inserter: inserter,
            reader: reader, copies: copySnapshot, history: history, context: context, copied: copied, log: log
        )
    }

    /// Notes with "the cat sat", fully readable; `selecting` sets the
    /// selection, otherwise the cursor is at `cursor` (default: the end).
    nonisolated static func notesContext(selecting range: UTF16Range? = nil, cursor: Int? = nil) -> EditContext {
        let full = fieldText as NSString
        return EditContext(
            appName: "Notes", bundleID: notes, windowTitle: "Trip plan", role: "AXTextArea", subrole: nil,
            isEditable: true, element: element,
            field: FieldWindowText(text: fieldText, range: UTF16Range(location: 0, length: full.length), fullLength: full.length),
            selection: range.map { SelectionInfo(text: full.substring(with: $0.nsRange), range: $0) },
            cursor: range?.location ?? cursor ?? full.length,
            needsCopyFallback: false
        )
    }

    /// Notes whose field is unavailable, with `selection` read from AX
    /// without a range.
    nonisolated static func unavailableContext(selection: String?, isEditable: Bool = true) -> EditContext {
        EditContext(
            appName: "Notes", bundleID: notes, windowTitle: "Trip plan", role: isEditable ? "AXTextArea" : "AXStaticText", subrole: nil,
            isEditable: isEditable, element: element, field: nil,
            selection: selection.map { SelectionInfo(text: $0, range: nil) },
            cursor: nil, needsCopyFallback: false
        )
    }

    private func reader(_ context: EditContext) -> FakeEditContextReader {
        FakeEditContextReader(.success(context))
    }

    private func runCommand(_ h: Harness) async {
        h.pipe.startRecording(kind: .command)
        await h.pipe.finalizeRecording()
    }

    private func answer(_ h: Harness, _ action: CommandAction, _ text: String) {
        h.llm.commandResults = [.success(CommandResult(action: action, text: text))]
    }

    // MARK: - Targets

    @Test func replace_command_targets_the_selection_range() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, .replaceSelection, "dog")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(h.inserter.calls.count == 1)
        #expect(call.target == .range(Self.cat, expected: "cat"))
        #expect(call.text == "dog")
        #expect(call.expected == Self.element)
        #expect(call.bundleID == Self.notes)
        #expect(call.trigger == Self.commandFamilies)

        let request = try #require(h.llm.commandRequests.first)
        #expect(request.instruction == Self.instruction)
        #expect(request.context == Self.notesContext(selecting: Self.cat))
        #expect(request.actions == [.replaceSelection, .insert])
        #expect(request.includesField)
        #expect(request.vocabulary == ["Voxline"])
        #expect(request.model == "test-model")

        let item = try #require(h.history.items.first)
        #expect(h.history.items.count == 1)
        #expect(item.cleanedText == "dog")
        #expect(item.rawTranscript == Self.instruction)
        #expect(item.appName == "Notes")
        #expect(item.appBundleID == Self.notes)
        #expect(item.modeCategoryName == "Writing")

        let row = try #require(h.pipe.metrics.items.first)
        #expect(h.pipe.metrics.items.count == 1)
        #expect(row.kind == .command)
        #expect(row.editAction == "replace_selection")
        #expect(row.insertStrategy == .ax)
        #expect(row.engineID == "fake:engine")
        #expect(row.modelID == "test-model")
        #expect(row.wordCount == 1)
        #expect(row.audioDuration > 0)
        #expect(row.totalMs >= row.transcribeMs + row.cleanupMs + row.insertMs)

        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == nil)
        #expect(h.state.recordingKind == nil)
        #expect(h.state.retryTranscript == nil)
        #expect(h.context.captureCallCount == 0)
        #expect(h.copies.reads.read() == 0)
        #expect(h.copied.read().isEmpty)
    }

    @Test func insert_command_lands_at_the_cursor() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(cursor: 7)))
        answer(h, .insert, "!")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .range(UTF16Range(location: 7, length: 0), expected: ""))
        #expect(call.text == "!")
        #expect(h.llm.commandRequests.first?.actions == [.insert, .rewrite])
        #expect(h.pipe.metrics.items.first?.editAction == "insert")
    }

    @Test func rewrite_command_replaces_the_minimal_hunk() async throws {
        let h = makeHarness(reader: reader(Self.notesContext()))
        answer(h, .rewrite, "the dog sat")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .range(Self.cat, expected: "cat"))
        #expect(call.text == "dog")
        #expect(h.history.items.first?.cleanedText == "dog")
        #expect(h.history.items.first?.rawTranscript == Self.instruction)
        #expect(h.pipe.metrics.items.first?.editAction == "rewrite")
    }

    @Test func insert_without_a_readable_field_lands_at_the_caret() async throws {
        let h = makeHarness(reader: reader(Self.unavailableContext(selection: nil)))
        answer(h, .insert, "hello")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .liveSelection)
        #expect(call.expected == Self.element)
        #expect(h.llm.commandRequests.first?.actions == [.insert])
        #expect(h.reader.readCount == 1)
    }

    @Test func live_selection_reread_match_replaces_the_selection() async throws {
        let h = makeHarness(reader: reader(Self.unavailableContext(selection: "abc")))
        answer(h, .replaceSelection, "xyz")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .liveSelection)
        #expect(call.text == "xyz")
        #expect(call.expected == Self.element)
        #expect(h.reader.readCount == 2)
        #expect(h.copies.reads.read() == 0)
    }

    @Test func insert_after_a_live_selection_targets_after_it() async throws {
        let h = makeHarness(reader: reader(Self.unavailableContext(selection: "abc")))
        answer(h, .insert, "!")
        await runCommand(h)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .afterLiveSelection)
        #expect(call.text == "!")
    }

    @Test func live_selection_reread_mismatch_is_fieldChanged() async throws {
        let h = makeHarness(reader: FakeEditContextReader(
            .success(Self.unavailableContext(selection: "abc")),
            .success(Self.unavailableContext(selection: "abd"))
        ))
        answer(h, .replaceSelection, "xyz")
        await runCommand(h)

        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read() == ["xyz"])
        #expect(h.state.toastMessage == "Field changed — copied, ⌘V to apply")
        #expect(h.state.status == .idle)
        #expect(h.pipe.metrics.items.first?.insertStrategy == .copy)
        #expect(h.history.items.first?.cleanedText == "xyz")
    }

    @Test func copied_selection_reread_mismatch_is_fieldChanged() async throws {
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted", "changed"])
        answer(h, .replaceSelection, "xyz")
        await runCommand(h)

        #expect(h.copies.reads.read() == 2)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read() == ["xyz"])
        #expect(h.state.toastMessage == "Field changed — copied, ⌘V to apply")
    }

    // MARK: - Cmd+C fallback

    @Test func copy_fallback_runs_after_release_and_before_the_llm() async throws {
        let log = LockedBox<[String]>([])
        let flags = LockedBox<[CGEventFlags]>([.maskAlternate, []])
        var gate = ModifierReleaseGate.released
        gate.flagsState = {
            var next: CGEventFlags = []
            flags.mutate { queue in
                next = queue.first ?? []
                if queue.count > 1 { queue.removeFirst() }
            }
            return next
        }
        gate.sleep = { _ in log.mutate { $0.append("held") } }
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"], gate: gate, log: log)
        await runCommand(h)

        #expect(Array(log.read().prefix(4)) == ["clipboard", "held", "copy", "command"])
        let request = try #require(h.llm.commandRequests.first)
        #expect(request.context.selection == SelectionInfo(text: "quoted", range: nil))
        #expect(request.context.needsCopyFallback == false)
        #expect(request.context.field == nil)
        #expect(request.actions == [.replaceSelection, .insert])
        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .liveSelection)
        #expect(call.text == "transformed")
    }

    @Test func copy_fallback_starts_before_transcription_finishes() async {
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"])
        h.session.holdFinish = true
        h.pipe.startRecording(kind: .command)
        let finalize = Task { await h.pipe.finalizeRecording() }

        #expect(await eventually { h.copies.reads.read() == 1 })
        #expect(h.llm.commandRequests.isEmpty)
        h.session.releaseFinish()
        await finalize.value
        #expect(h.llm.commandRequests.first?.context.selection?.text == "quoted")
    }

    @Test func copy_fallback_waits_for_the_pending_clipboard_restore() async {
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"])
        h.inserter.holdClipboardRestore = true
        defer { h.inserter.releaseClipboardRestore() }
        h.pipe.startRecording(kind: .command)
        let finalize = Task { await h.pipe.finalizeRecording() }

        #expect(await eventually { h.inserter.clipboardRestoreGate.waiting == 1 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.copies.reads.read() == 0)
        #expect(h.llm.commandRequests.isEmpty)

        h.inserter.releaseClipboardRestore()
        await finalize.value
        #expect(Array(h.log.read().prefix(3)) == ["clipboard", "copy", "command"])
        #expect(h.inserter.calls.map(\.text) == ["transformed"])
    }

    @Test func esc_before_the_copy_fallback_skips_the_copy() async {
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"])
        h.inserter.holdClipboardRestore = true
        defer { h.inserter.releaseClipboardRestore() }
        h.pipe.startRecording(kind: .command)
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.inserter.clipboardRestoreGate.waiting == 1 })

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .seconds(1)))
        h.inserter.releaseClipboardRestore()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(h.copies.reads.read() == 0)
        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
    }

    @Test func esc_during_a_held_modifier_wait_never_force_clears() async {
        let clock = ManualClock()
        let clears = LockedBox(0)
        let polls = LockedBox(0)
        var gate = ModifierReleaseGate()
        gate.flagsState = {
            polls.mutate { $0 += 1 }
            return .maskAlternate
        }
        gate.forceClear = { clears.mutate { $0 += 1 } }
        gate.sleep = { @MainActor in try await clock.sleep($0) }
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"], gate: gate)
        h.session.holdFinish = true
        h.session.ignoresCancel = true
        defer { h.session.releaseFinish() }
        h.pipe.startRecording(kind: .command)
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { clock.pendingCount == 1 })
        #expect(polls.read() >= 1)

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .seconds(1)))
        await clock.advance(by: .seconds(5))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(clears.read() == 0)
        #expect(clock.pendingCount == 0)
        #expect(h.copies.reads.read() == 0)
        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")
    }

    @Test func copied_selection_over_the_cap_refuses() async {
        let h = makeHarness(reader: .needingCopy(), copies: [String(repeating: "a", count: 8_001)])
        await runCommand(h)

        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.state.toastMessage == "Selection too long — 8,000 characters max")
        #expect(h.state.status == .idle)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func non_editable_element_with_no_readable_selection_copies_and_never_inserts() async throws {
        let h = makeHarness(reader: .needingCopy(isEditable: false), copies: ["text on a web page"])
        answer(h, .insert, "A summary.")
        await runCommand(h)

        #expect(h.copies.reads.read() == 1)
        #expect(h.llm.commandRequests.first?.context.selection?.text == "text on a web page")
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read() == ["A summary."])
        #expect(h.state.toastMessage == "Copied — no text field focused")
        #expect(h.state.status == .idle)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.insertStrategy == .copy)
        #expect(row.editAction == "insert")
        #expect(h.history.items.first?.cleanedText == "A summary.")
    }

    @Test func non_editable_element_with_nothing_copied_still_copies_the_answer() async throws {
        let h = makeHarness(reader: .needingCopy(isEditable: false), copies: [nil])
        answer(h, .insert, "Answer.")
        await runCommand(h)

        #expect(h.llm.commandRequests.first?.actions == [.insert])
        #expect(h.llm.commandRequests.first?.context.selection == nil)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read() == ["Answer."])
        #expect(h.state.toastMessage == "Copied — no text field focused")
    }

    // MARK: - Toast table

    @Test(arguments: [
        (EditContextRefusal.secureField, "Command mode is off in password fields"),
        (.notResponding, "The app isn't responding — try again"),
        (.selectionTooLong, "Selection too long — 8,000 characters max"),
    ])
    func refusal_shows_its_toast(refusal: EditContextRefusal, toast: String) async {
        let h = makeHarness(reader: FakeEditContextReader(.failure(refusal)))
        await runCommand(h)

        #expect(h.state.toastMessage == toast)
        #expect(CapturePipeline.toast(for: refusal) == toast)
        #expect(h.state.status == .idle)
        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read().isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test(arguments: [
        (NotInsertedReason.fieldChanged, "Field changed — copied, ⌘V to apply"),
        (.focusMoved, "Field changed — copied, ⌘V to apply"),
        (.cannotTarget, "Couldn't edit in place — copied, ⌘V to apply"),
        (.outcomeUnknown, "Couldn't edit in place — copied, ⌘V to apply"),
    ])
    func not_inserted_copies_with_its_toast(reason: NotInsertedReason, toast: String) async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, .replaceSelection, "dog")
        h.inserter.outcomes = [.notInserted(reason)]
        await runCommand(h)

        #expect(h.copied.read() == ["dog"])
        #expect(h.state.toastMessage == toast)
        #expect(CapturePipeline.toast(for: reason) == toast)
        #expect(h.state.status == .idle)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.insertStrategy == .copy)
        #expect(row.insertMs == 0)
        #expect(row.editAction == "replace_selection")
        #expect(h.history.items.first?.cleanedText == "dog")
    }

    @Test(arguments: [
        (NotInsertedReason.secure, "Command mode is off in password fields"),
        (.notResponding, "The app isn't responding — try again"),
    ])
    func not_inserted_without_a_copy(reason: NotInsertedReason, toast: String) async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, .replaceSelection, "dog")
        h.inserter.outcomes = [.notInserted(reason)]
        await runCommand(h)

        #expect(h.state.toastMessage == toast)
        #expect(CapturePipeline.toast(for: reason) == toast)
        #expect(h.state.status == .idle)
        #expect(h.copied.read().isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func planned_copy_for_a_non_editable_field() async throws {
        let h = makeHarness(reader: reader(Self.unavailableContext(selection: "cat", isEditable: false)))
        answer(h, .replaceSelection, "dog")
        await runCommand(h)

        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read() == ["dog"])
        #expect(h.state.toastMessage == "Copied — no text field focused")
        #expect(h.state.status == .idle)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.kind == .command)
        #expect(row.insertStrategy == .copy)
        #expect(h.history.items.first?.cleanedText == "dog")
    }

    @Test(arguments: [
        (CommandAction.replaceSelection, "cat", "No changes"),
        (.insert, "", "Couldn't apply that"),
    ])
    func nothing_to_apply_shows_its_toast(action: CommandAction, text: String, toast: String) async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, action, text)
        await runCommand(h)

        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read().isEmpty)
        #expect(h.state.toastMessage == toast)
        #expect(h.state.status == .idle)
        #expect(h.history.items.isEmpty)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.insertStrategy == DictationMetrics.InsertStrategyTag.none)
        #expect(row.editAction == action.rawValue)
        #expect(row.insertMs == 0)
    }

    @Test func llm_error_says_nothing_was_changed() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.llm.commandResults = [.failure(LLMError.rateLimited)]
        await runCommand(h)

        guard case .error(let message) = h.state.status else {
            Issue.record("expected .error, got \(h.state.status)"); return
        }
        #expect(message == "\(LLMError.rateLimited.errorDescription!) Nothing was changed.")
        #expect(message.hasSuffix("Nothing was changed."))
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read().isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.recordingKind == nil)
    }

    @Test func other_error_says_nothing_was_changed() async {
        struct Boom: LocalizedError { var errorDescription: String? { "Boom." } }
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.llm.commandResults = [.failure(Boom())]
        await runCommand(h)

        #expect(h.state.status == .error("Command failed: Boom. Nothing was changed."))
        #expect(h.inserter.calls.isEmpty)
    }

    @Test(arguments: [
        TextInsertionError.pasteVerificationFailed,
        .allStrategiesFailed(["Accessibility write rejected", "Typing produced no change"]),
        .secureFieldUnsupported,
    ])
    func failed_insert_copies_instead(error: TextInsertionError) async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, .replaceSelection, "dog")
        h.inserter.outcomes = [.failed(error)]
        await runCommand(h)

        #expect(h.copied.read() == ["dog"])
        #expect(h.state.toastMessage == "Couldn't edit in place — copied, ⌘V to apply")
        #expect(h.state.status == .idle)
        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.insertStrategy == .copy)
        #expect(row.insertMs == 0)
        #expect(row.editAction == "replace_selection")
        #expect(h.history.items.first?.cleanedText == "dog")
        #expect(h.history.items.first?.rawTranscript == Self.instruction)
    }

    @Test(arguments: [
        InsertOutcome.notInserted(.fieldChanged),
        .notInserted(.cannotTarget),
        .failed(.pasteVerificationFailed),
    ])
    func a_rewrite_that_cannot_land_copies_the_whole_rewritten_text(outcome: InsertOutcome) async throws {
        let h = makeHarness(reader: reader(Self.notesContext()))
        answer(h, .rewrite, "\(CommandPrompt.cutMarker)the dog sat\(CommandPrompt.cursorMarker)")
        h.inserter.outcomes = [outcome]
        await runCommand(h)

        #expect(h.inserter.calls.first?.text == "dog")
        #expect(h.copied.read() == ["the dog sat"])
        #expect(h.history.items.first?.cleanedText == "dog")
        #expect(try #require(h.pipe.metrics.items.first).insertStrategy == .copy)
        #expect(h.state.status == .idle)
    }

    @Test func insert_failure_is_phase_2s_error_path() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.inserter.outcomes = [.failed(.accessibilityNotGranted)]
        await runCommand(h)

        #expect(h.state.status == .permissionsError(TextInsertionError.accessibilityNotGranted.errorDescription!))
        #expect(h.copied.read().isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    // MARK: - Cancel

    @Test func esc_while_editing_drops_the_result() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.llm.holdCommand = true
        defer { h.llm.releaseCommand() }
        h.pipe.startRecording(kind: .command)
        let finalize = Task { await h.pipe.finalizeRecording() }
        #expect(await eventually { h.llm.commandGate.waiting == 1 })
        #expect(h.state.status == .thinking)
        #expect(h.state.pipelinePhase == .editing)
        #expect(h.state.isCancellable)

        h.pipe.cancel()
        #expect(await finishes(finalize, within: .seconds(1)))
        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == "Cancelled")

        h.llm.releaseCommand()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copied.read().isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
        #expect(h.state.status == .idle)
    }

    @Test func shortcut_discard_is_silent() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.pipe.startRecording(kind: .command)
        #expect(h.state.recordingKind == .command)
        h.pipe.cancel(reason: .shortcut)

        #expect(h.state.status == .idle)
        #expect(h.state.toastMessage == nil)
        #expect(h.state.recordingKind == nil)
        await h.pipe.finalizeRecording()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.state.toastMessage == nil)
        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.copies.reads.read() == 0)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func the_edit_context_is_read_at_recording_start() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.pipe.startRecording(kind: .command)
        #expect(await eventually { h.reader.readCount == 1 })
        #expect(h.state.status == .recording)
        await h.pipe.finalizeRecording()
        #expect(h.reader.readCount == 1)
        #expect(h.inserter.calls.count == 1)
    }

    // MARK: - Metrics and model

    @Test func metrics_strategy_recorded() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.inserter.outcomes = [.inserted(.paste, verified: false)]
        await runCommand(h)
        #expect(try #require(h.pipe.metrics.items.first).insertStrategy == .paste)
    }

    @Test func the_command_model_overrides_the_cleanup_model() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)), commandModel: "big-model")
        await runCommand(h)
        #expect(h.llm.commandRequests.first?.model == "big-model")
        #expect(try #require(h.pipe.metrics.items.first).modelID == "big-model")
    }

    @Test func history_is_skipped_without_a_mode() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)), modes: [])
        await runCommand(h)
        #expect(h.inserter.calls.count == 1)
        #expect(h.history.items.isEmpty)
        #expect(h.state.status == .idle)
        #expect(h.pipe.metrics.items.count == 1)
    }

    // MARK: - Presets

    @Test func preset_with_selection_runs_without_recording() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.llm.holdCommand = true
        defer { h.llm.releaseCommand() }
        let preset = Task { await h.pipe.runPreset(Self.makeConcise) }
        #expect(await eventually { h.llm.commandGate.waiting == 1 })
        #expect(h.state.status == .thinking)
        #expect(h.state.activityLabel == "Make concise…")
        #expect(h.state.pipelinePhase == .editing)
        #expect(h.state.isCancellable)
        h.llm.releaseCommand()
        await preset.value

        #expect(h.capture.startCallCount == 0)
        let request = try #require(h.llm.commandRequests.first)
        #expect(request.instruction == Self.makeConcise.instruction)
        #expect(request.actions == [.replaceSelection])
        #expect(request.includesField == false)
        #expect(CommandPrompt.user(request).contains("FIELD: unavailable"))
        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .range(Self.cat, expected: "cat"))
        #expect(call.text == "transformed")
        #expect(call.trigger == .option)
        #expect(call.expected == Self.element)

        let row = try #require(h.pipe.metrics.items.first)
        #expect(row.kind == .preset)
        #expect(row.audioDuration == 0)
        #expect(row.captureTailMs == 0)
        #expect(row.transcribeMs == 0)
        #expect(row.engineID == "none")
        #expect(row.firstPartialMs == nil)
        #expect(row.editAction == "replace_selection")
        #expect(row.modelID == "test-model")
        #expect(row.totalMs >= row.cleanupMs + row.insertMs)
        let item = try #require(h.history.items.first)
        #expect(item.rawTranscript == "Make concise")
        #expect(item.cleanedText == "transformed")

        #expect(h.state.status == .idle)
        #expect(h.state.activityLabel == nil)
        #expect(h.state.toastMessage == nil)
    }

    @Test func preset_without_selection_toasts() async {
        let h = makeHarness(reader: reader(Self.notesContext(cursor: 3)))
        await h.pipe.runPreset(Self.makeConcise)

        #expect(h.state.toastMessage == "Select text to transform")
        #expect(h.state.status == .idle)
        #expect(h.state.activityLabel == nil)
        #expect(h.llm.commandRequests.isEmpty)
        #expect(h.inserter.calls.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }

    @Test func preset_copy_fallback_waits_for_the_preset_modifiers() async throws {
        let log = LockedBox<[String]>([])
        let flags = LockedBox<[CGEventFlags]>([.maskAlternate, []])
        var gate = ModifierReleaseGate.released
        gate.flagsState = {
            var next: CGEventFlags = []
            flags.mutate { queue in
                next = queue.first ?? []
                if queue.count > 1 { queue.removeFirst() }
            }
            return next
        }
        gate.sleep = { _ in log.mutate { $0.append("held") } }
        let h = makeHarness(reader: .needingCopy(), copies: ["quoted"], gate: gate, log: log)
        await h.pipe.runPreset(Self.makeConcise)

        #expect(Array(log.read().prefix(4)) == ["clipboard", "held", "copy", "command"])
        #expect(h.llm.commandRequests.first?.context.selection == SelectionInfo(text: "quoted", range: nil))
        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .liveSelection)
        #expect(call.trigger == .option)
    }

    @Test func preset_with_nothing_copied_toasts() async {
        let h = makeHarness(reader: .needingCopy(), copies: [nil])
        await h.pipe.runPreset(Self.makeConcise)

        #expect(h.copies.reads.read() == 1)
        #expect(h.state.toastMessage == "Select text to transform")
        #expect(h.llm.commandRequests.isEmpty)
    }

    @Test func preset_refusal_shows_its_toast() async {
        let h = makeHarness(reader: FakeEditContextReader(.failure(.secureField)))
        await h.pipe.runPreset(Self.makeConcise)

        #expect(h.state.toastMessage == "Command mode is off in password fields")
        #expect(h.state.status == .idle)
        #expect(h.state.activityLabel == nil)
        #expect(h.llm.commandRequests.isEmpty)
    }

    @Test func preset_ignored_while_recording() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.pipe.startRecording(kind: .dictation)
        await h.pipe.runPreset(Self.makeConcise)

        #expect(h.state.status == .recording)
        #expect(h.state.activityLabel == nil)
        #expect(h.reader.readCount == 0)
        #expect(h.llm.commandRequests.isEmpty)
        h.pipe.cancel(reason: .shortcut)
    }

    @Test func preset_runs_from_an_error() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.state.status = .error("earlier failure")
        await h.pipe.runPreset(Self.makeConcise)

        #expect(h.inserter.calls.count == 1)
        #expect(h.state.status == .idle)
    }

    @Test func preset_result_insert_is_treated_as_replace() async throws {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        answer(h, .insert, "kitty")
        await h.pipe.runPreset(Self.makeConcise)

        let call = try #require(h.inserter.calls.first)
        #expect(call.target == .range(Self.cat, expected: "cat"))
        #expect(call.text == "kitty")
        #expect(h.pipe.metrics.items.first?.editAction == "replace_selection")
    }

    @Test func esc_while_a_preset_is_editing_drops_the_result() async {
        let h = makeHarness(reader: reader(Self.notesContext(selecting: Self.cat)))
        h.llm.holdCommand = true
        defer { h.llm.releaseCommand() }
        let preset = Task { await h.pipe.runPreset(Self.makeConcise) }
        #expect(await eventually { h.llm.commandGate.waiting == 1 })

        h.pipe.cancel()
        #expect(await finishes(preset, within: .seconds(1)))
        #expect(h.state.status == .idle)
        #expect(h.state.activityLabel == nil)
        #expect(h.state.toastMessage == "Cancelled")

        h.llm.releaseCommand()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.inserter.calls.isEmpty)
        #expect(h.history.items.isEmpty)
        #expect(h.pipe.metrics.items.isEmpty)
    }
}
