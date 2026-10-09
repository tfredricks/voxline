// voxlineTests/FakeEditContextReader.swift
import Foundation
@testable import voxline

/// Answers `read()` from `results` in order, then repeats the last one.
final class FakeEditContextReader: EditContextReading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<EditContext, EditContextRefusal>]
    private var reads = 0

    init(_ results: Result<EditContext, EditContextRefusal>...) {
        precondition(!results.isEmpty)
        self.results = results
    }

    var readCount: Int { lock.withLock { reads } }

    func read() -> Result<EditContext, EditContextRefusal> {
        lock.withLock {
            reads += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }

    /// An editable field whose selection AX couldn't read, so a command runs
    /// the Cmd+C fallback and its `SelectionSnapshotting` decides the selection.
    static func needingCopy(isEditable: Bool = true) -> FakeEditContextReader {
        FakeEditContextReader(.success(EditContext(
            isEditable: isEditable, element: nil, field: nil, selection: nil, cursor: nil, needsCopyFallback: true
        )))
    }
}

extension ModifierReleaseGate {
    /// Sees no modifier held, so it never sleeps or force-clears.
    static let released: ModifierReleaseGate = {
        var gate = ModifierReleaseGate()
        gate.flagsState = { [] }
        gate.forceClear = {}
        gate.sleep = { _ in }
        return gate
    }()
}
