// voxlineTests/TextInserterTests.swift
import AppKit
import ApplicationServices
import Testing
@testable import voxline

@MainActor
@Suite struct TextInserterTests {

    nonisolated private static let notes = "com.apple.Notes"
    nonisolated private static let slack = "com.tinyspeck.slackmacgap"

    struct ThrowingSnapshotter: PasteboardSnapshotting {
        func capture(from pasteboard: NSPasteboard) throws -> PasteboardSnapshot {
            throw PasteboardSnapshot.SnapshotError.refuseToClobber(reason: "test refusal")
        }
    }

    /// Forwards to a `FakeAXTextElement`, and a successful range write moves
    /// the fake's selected range the way a real field would.
    final class SelectionFollowingElement: AXTextElement, @unchecked Sendable {
        let fake: FakeAXTextElement
        init(_ fake: FakeAXTextElement) { self.fake = fake }
        var ref: AXElementRef { fake.ref }
        func string(_ attribute: String) -> AXRead<String> { fake.string(attribute) }
        func range(_ attribute: String) -> AXRead<UTF16Range> { fake.range(attribute) }
        func attributeNames() -> AXRead<[String]> { fake.attributeNames() }
        func isSettable(_ attribute: String) -> AXRead<Bool> { fake.isSettable(attribute) }
        func set(_ attribute: String, string: String, timeout: Float) -> AXError {
            fake.set(attribute, string: string, timeout: timeout)
        }
        func set(_ attribute: String, range: UTF16Range, timeout: Float) -> AXError {
            let status = fake.set(attribute, range: range, timeout: timeout)
            if status == .success { fake.ranges[attribute] = .value(range) }
            return status
        }
    }

    struct Harness {
        let inserter: TextInserter
        let paste: PasteInjector
        let board: NSPasteboard
        let pastes: LockedBox<Int>
        let typed: LockedBox<[[UInt16]]>
        let events: LockedBox<[String]>
    }

