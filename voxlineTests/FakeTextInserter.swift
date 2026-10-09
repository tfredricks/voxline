// voxlineTests/FakeTextInserter.swift
@testable import voxline

/// Records every insert and answers from `outcomes`.
@MainActor
final class FakeTextInserter: TextInserting {
    /// Answered in order; once empty, every insert lands through Accessibility.
    var outcomes: [InsertOutcome] = []
    private(set) var calls: [(text: String, target: InsertTarget, expected: AXElementRef?, bundleID: String?, trigger: ModifierFamilies)] = []
    /// Runs as each insert is recorded, before any hold.
    var onInsert: (() -> Void)?
    /// When true, `insert` suspends until `releaseInsert()`.
    var holdInsert = false
    let insertGate = TestGate()
    func releaseInsert() { insertGate.open() }
    /// Calls to `waitForClipboardRestore`, which run `onClipboardRestoreWait`
    /// and, while `holdClipboardRestore` is true, suspend until
    /// `releaseClipboardRestore()`.
    private(set) var clipboardRestoreWaits = 0
    var onClipboardRestoreWait: (() -> Void)?
    var holdClipboardRestore = false
    let clipboardRestoreGate = TestGate()
    func releaseClipboardRestore() { clipboardRestoreGate.open() }

    func insert(_ text: String, at target: InsertTarget, expectedElement: AXElementRef?,
                bundleID: String?, trigger: ModifierFamilies) async -> InsertOutcome {
        calls.append((text, target, expectedElement, bundleID, trigger))
        onInsert?()
        if holdInsert { await insertGate.wait() }
        return outcomes.isEmpty ? .inserted(.accessibility, verified: true) : outcomes.removeFirst()
    }

    func waitForClipboardRestore() async {
        clipboardRestoreWaits += 1
        onClipboardRestoreWait?()
        if holdClipboardRestore { await clipboardRestoreGate.wait() }
    }
}
