// voxline/Output/TextInserter.swift
import ApplicationServices
import Foundation

enum InsertTarget: Equatable, Sendable {
    case liveSelection
    /// Posts a Right Arrow, then inserts with paste or typing only: the arrow
    /// is an async key event, and an AX write could land before it and
    /// replace the selection. Paste and typing queue behind it.
    case afterLiveSelection
    /// Selects `range` first, provided the field's text there is still `expected`.
    case range(UTF16Range, expected: String)
}

enum NotInsertedReason: Equatable, Sendable {
    case focusMoved, fieldChanged, cannotTarget, outcomeUnknown, notResponding, secure
    /// The calling task was cancelled before anything was posted or written.
    case cancelled
}

enum InsertOutcome: Equatable {
    case inserted(InsertStrategy, verified: Bool)
    case notInserted(NotInsertedReason)
    case failed(TextInsertionError)
}

@MainActor
protocol TextInserting: AnyObject {
    func insert(_ text: String, at target: InsertTarget, expectedElement: AXElementRef?,
                bundleID: String?, trigger: ModifierFamilies) async -> InsertOutcome
    /// Returns once an earlier paste has put the user's clipboard back, so
    /// a synthetic Cmd+C never snapshots voxline's own pasted item.
    func waitForClipboardRestore() async
}

/// The one way voxline puts text into another app: checks, targets, then
/// runs `InsertionPlan`'s strategies until one lands.
@MainActor
final class TextInserter: TextInserting {

    private let focused: @Sendable () -> AXRead<any AXTextElement>
    private let isAccessibilityTrusted: @Sendable () -> Bool
    private let axEditor: AXTextEditor
    private let paste: PasteInjector
    private let typing: TypingInjector
    private let gate: ModifierReleaseGate
    private let postRightArrow: @Sendable () -> Void
    private let postDelete: @Sendable () -> Void
    private let overrides: @Sendable () -> InsertionPlan.Overrides
    private let sleep: @Sendable (Duration) async throws -> Void
    private let typingVerifyDelay: Duration

