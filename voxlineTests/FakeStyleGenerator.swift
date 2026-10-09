import Foundation
@testable import voxline

/// Records each request and answers `result`; holds while `hold` is true until `release()`.
final class FakeStyleGenerator: StyleNoteGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [StyleNoteRequest] = []
    private var _result: Result<String, Error> = .success("- Uses contractions.")
    private var _hold = false
    private let gate = TestGate()

    var requests: [StyleNoteRequest] { lock.withLock { _requests } }
    var result: Result<String, Error> {
        get { lock.withLock { _result } }
        set { lock.withLock { _result = newValue } }
    }
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }

    func release() { gate.open() }

    func styleNote(_ request: StyleNoteRequest) async throws -> String {
        let holds = lock.withLock {
            _requests.append(request)
            return _hold
        }
        if holds { await gate.wait() }
        return try result.get()
    }
}
