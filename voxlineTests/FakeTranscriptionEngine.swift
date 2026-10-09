import Foundation
@testable import voxline

final class FakeTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _appended: [[Float]] = []
    private var continuation: AsyncStream<TranscriptPartial>.Continuation?
    let partials: AsyncStream<TranscriptPartial>
    var finishResult: Result<String, Error> = .success("hello world")
    /// When true, finish() suspends until `releaseFinish()` or `cancel()`.
    var holdFinish = false
    /// When true, finish() and cancel() leave `partials` open, like a
    /// misbehaving engine, so later `emit` calls still reach any listener.
    var keepsPartialsOpen = false
    /// When true, `cancel()` neither releases a held `finish()` nor makes it
    /// throw, like an engine that ignores cancellation.
    var ignoresCancel = false
    private var finishWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private var _cancelCount = 0
    private var _finishCount = 0

    init() {
        var c: AsyncStream<TranscriptPartial>.Continuation!
        partials = AsyncStream { c = $0 }
        continuation = c
    }

    var appended: [[Float]] { lock.withLock { _appended } }
    var appendedSampleCount: Int { appended.reduce(0) { $0 + $1.count } }
    var cancelCount: Int { lock.withLock { _cancelCount } }
    var finishCount: Int { lock.withLock { _finishCount } }
    /// Whether a `finish()` call is suspended on `holdFinish` right now.
    var isHoldingFinish: Bool { lock.withLock { finishWaiter != nil } }

    func append(_ samples: [Float]) { lock.withLock { _appended.append(samples) } }

    func emit(_ partial: TranscriptPartial) { continuation?.yield(partial) }

    func finish() async throws -> String {
        lock.withLock { _finishCount += 1 }
        if holdFinish, !lock.withLock({ released }) {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                let alreadyReleased = lock.withLock { () -> Bool in
                    if released { return true }
                    finishWaiter = k
                    return false
                }
                if alreadyReleased { k.resume() }
            }
        }
        if !ignoresCancel, lock.withLock({ _cancelCount > 0 }) { throw CancellationError() }
        if !keepsPartialsOpen { continuation?.finish() }
        return try finishResult.get()
    }

    func releaseFinish() {
        let k = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { finishWaiter = nil }
            return finishWaiter
        }
        k?.resume()
    }

    func cancel() {
        lock.withLock { _cancelCount += 1 }
        if !keepsPartialsOpen { continuation?.finish() }
        if !ignoresCancel { releaseFinish() }
    }
}

@MainActor
final class FakeTranscriptionEngine: TranscriptionEngine {
    let id: EngineID
    var metricsID: String
    var capabilities: EngineCapabilities
    var readinessValue: EngineReadiness = .ready
    var openError: Error?
    /// When true, `openSession` suspends until `releaseOpen()`, ignoring
    /// cancellation, like a cloud engine on a dead network or a model still
    /// loading.
    var holdsOpen = false
    private var openWaiters: [CheckedContinuation<Void, Never>] = []
    var prepareCount = 0
    var openedConfigs: [SessionConfig] = []
    /// Sessions handed out, in order. Pre-seed `nextSessions` to control them.
    var nextSessions: [FakeTranscriptionSession] = []
    private(set) var sessions: [FakeTranscriptionSession] = []

    init(id: EngineID = .whisperKit, metricsID: String = "fake:engine", capabilities: EngineCapabilities = [.streamingPartials]) {
        self.id = id
        self.metricsID = metricsID
        self.capabilities = capabilities
    }

    func readiness() async -> EngineReadiness { readinessValue }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { prepareCount += 1; progress(1) }

    func openSession(_ config: SessionConfig) async throws -> any TranscriptionSession {
        openedConfigs.append(config)
        if holdsOpen {
            await withCheckedContinuation { openWaiters.append($0) }
        }
        if let openError { throw openError }
        let s = nextSessions.isEmpty ? FakeTranscriptionSession() : nextSessions.removeFirst()
        sessions.append(s)
        return s
    }

    /// Lets every held and later `openSession` through.
    func releaseOpen() {
        holdsOpen = false
        let waiters = openWaiters
        openWaiters = []
        for waiter in waiters { waiter.resume() }
    }
}

@MainActor
final class FakeEngineProvider: TranscriptionEngineProviding {
    var engines: [EngineID: any TranscriptionEngine]
    var currentID: EngineID

    init(_ engine: any TranscriptionEngine) {
        engines = [engine.id: engine]
        currentID = engine.id
    }

    /// Registers `engine` under its id without making it current.
    func add(_ engine: any TranscriptionEngine) {
        engines[engine.id] = engine
    }

    var current: any TranscriptionEngine { engines[currentID]! }
    func engine(for id: EngineID) -> any TranscriptionEngine { engines[id] ?? engines[currentID]! }
}
