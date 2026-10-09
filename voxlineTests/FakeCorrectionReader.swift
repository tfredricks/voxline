import ApplicationServices
import Foundation
@testable import voxline

/// Scripted `CorrectionReading`. Each queue answers in order, then repeats
/// its last entry. Safe to call from detached tasks.
final class FakeCorrectionReader: CorrectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private var anchors: [AnchorRead]
    private var focus: [AXRead<AXElementRef>]
    private var values: [AXRead<String>]
    private var counts = (anchor: 0, focus: 0, value: 0)
    /// When set, `anchor(for:)` blocks on it after counting the call.
    private let anchorBlock: DispatchSemaphore?

    init(anchors: [AnchorRead], focus: [AXRead<AXElementRef>] = [.absent],
         values: [AXRead<String>] = [.failed], anchorBlock: DispatchSemaphore? = nil) {
        precondition(!anchors.isEmpty && !focus.isEmpty && !values.isEmpty)
        self.anchors = anchors
        self.focus = focus
        self.values = values
        self.anchorBlock = anchorBlock
    }

    var anchorCalls: Int { lock.withLock { counts.anchor } }
    var focusCalls: Int { lock.withLock { counts.focus } }
    var valueCalls: Int { lock.withLock { counts.value } }

    func anchor(for inserted: String) -> AnchorRead {
        let read = lock.withLock {
            counts.anchor += 1
            return Self.next(&anchors)
        }
        anchorBlock?.wait()
        return read
    }

    func focusedRef() -> AXRead<AXElementRef> {
        lock.withLock {
            counts.focus += 1
            return Self.next(&focus)
        }
    }

    func value(of element: any AXTextElement) -> AXRead<String> {
        lock.withLock {
            counts.value += 1
            return Self.next(&values)
        }
    }

    /// `inserted` anchored where it first appears in `value`, caret right after it.
    static func anchored(_ element: FakeAXTextElement, value: String, inserted: String) -> AnchorRead {
        let found = (value as NSString).range(of: inserted)
        let caret = UTF16Range(location: found.location + found.length, length: 0)
        return .anchored(InsertAnchor(element: element, text: AnchorText.make(value: value, caret: caret, inserted: inserted)!))
    }

    private static func next<T>(_ queue: inout [T]) -> T {
        queue.count > 1 ? queue.removeFirst() : queue[0]
    }
}