    init(focused: @escaping @Sendable () -> AXRead<any AXTextElement> = {
             LiveFocusedElementSource.readElement().map { LiveAXTextElement(element: $0.element) }
         },
         isAccessibilityTrusted: @escaping @Sendable () -> Bool = { AXIsProcessTrusted() },
         axEditor: AXTextEditor = AXTextEditor(),
         paste: PasteInjector,
         typing: TypingInjector = TypingInjector(),
         gate: ModifierReleaseGate = ModifierReleaseGate(),
         postRightArrow: @escaping @Sendable () -> Void = { SyntheticKeys.postRightArrow() },
         postDelete: @escaping @Sendable () -> Void = { SyntheticKeys.postDelete() },
         overrides: @escaping @Sendable () -> InsertionPlan.Overrides = { InsertionPlan.Overrides.load(from: .standard) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         typingVerifyDelay: Duration = .milliseconds(150)) {
        self.focused = focused
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.axEditor = axEditor
        self.paste = paste
        self.typing = typing
        self.gate = gate
        self.postRightArrow = postRightArrow
        self.postDelete = postDelete
        self.overrides = overrides
        self.sleep = sleep
        self.typingVerifyDelay = typingVerifyDelay
    }

    /// A strategy that may have inserted never falls through: an AX write
    /// that timed out is `outcomeUnknown`, and a posted Cmd+V is `inserted`
    /// (or `pasteVerificationFailed` when focus moved during it). Focus that
    /// moves before the Cmd+V is posted is `focusMoved`. Only a rejected AX
    /// write, a refused clipboard snapshot, a clipboard that something else
    /// wrote before the Cmd+V (left as it is), or typing that left the value
    /// unchanged moves on to the next strategy.
    ///
    /// An app that exposes no focused element (a terminal like Alacritty, a
    /// VM or remote-desktop window) gets an unverified paste, then typing, as
    /// earlier versions did, unless `expectedElement` was given (`focusMoved`) or the
    /// target is a range it can't check (`cannotTarget`).
    ///
    /// An empty `text` is never pasted or typed. When it replaces a selection
    /// the element shows as non-empty (a `.range` of non-zero length, or a
    /// live selection) it is a deletion: an AX write of "" deletes it as
    /// usual, and the first paste or typing step in the plan posts a single
    /// Backspace instead, after the release gate and only while the same
    /// element is focused (else `focusMoved`) with the same selection (else
    /// `fieldChanged`). It is verified like typing, reported as `.typing`,
    /// and never falls through. With no selection the element shows (one
    /// only Cmd+C could read), no accessible focus, or an element whose
    /// kAXValue isn't settable (read-only content, such as a web page or a
    /// message being read), that step is `cannotTarget` and posts nothing.
    /// In a terminal (`InsertionPlan.isTerminal`) an empty `text` is
    /// `cannotTarget` before anything is read: the selection there is
    /// scrollback.
    ///
    /// Once the calling task is cancelled nothing more is selected, posted, or
    /// written: the insert checks on entry, before each strategy, and after
    /// every release-gate wait, and returns `cancelled`.
    func insert(_ text: String, at target: InsertTarget, expectedElement: AXElementRef?,
                bundleID: String?, trigger: ModifierFamilies) async -> InsertOutcome {
        guard isAccessibilityTrusted() else { return .failed(.accessibilityNotGranted) }
        guard !Task.isCancelled else { return notInserted(.cancelled) }
        if text.isEmpty, InsertionPlan.isTerminal(bundleID) {
            AppLog.paste.debug("insert: a terminal can't delete its selection")
            return notInserted(.cannotTarget)
        }

        let element: any AXTextElement
        switch focused() {
        case .value(let focusedElement): element = focusedElement
        case .absent:
            guard expectedElement == nil else { return notInserted(.focusMoved) }
            return await insertWithoutFocus(text, at: target, trigger: trigger)
        case .failed: return notInserted(.notResponding)
        }
        if let expectedElement, element.ref != expectedElement { return notInserted(.focusMoved) }
        let subrole = element.string(kAXSubroleAttribute)
        if subrole.isFailed { return notInserted(.notResponding) }
        if subrole.value == (kAXSecureTextFieldSubrole as String) { return notInserted(.secure) }

        switch target {
        case .liveSelection:
            break
        case .afterLiveSelection:
            try? await gate.wait(for: trigger)
            guard !Task.isCancelled else { return notInserted(.cancelled) }
            postRightArrow()
        case .range(let range, let expected):
            if let reason = select(range, expected: expected, in: element) { return notInserted(reason) }
        }

        let traits = InsertionPlan.Traits(
            bundleID: bundleID,
            attributeNames: element.attributeNames().value ?? [],
            selectedTextSettable: element.isSettable(kAXSelectedTextAttribute) == .value(true)
        )
        var plan = InsertionPlan.strategies(for: traits, overrides: overrides())
        if target == .afterLiveSelection { plan.removeAll { $0 == .accessibility } }
        let deletion = text.isEmpty ? Self.deletion(for: target, in: element) : nil
        AppLog.paste.debug("insert plan: \(plan.map(\.rawValue).joined(separator: ", "), privacy: .public)\(deletion != nil ? " (deleting)" : "", privacy: .public)")
        return await run(plan, text: text, element: element, trigger: trigger, deletion: deletion)
    }

    func waitForClipboardRestore() async {
        await paste.pendingRestore?.value
    }

    private func insertWithoutFocus(_ text: String, at target: InsertTarget, trigger: ModifierFamilies) async -> InsertOutcome {
        switch target {
        case .liveSelection:
            break
        case .afterLiveSelection:
            try? await gate.wait(for: trigger)
            guard !Task.isCancelled else { return notInserted(.cancelled) }
            postRightArrow()
        case .range:
            return notInserted(.cannotTarget)
        }
        AppLog.paste.debug("insert: no focused element; pasting unverified")
        return await run([.paste, .typing], text: text, element: nil, trigger: trigger)
    }

    /// With no `element`, nothing can be verified: a posted paste or typed
    /// text is `inserted(_, verified: false)`, and an AX write is skipped.
    private func run(_ plan: [InsertStrategy], text: String, element: (any AXTextElement)?,
                     trigger: ModifierFamilies, deletion: Deletion? = nil) async -> InsertOutcome {
        var failures: [String] = []
        for strategy in plan {
            guard !Task.isCancelled else { return notInserted(.cancelled) }
            if text.isEmpty, strategy != .accessibility {
                guard let deletion, let element else {
                    AppLog.paste.debug("insert: no selection to delete; posting nothing")
                    return notInserted(.cannotTarget)
                }
                guard element.isSettable(kAXValueAttribute) == .value(true) else {
                    AppLog.paste.debug("insert: the focused element isn't editable; posting no delete key")
                    return notInserted(.cannotTarget)
                }
                return await deleteSelection(deletion, in: element, trigger: trigger)
            }
            switch strategy {
            case .accessibility:
                guard let element else { continue }
                switch await axEditor.replaceSelection(of: element, with: text) {
                case .applied(let verified):
                    return inserted(.accessibility, verified: verified)
                case .rejected:
                    failures.append("Accessibility write rejected")
                    AppLog.paste.debug("insert: ax rejected; moving on")
                case .unknown:
                    AppLog.paste.debug("insert: ax write timed out and never showed up; stopping")
                    return notInserted(.outcomeUnknown)
                }
            case .paste:
                let currentRef: @Sendable () -> AXElementRef? = { [focused] in focused().value?.ref }
                switch await paste.paste(text, element: element, trigger: trigger, focused: currentRef) {
                case .pasted(let verified):
                    return inserted(.paste, verified: verified)
                case .snapshotRefused(let reason):
                    failures.append("Clipboard paste skipped: \(reason)")
                    AppLog.paste.debug("insert: paste refused (\(reason, privacy: .public)); moving on")
                case .clipboardChangedBeforePaste:
                    failures.append("Clipboard paste skipped: the clipboard changed before the paste")
                    AppLog.paste.debug("insert: clipboard changed before the paste; moving on")
                case .focusMovedBeforePaste:
                    return notInserted(.focusMoved)
                case .cancelled:
                    return notInserted(.cancelled)
                case .focusMoved:
                    AppLog.paste.debug("insert: focus moved during the paste")
                    return .failed(.pasteVerificationFailed)
                }
            case .typing:
                try? await gate.wait(for: trigger)
                guard !Task.isCancelled else { return notInserted(.cancelled) }
                let before = element?.string(kAXValueAttribute).value
                typing.type(text)
                try? await sleep(typingVerifyDelay)
                let after = element?.string(kAXValueAttribute).value
                guard let before, let after else { return inserted(.typing, verified: false) }
                if before != after { return inserted(.typing, verified: true) }
                failures.append("Typing produced no change")
                AppLog.paste.debug("insert: typing produced no change")
            }
        }
        AppLog.paste.info("insert: all strategies failed: \(failures.joined(separator: "; "), privacy: .public)")
        return .failed(.allStrategiesFailed(failures))
    }

    private func deleteSelection(_ deletion: Deletion, in element: any AXTextElement, trigger: ModifierFamilies) async -> InsertOutcome {
        try? await gate.wait(for: trigger)
        guard !Task.isCancelled else { return notInserted(.cancelled) }
        let before = element.string(kAXValueAttribute).value
        guard focused().value?.ref == element.ref else {
            AppLog.paste.debug("insert: focus moved before the delete key")
            return notInserted(.focusMoved)
        }
        guard Self.stillSelected(deletion, in: element) else {
            AppLog.paste.debug("insert: selection changed before the delete key")
            return notInserted(.fieldChanged)
        }
        postDelete()
        try? await sleep(typingVerifyDelay)
        let after = element.string(kAXValueAttribute).value
        guard let before, let after else { return inserted(.typing, verified: false) }
        return inserted(.typing, verified: before != after)
    }

    /// The selection an empty `text` deletes, as the element showed it.
    private enum Deletion {
        case range(UTF16Range)
        case selectedText(String)
    }

    /// A `.range` has been selected and checked by `select`; a live
    /// selection counts only when the element reports it, by range or, when
    /// the range is unreadable, by selected text.
    private static func deletion(for target: InsertTarget, in element: any AXTextElement) -> Deletion? {
        switch target {
        case .range(let range, _):
            return range.length > 0 ? .range(range) : nil
        case .afterLiveSelection:
            return nil
        case .liveSelection:
            if let range = element.range(kAXSelectedTextRangeAttribute).value {
                return range.length > 0 ? .range(range) : nil
            }
            let selected = element.string(kAXSelectedTextAttribute).value ?? ""
            return selected.isEmpty ? nil : .selectedText(selected)
        }
    }

    private static func stillSelected(_ deletion: Deletion, in element: any AXTextElement) -> Bool {
        switch deletion {
        case .range(let range): return element.range(kAXSelectedTextRangeAttribute) == .value(range)
        case .selectedText(let text): return element.string(kAXSelectedTextAttribute) == .value(text)
        }
    }

    private func select(_ range: UTF16Range, expected: String, in element: any AXTextElement) -> NotInsertedReason? {
        let value: String
        switch element.string(kAXValueAttribute) {
        case .value(let read): value = read
        case .absent: return .cannotTarget
        case .failed: return .notResponding
        }
        let text = value as NSString
        guard range.fits(in: text.length), text.substring(with: range.nsRange) == expected else {
            return .fieldChanged
        }
        guard element.range(kAXSelectedTextRangeAttribute) != .value(range) else { return nil }
        _ = element.set(kAXSelectedTextRangeAttribute, range: range, timeout: axEditor.writeTimeout)
        guard element.range(kAXSelectedTextRangeAttribute) == .value(range) else { return .cannotTarget }
        return nil
    }

    private func inserted(_ strategy: InsertStrategy, verified: Bool) -> InsertOutcome {
        AppLog.paste.debug("insert: \(strategy.rawValue, privacy: .public) landed, \(verified ? "verified" : "unverified", privacy: .public)")
        return .inserted(strategy, verified: verified)
    }

    private func notInserted(_ reason: NotInsertedReason) -> InsertOutcome {
        AppLog.paste.debug("insert: not inserted (\(String(describing: reason), privacy: .public))")
        return .notInserted(reason)
    }
}