    private func editableFake(value: [AXRead<String>] = [.value("hello")]) -> FakeAXTextElement {
        let fake = FakeAXTextElement()
        fake.settable[kAXSelectedTextAttribute] = .value(true)
        fake.strings[kAXValueAttribute] = value
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 5, length: 0))
        return fake
    }

    private func makeHarness(
        focused: @escaping @Sendable () -> AXRead<any AXTextElement>,
        trusted: Bool = true,
        snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
        flags: [CGEventFlags] = [[]],
        cancelInGate: Bool = false,
        onGate: @escaping @Sendable () -> Void = {}
    ) -> Harness {
        let board = NSPasteboard(name: NSPasteboard.Name("voxline-test-\(UUID())"))
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)
        let pastes = LockedBox(0)
        let typed = LockedBox<[[UInt16]]>([])
        let events = LockedBox<[String]>([])
        let flagQueue = LockedBox(flags)

        var gate = ModifierReleaseGate()
        gate.flagsState = {
            var next: CGEventFlags = []
            flagQueue.mutate { queue in
                guard let first = queue.first else { return }
                next = first
                if queue.count > 1 { queue.removeFirst() }
            }
            return next
        }
        gate.forceClear = {}
        gate.sleep = { _ in
            events.mutate { $0.append("gate") }
            onGate()
            if cancelInGate { withUnsafeCurrentTask { $0?.cancel() } }
        }

        var pasteGate = gate
        pasteGate.sleep = { _ in
            events.mutate { $0.append("paste gate") }
            if cancelInGate { withUnsafeCurrentTask { $0?.cancel() } }
        }

        let paste = PasteInjector(
            pasteboard: board,
            snapshotter: snapshotter,
            postPaste: {
                pastes.mutate { $0 += 1 }
                events.mutate { $0.append("paste") }
            },
            gate: pasteGate,
            sleep: { _ in }
        )
        let inserter = TextInserter(
            focused: focused,
            isAccessibilityTrusted: { trusted },
            axEditor: AXTextEditor(sleep: { _ in }),
            paste: paste,
            typing: TypingInjector(post: { chunk in
                typed.mutate { $0.append(chunk) }
                events.mutate { $0.append("type") }
            }),
            gate: gate,
            postRightArrow: { events.mutate { $0.append("arrow") } },
            postDelete: { events.mutate { $0.append("delete") } },
            overrides: { InsertionPlan.Overrides() },
            sleep: { _ in }
        )
        return Harness(inserter: inserter, paste: paste, board: board, pastes: pastes, typed: typed, events: events)
    }

    private func makeHarness(element: any AXTextElement, trusted: Bool = true,
                             snapshotter: PasteboardSnapshotting = DefaultPasteboardSnapshotter(),
                             flags: [CGEventFlags] = [[]], cancelInGate: Bool = false,
                             onGate: @escaping @Sendable () -> Void = {}) -> Harness {
        makeHarness(focused: { .value(element) }, trusted: trusted, snapshotter: snapshotter, flags: flags,
                    cancelInGate: cancelInGate, onGate: onGate)
    }

    private func insert(_ h: Harness, _ text: String = " world", at target: InsertTarget = .liveSelection,
                        expectedElement: AXElementRef? = nil, bundleID: String? = TextInserterTests.notes,
                        trigger: ModifierFamilies = [.shift, .control]) async -> InsertOutcome {
        let outcome = await h.inserter.insert(text, at: target, expectedElement: expectedElement,
                                              bundleID: bundleID, trigger: trigger)
        await h.paste.pendingRestore?.value
        return outcome
    }

    // MARK: - Strategies

    @Test func ax_applied_finishes() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, expectedElement: fake.ref)

        #expect(outcome == .inserted(.accessibility, verified: true))
        #expect(fake.stringSets.map(\.value) == [" world"])
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
    }

    @Test func ax_rejected_falls_to_paste() async {
        let fake = editableFake()
        fake.setResults = [.failure]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(outcome == .inserted(.paste, verified: false))
        #expect(fake.stringSets.count == 1)
        #expect(h.pastes.read() == 1)
        #expect(h.typed.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func ax_unknown_stops() async {
        let fake = editableFake()
        fake.setResults = [.cannotComplete]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(outcome == .notInserted(.outcomeUnknown))
        #expect(fake.stringSets.count == 1)
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
    }

    @Test func paste_first_for_slack() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .inserted(.paste, verified: true))
        #expect(fake.stringSets.isEmpty)
        #expect(h.pastes.read() == 1)
    }

    @Test func web_content_goes_to_paste_first() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        fake.names = .value(["AXValue", "AXDOMIdentifier"])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(outcome == .inserted(.paste, verified: true))
        #expect(fake.stringSets.isEmpty)
    }

    @Test func posted_paste_never_falls_through() async {
        let fake = editableFake()
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .inserted(.paste, verified: false))
        #expect(h.pastes.read() == 1)
        #expect(h.typed.read().isEmpty)
        #expect(fake.stringSets.isEmpty)
    }

    @Test func snapshot_refused_falls_to_typing() async {
        let fake = editableFake(value: [])
        let h = makeHarness(element: fake, snapshotter: ThrowingSnapshotter())
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: false))
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read() == [Array(" world".utf16)])
    }

    @Test func typing_verified_when_value_changes() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake, snapshotter: ThrowingSnapshotter())
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: true))
    }

    @Test func typing_waits_for_the_release_gate() async {
        let fake = editableFake(value: [])
        let h = makeHarness(element: fake, snapshotter: ThrowingSnapshotter(), flags: [.maskShift, []])
        defer { h.board.releaseGlobally() }

        _ = await insert(h, bundleID: Self.slack, trigger: [.shift])

        #expect(h.events.read() == ["gate", "type"])
    }

    @Test func all_strategies_failed() async {
        let fake = editableFake()
        fake.setResults = [.failure]
        let h = makeHarness(element: fake, snapshotter: ThrowingSnapshotter())
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(outcome == .failed(.allStrategiesFailed([
            "Accessibility write rejected", "Clipboard paste skipped: test refusal", "Typing produced no change",
        ])))
        #expect(h.typed.read().count == 1)
    }

    @Test func all_strategies_failed_message_is_plain() {
        let error = TextInsertionError.allStrategiesFailed([
            "Accessibility write rejected", "Clipboard paste skipped: pasteboardItems was nil", "Typing produced no change",
        ])
        #expect(error.errorDescription == "Couldn't insert the text.")
        #expect(TextInsertionError.allStrategiesFailed([]).errorDescription == "Couldn't insert the text.")
    }

    // MARK: - Checks

    @Test func focus_moved() async {
        let fake = editableFake()
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, expectedElement: FakeAXTextElement(pid: 9191).ref)

        #expect(outcome == .notInserted(.focusMoved))
        #expect(fake.stringSets.isEmpty)
        #expect(h.events.read().isEmpty)
    }

    @Test func focus_absent_with_an_expected_element_is_focus_moved() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }
        #expect(await insert(h, expectedElement: FakeAXTextElement().ref) == .notInserted(.focusMoved))
        #expect(h.events.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test(arguments: [nil, FakeAXTextElement().ref] as [AXElementRef?])
    func failed_focus_read_is_not_responding(expectedElement: AXElementRef?) async {
        let h = makeHarness(focused: { .failed })
        defer { h.board.releaseGlobally() }
        #expect(await insert(h, expectedElement: expectedElement) == .notInserted(.notResponding))
        #expect(h.events.read().isEmpty)
    }

    // MARK: - No accessible focus

    @Test func no_accessible_focus_pastes_blind() async {
        let h = makeHarness(focused: { .absent }, flags: [.maskShift, []])
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: "org.alacritty", trigger: [.shift])

        #expect(outcome == .inserted(.paste, verified: false))
        #expect(h.events.read() == ["paste gate", "paste"])
        #expect(h.pastes.read() == 1)
        #expect(h.typed.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func no_accessible_focus_pastes_blind_even_for_ax_first_apps() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.notes)

        #expect(outcome == .inserted(.paste, verified: false))
        #expect(h.pastes.read() == 1)
    }

    @Test func no_accessible_focus_types_blind_when_the_snapshot_is_refused() async {
        let h = makeHarness(focused: { .absent }, snapshotter: ThrowingSnapshotter())
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(outcome == .inserted(.typing, verified: false))
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read() == [Array(" world".utf16)])
    }

    @Test func no_accessible_focus_after_live_selection_posts_the_arrow_then_pastes() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, at: .afterLiveSelection)

        #expect(outcome == .inserted(.paste, verified: false))
        #expect(h.events.read() == ["arrow", "paste"])
    }

    @Test func no_accessible_focus_cannot_target_a_range() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "hi", at: .range(UTF16Range(location: 0, length: 5), expected: "hello"))

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
    }

    @Test func no_accessible_focus_still_needs_accessibility_trust() async {
        let h = makeHarness(focused: { .absent }, trusted: false)
        defer { h.board.releaseGlobally() }
        #expect(await insert(h) == .failed(.accessibilityNotGranted))
        #expect(h.events.read().isEmpty)
    }

    @Test func secure_and_failed_checks() async {
        let secure = editableFake()
        secure.strings[kAXSubroleAttribute] = [.value(kAXSecureTextFieldSubrole as String)]
        let h1 = makeHarness(element: secure)
        defer { h1.board.releaseGlobally() }
        #expect(await insert(h1) == .notInserted(.secure))
        #expect(secure.stringSets.isEmpty)
        #expect(h1.events.read().isEmpty)

        let silent = editableFake()
        silent.strings[kAXSubroleAttribute] = [.failed]
        let h2 = makeHarness(element: silent)
        defer { h2.board.releaseGlobally() }
        #expect(await insert(h2) == .notInserted(.notResponding))
        #expect(silent.stringSets.isEmpty)
        #expect(h2.events.read().isEmpty)

        let untrusted = editableFake()
        let h3 = makeHarness(element: untrusted, trusted: false)
        defer { h3.board.releaseGlobally() }
        #expect(await insert(h3) == .failed(.accessibilityNotGranted))
        #expect(untrusted.reads.isEmpty)
        #expect(h3.events.read().isEmpty)
    }

    // MARK: - Targets

    @Test func field_changed() async {
        let fake = editableFake(value: [.value("goodbye")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "hi", at: .range(UTF16Range(location: 0, length: 5), expected: "hello"))

        #expect(outcome == .notInserted(.fieldChanged))
        #expect(fake.rangeSets.isEmpty)
        #expect(fake.stringSets.isEmpty)
    }

    @Test func range_beyond_the_value_is_field_changed() async {
        let fake = editableFake(value: [.value("hey")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "hi", at: .range(UTF16Range(location: 0, length: 5), expected: "hello"))

        #expect(outcome == .notInserted(.fieldChanged))
    }

    @Test func range_target_reads_the_value_tri_state() async {
        let failed = editableFake(value: [.failed])
        let h1 = makeHarness(element: failed)
        defer { h1.board.releaseGlobally() }
        #expect(await insert(h1, "hi", at: .range(UTF16Range(location: 0, length: 5), expected: "hello"))
                == .notInserted(.notResponding))

        let absent = editableFake(value: [])
        let h2 = makeHarness(element: absent)
        defer { h2.board.releaseGlobally() }
        #expect(await insert(h2, "hi", at: .range(UTF16Range(location: 0, length: 5), expected: "hello"))
                == .notInserted(.cannotTarget))
    }

    @Test func cannot_target() async {
        let fake = editableFake(value: [.value("hello world")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 0))
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "there", at: .range(UTF16Range(location: 6, length: 5), expected: "world"))

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(fake.rangeSets.map(\.value) == [UTF16Range(location: 6, length: 5)])
        #expect(fake.stringSets.isEmpty)
        #expect(h.events.read().isEmpty)
    }

    @Test func range_target_sets_selection_then_writes() async {
        let fake = editableFake(value: [.value("hello world"), .value("hello world"), .value("hello there")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 0))
        let h = makeHarness(element: SelectionFollowingElement(fake))
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "there", at: .range(UTF16Range(location: 6, length: 5), expected: "world"),
                                   expectedElement: fake.ref)

        #expect(outcome == .inserted(.accessibility, verified: true))
        #expect(fake.rangeSets.map(\.attribute) == [kAXSelectedTextRangeAttribute])
        #expect(fake.rangeSets.map(\.value) == [UTF16Range(location: 6, length: 5)])
        #expect(fake.rangeSets.map(\.timeout) == [2])
        #expect(fake.stringSets.map(\.attribute) == [kAXSelectedTextAttribute])
        #expect(fake.stringSets.map(\.value) == ["there"])
    }

    @Test func range_already_selected_is_not_set_again() async {
        let fake = editableFake(value: [.value("hello world"), .value("hello world"), .value("hello there")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 6, length: 5))
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "there", at: .range(UTF16Range(location: 6, length: 5), expected: "world"))

        #expect(outcome == .inserted(.accessibility, verified: true))
        #expect(fake.rangeSets.isEmpty)
    }

    @Test func after_live_selection_posts_right_arrow_after_gate() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake, flags: [.maskAlternate, []])
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, at: .afterLiveSelection, trigger: [.option])

        #expect(outcome == .inserted(.paste, verified: true))
        #expect(h.events.read() == ["gate", "arrow", "paste"])
        #expect(fake.stringSets.isEmpty)
    }

    @Test func after_live_selection_never_writes_through_ax() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake, snapshotter: ThrowingSnapshotter())
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, at: .afterLiveSelection)

        #expect(outcome == .inserted(.typing, verified: true))
        #expect(fake.stringSets.isEmpty)
        #expect(h.events.read() == ["arrow", "type"])
    }

    @Test func live_selection_posts_no_arrow() async {
        let fake = editableFake(value: [.value("hello"), .value("hello world")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        _ = await insert(h)

        #expect(h.events.read().isEmpty)
    }

    @Test func paste_focus_shift_is_pasteVerificationFailed() async {
        let fake = editableFake()
        let otherElement = FakeAXTextElement(pid: 9191)
        let calls = LockedBox(0)
        let h = makeHarness(focused: {
            calls.mutate { $0 += 1 }
            return calls.read() <= 2 ? .value(fake) : .value(otherElement)
        })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .failed(.pasteVerificationFailed))
        #expect(h.pastes.read() == 1)
        #expect(h.typed.read().isEmpty)
    }

    @Test func focus_move_before_the_cmd_v_is_focus_moved() async {
        let fake = editableFake()
        let otherElement = FakeAXTextElement(pid: 9191)
        let calls = LockedBox(0)
        let h = makeHarness(focused: {
            calls.mutate { $0 += 1 }
            return calls.read() == 1 ? .value(fake) : .value(otherElement)
        })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, bundleID: Self.slack)

        #expect(outcome == .notInserted(.focusMoved))
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func focus_move_during_the_ax_settle_skips_the_paste() async {
        let fake = editableFake()
        let otherElement = FakeAXTextElement(pid: 9191)
        let calls = LockedBox(0)
        let h = makeHarness(focused: {
            calls.mutate { $0 += 1 }
            return calls.read() == 1 ? .value(fake) : .value(otherElement)
        })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h)

        #expect(fake.stringSets.count == 1)
        #expect(outcome == .notInserted(.focusMoved))
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    // MARK: - Empty replacement

    private func selectedFake(value: [AXRead<String>]) -> FakeAXTextElement {
        let fake = editableFake(value: value)
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 6, length: 5))
        return fake
    }

    @Test func empty_replacement_of_a_range_on_paste_first_deletes_it() async {
        let fake = editableFake(value: [.value("hello world"), .value("hello world"), .value("hello ")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .value(UTF16Range(location: 0, length: 0))
        let h = makeHarness(element: SelectionFollowingElement(fake))
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", at: .range(UTF16Range(location: 6, length: 5), expected: "world"),
                                   bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: true))
        #expect(fake.rangeSets.map(\.value) == [UTF16Range(location: 6, length: 5)])
        #expect(h.events.read() == ["delete"])
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
        #expect(fake.stringSets.isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func empty_replacement_of_a_live_selection_on_paste_first_deletes_it() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello ")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: true))
        #expect(h.events.read() == ["delete"])
        #expect(h.pastes.read() == 0)
    }

    @Test func a_selection_seen_only_through_selected_text_is_deleted() async {
        let fake = editableFake(value: [.value("hello world"), .value("hello ")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .absent
        fake.strings[kAXSelectedTextAttribute] = [.value("world")]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: true))
        #expect(h.events.read() == ["delete"])
    }

    @Test func empty_text_with_nothing_selected_posts_nothing() async {
        let fake = editableFake()
        fake.strings[kAXSelectedTextAttribute] = [.value("")]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func a_selection_only_cmd_c_could_read_is_never_pasted_over_or_deleted() async {
        let fake = editableFake()
        fake.ranges[kAXSelectedTextRangeAttribute] = .absent
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
        #expect(h.typed.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func empty_text_without_accessible_focus_posts_nothing() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func a_rejected_ax_write_of_nothing_is_not_pasted() async {
        let fake = editableFake()
        fake.setResults = [.failure]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "")

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(fake.stringSets.map(\.value) == [""])
        #expect(h.events.read().isEmpty)
        #expect(h.typed.read().isEmpty)
    }

    @Test func empty_replacement_on_an_ax_first_app_writes_through_ax() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello world"), .value("hello ")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", at: .range(UTF16Range(location: 6, length: 5), expected: "world"))

        #expect(outcome == .inserted(.accessibility, verified: true))
        #expect(fake.stringSets.map(\.value) == [""])
        #expect(h.events.read().isEmpty)
    }

    @Test func a_rejected_ax_delete_falls_to_the_delete_key_not_a_paste() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello world"), .value("hello ")])
        fake.setResults = [.failure]
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "")

        #expect(outcome == .inserted(.typing, verified: true))
        #expect(fake.stringSets.map(\.value) == [""])
        #expect(h.events.read() == ["delete"])
        #expect(h.pastes.read() == 0)
    }

    @Test func delete_waits_for_the_release_gate() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello ")])
        let h = makeHarness(element: fake, flags: [.maskShift, []])
        defer { h.board.releaseGlobally() }

        _ = await insert(h, "", bundleID: Self.slack, trigger: [.shift])

        #expect(h.events.read() == ["gate", "delete"])
    }

    @Test func a_delete_that_changes_nothing_is_unverified_and_never_falls_through() async {
        let fake = selectedFake(value: [.value("hello world")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack)

        #expect(outcome == .inserted(.typing, verified: false))
        #expect(h.events.read() == ["delete"])
        #expect(h.typed.read().isEmpty)
    }

    @Test func focus_moved_while_waiting_to_delete_posts_no_delete() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello ")])
        let other = FakeAXTextElement(pid: 9191)
        let moved = LockedBox(false)
        let h = makeHarness(focused: { moved.read() ? .value(other) : .value(fake) }, flags: [.maskShift, []],
                            onGate: { moved.write(true) })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack, trigger: [.shift])

        #expect(outcome == .notInserted(.focusMoved))
        #expect(h.events.read() == ["gate"])
    }

    @Test func unreadable_focus_after_the_wait_posts_no_delete() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello ")])
        let waited = LockedBox(false)
        let h = makeHarness(focused: { waited.read() ? .failed : .value(fake) }, flags: [.maskShift, []],
                            onGate: { waited.write(true) })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack, trigger: [.shift])

        #expect(outcome == .notInserted(.focusMoved))
        #expect(h.events.read() == ["gate"])
    }

    @Test(arguments: [
        (InsertTarget.liveSelection, UTF16Range(location: 0, length: 11)),
        (.liveSelection, UTF16Range(location: 6, length: 0)),
        (.range(UTF16Range(location: 6, length: 5), expected: "world"), UTF16Range(location: 0, length: 11)),
        (.range(UTF16Range(location: 6, length: 5), expected: "world"), UTF16Range(location: 11, length: 0)),
    ])
    func a_selection_changed_while_waiting_to_delete_posts_no_delete(target: InsertTarget, changed: UTF16Range) async {
        let fake = selectedFake(value: [.value("hello world")])
        let h = makeHarness(element: fake, flags: [.maskShift, []],
                            onGate: { fake.ranges[kAXSelectedTextRangeAttribute] = .value(changed) })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", at: target, bundleID: Self.slack, trigger: [.shift])

        #expect(outcome == .notInserted(.fieldChanged))
        #expect(h.events.read() == ["gate"])
    }

    @Test func selected_text_changed_while_waiting_to_delete_posts_no_delete() async {
        let fake = editableFake(value: [.value("hello world")])
        fake.ranges[kAXSelectedTextRangeAttribute] = .absent
        fake.strings[kAXSelectedTextAttribute] = [.value("world")]
        let h = makeHarness(element: fake, flags: [.maskShift, []],
                            onGate: { fake.strings[kAXSelectedTextAttribute] = [.value("hello world")] })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: Self.slack, trigger: [.shift])

        #expect(outcome == .notInserted(.fieldChanged))
        #expect(h.events.read() == ["gate"])
    }

    // MARK: - Terminals

    @Test(arguments: InsertionPlan.terminalBundleIDs.sorted())
    func an_empty_replacement_in_a_terminal_posts_nothing(bundleID: String) async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello ")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let range = await insert(h, "", at: .range(UTF16Range(location: 6, length: 5), expected: "world"),
                                 bundleID: bundleID)
        let live = await insert(h, "", bundleID: bundleID)

        #expect(range == .notInserted(.cannotTarget))
        #expect(live == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
        #expect(h.pastes.read() == 0)
        #expect(h.typed.read().isEmpty)
        #expect(fake.stringSets.isEmpty)
        #expect(fake.rangeSets.isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func an_empty_edit_in_a_terminal_without_accessible_focus_posts_nothing() async {
        let h = makeHarness(focused: { .absent })
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "", bundleID: "io.alacritty")

        #expect(outcome == .notInserted(.cannotTarget))
        #expect(h.events.read().isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func text_in_a_terminal_still_pastes() async {
        let fake = selectedFake(value: [.value("hello world"), .value("hello world!")])
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let outcome = await insert(h, "!", bundleID: "com.apple.Terminal")

        #expect(outcome == .inserted(.paste, verified: true))
        #expect(h.events.read() == ["paste"])
    }

    // MARK: - Cancellation

    @Test(arguments: [InsertTarget.liveSelection, .afterLiveSelection])
    func a_cancelled_insert_posts_nothing(target: InsertTarget) async {
        let fake = editableFake()
        let h = makeHarness(element: fake)
        defer { h.board.releaseGlobally() }

        let task = Task { await insert(h, at: target, bundleID: Self.slack, trigger: []) }
        task.cancel()

        #expect(await task.value == .notInserted(.cancelled))
        #expect(h.events.read().isEmpty)
        #expect(h.pastes.read() == 0)
        #expect(fake.stringSets.isEmpty)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func cancel_while_waiting_for_the_release_skips_the_paste() async {
        let h = makeHarness(element: editableFake(), flags: [.maskShift, []], cancelInGate: true)
        defer { h.board.releaseGlobally() }

        let outcome = await Task { await insert(h, bundleID: Self.slack, trigger: [.shift]) }.value

        #expect(outcome == .notInserted(.cancelled))
        #expect(h.events.read() == ["paste gate"])
        #expect(h.pastes.read() == 0)
        #expect(h.board.string(forType: .string) == "ORIGINAL")
    }

    @Test func cancel_while_waiting_for_the_release_skips_typing() async {
        let h = makeHarness(element: editableFake(value: []), snapshotter: ThrowingSnapshotter(),
                            flags: [.maskShift, []], cancelInGate: true)
        defer { h.board.releaseGlobally() }

        let outcome = await Task { await insert(h, bundleID: Self.slack, trigger: [.shift]) }.value

        #expect(outcome == .notInserted(.cancelled))
        #expect(h.events.read() == ["gate"])
        #expect(h.typed.read().isEmpty)
    }

    @Test func cancel_while_waiting_for_the_release_posts_no_arrow() async {
        let h = makeHarness(element: editableFake(), flags: [.maskAlternate, []], cancelInGate: true)
        defer { h.board.releaseGlobally() }

        let outcome = await Task { await insert(h, at: .afterLiveSelection, trigger: [.option]) }.value

        #expect(outcome == .notInserted(.cancelled))
        #expect(h.events.read() == ["gate"])
    }

    @Test func cancel_while_waiting_for_the_release_posts_no_delete() async {
        let fake = selectedFake(value: [.value("hello world")])
        let h = makeHarness(element: fake, flags: [.maskShift, []], cancelInGate: true)
        defer { h.board.releaseGlobally() }

        let outcome = await Task { await insert(h, "", bundleID: Self.slack, trigger: [.shift]) }.value

        #expect(outcome == .notInserted(.cancelled))
        #expect(h.events.read() == ["gate"])
    }

    // MARK: - Clipboard restore

    @Test(.timeLimit(.minutes(1)))
    func waitForClipboardRestore_returns_once_the_paste_restore_has_run() async {
        let board = NSPasteboard(name: NSPasteboard.Name("voxline-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("ORIGINAL", forType: .string)
        let clock = ManualClock()
        let posts = LockedBox(0)
        let paste = PasteInjector(
            pasteboard: board,
            postPaste: { posts.mutate { $0 += 1 } },
            gate: .released,
            sleep: { @MainActor in try await clock.sleep($0) }
        )
        let inserter = TextInserter(
            focused: { .absent },
            isAccessibilityTrusted: { true },
            axEditor: AXTextEditor(sleep: { _ in }),
            paste: paste,
            typing: TypingInjector(post: { _ in }),
            gate: .released,
            postRightArrow: {},
            overrides: { InsertionPlan.Overrides() },
            sleep: { _ in }
        )

        let insert = Task { await inserter.insert("PASTED", at: .liveSelection, expectedElement: nil, bundleID: nil, trigger: []) }
        #expect(await eventually { clock.pendingCount == 1 })
        await clock.advance(by: .milliseconds(50))
        #expect(await eventually { posts.read() == 1 && clock.pendingCount == 2 })
        await clock.advance(by: .milliseconds(300))
        #expect(await insert.value == .inserted(.paste, verified: false))

        let restored = LockedBox(false)
        let wait = Task { await inserter.waitForClipboardRestore(); restored.write(true) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!restored.read())

        await clock.advance(by: .seconds(2))
        await wait.value
        #expect(restored.read())
        #expect(board.string(forType: .string) == "ORIGINAL")
    }
}
