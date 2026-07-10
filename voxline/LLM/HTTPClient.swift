import Foundation

/// Network seam so tests can run without URLSession or sandbox networking.
/// Both AnthropicClient and OpenAIClient depend on this rather than
/// URLSession directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    /// Dedicated session, not .shared: a hung provider must not freeze a
    /// dictation for the 60s system default (the pipeline blocks new
    /// recordings the whole time). 15s idle / 30s total is generous for a
    /// few hundred tokens of cleanup. .ephemeral keeps transcripts and API
    /// responses out of any on-disk URL cache.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    init(session: URLSession = URLSessionHTTPClient.makeSession()) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await perform(request)
        } catch let err as URLError where err.code == .networkConnectionLost {
            // URLSession sometimes hands out a pooled HTTPS connection that the
            // peer has already half-closed (Apple DTS-known quirk on .shared).
            // Symptom: -1005 on the first real request after an idle period,
            // while a fresh request that follows succeeds. One retry on this
            // specific code is the standard remedy; do not retry on other
            // URLErrors so genuine failures still surface immediately.
            AppLog.llm.debug("network connection lost, retrying once")
            return try await perform(request)
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
