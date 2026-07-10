import Foundation

/// Decorates another HTTPClient with a single retry on transient provider
/// failures. Both providers document 429 and 5xx (Anthropic adds 529
/// "overloaded") as retryable; without this, one momentary blip destroys an
/// already-transcribed dictation and the user has to re-speak everything.
/// Exactly one retry after a short flat delay — enough to ride out a blip,
/// bounded enough that the pipeline (which blocks new dictations while
/// waiting) stays responsive. Transport errors pass straight through:
/// URLSessionHTTPClient owns the -1005 quirk, and retrying a timeout would
/// double the worst-case wait.
struct RetryingHTTPClient: HTTPClient {
    let wrapped: HTTPClient
    var retryDelay: Duration = .seconds(1)
    /// Injectable so tests don't sleep for real.
    var sleeper: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    static let transientStatuses: Set<Int> = [429, 500, 502, 503, 529]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let first = try await wrapped.send(request)
        guard Self.transientStatuses.contains(first.1.statusCode) else {
            return first
        }
        AppLog.llm.info("transient HTTP \(first.1.statusCode); retrying once")
        try await sleeper(retryDelay)
        return try await wrapped.send(request)
    }
}
