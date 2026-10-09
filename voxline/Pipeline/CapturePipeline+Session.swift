import Foundation

extension CapturePipeline {

    /// One recording's transcription plumbing: the engine chosen at start,
    /// the router capture feeds, the session opening behind it, and the
    /// consumer forwarding its live partials.
    @MainActor
    final class LiveSession {
        let engine: any TranscriptionEngine
        let config: SessionConfig
        let router: StreamingSampleRouter
        /// Whether the recording is saved as a bake-off clip once inserted.
        let savesBakeoffClip: Bool
        private var startedAt: ContinuousClock.Instant?
        private var firstPartialAt: ContinuousClock.Instant?
        private var sessionTask: Task<any TranscriptionSession, Error>?
        private var openedSession: (any TranscriptionSession)?
        private var partialsTask: Task<Void, Never>?
        private var isClosed = false

        /// The router keeps the audio for a bake-off clip, and for a cloud
        /// engine so a failed session can be redone on-device.
        init(engine: any TranscriptionEngine, config: SessionConfig, savesBakeoffClip: Bool) {
            self.engine = engine
            self.config = config
            self.savesBakeoffClip = savesBakeoffClip
            router = StreamingSampleRouter(retainsAudio: savesBakeoffClip || engine.capabilities.contains(.sendsAudioOffDevice))
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
        func open(onPartial: @escaping @MainActor (TranscriptPartial) -> Void) {
            startedAt = .now
            let engine = engine
            let config = config
            let router = router
            sessionTask = Task { [weak self] in
                let session = try await engine.openSession(config)
                guard !Task.isCancelled else {
                    session.cancel()
                    throw CancellationError()
                }
                router.attach(session)
                self?.openedSession = session
                self?.observe(session, onPartial: onPartial)
                return session
            }
        }

        func session() async throws -> any TranscriptionSession {
            guard let sessionTask else { throw CancellationError() }
            return try await sessionTask.value
        }

        /// Cancels the session now, or as soon as it opens, without waiting,
        /// then closes.
        func discard() {
            sessionTask?.cancel()
            openedSession?.cancel()
            close()
        }

        /// Stops feeding and observing the session, and lets go of the
        /// retained audio. The session itself must already be finished or
        /// cancelled.
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
