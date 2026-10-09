import Foundation

extension CapturePipeline {

    /// One recording's transcription plumbing: the engine chosen at start,
    /// the router capture feeds, the session opening behind it, and the
    /// consumer forwarding its live partials.
    @MainActor
    final class LiveSession {
        let engine: any TranscriptionEngine
        let router: StreamingSampleRouter
        private var startedAt: ContinuousClock.Instant?
        private var firstPartialAt: ContinuousClock.Instant?
        private var sessionTask: Task<any TranscriptionSession, Error>?
        private var partialsTask: Task<Void, Never>?
        private var isClosed = false

        init(engine: any TranscriptionEngine) {
            self.engine = engine
            router = StreamingSampleRouter(retainsAudio: engine.capabilities.contains(.sendsAudioOffDevice))
        }

        /// Recording start → first non-empty partial, or nil if none arrived.
        var timeToFirstPartial: Duration? {
            guard let startedAt, let firstPartialAt else { return nil }
            return startedAt.duration(to: firstPartialAt)
        }

        /// Opens the session off the keypress path; call once capture has
        /// started. Audio captured meanwhile waits in the router. The session
        /// is attached inside the opening task, so `session()` never returns
        /// one that is missing early audio. `onPartial` runs on the main actor
        /// for each partial until `close()`.
        func open(vocabulary: @escaping @Sendable () -> [String], onPartial: @escaping @MainActor (TranscriptPartial) -> Void) {
            startedAt = .now
            let engine = engine
            let router = router
            sessionTask = Task { [weak self] in
                let session = try await engine.openSession(SessionConfig(vocabularyHints: vocabulary()))
                router.attach(session)
                self?.observe(session, onPartial: onPartial)
                return session
            }
        }

        func session() async throws -> any TranscriptionSession {
            guard let sessionTask else { throw CancellationError() }
            return try await sessionTask.value
        }

        /// Waits for the open to settle, then cancels the session if it opened.
        func cancel() async {
            (try? await session())?.cancel()
        }

        /// Stops feeding and observing the session. The session itself must
        /// already be finished or cancelled.
        func close() {
            isClosed = true
            router.close()
            partialsTask?.cancel()
            partialsTask = nil
        }

        private func observe(_ session: any TranscriptionSession, onPartial: @escaping @MainActor (TranscriptPartial) -> Void) {
            guard !isClosed else { return }
            partialsTask = Task { [weak self] in
                for await partial in session.partials {
                    guard let self, !self.isClosed else { return }
                    if self.firstPartialAt == nil, !partial.isEmpty {
                        self.firstPartialAt = .now
                    }
                    onPartial(partial)
                }
            }
        }
    }
}
