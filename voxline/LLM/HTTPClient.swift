import Foundation

/// Network seam so tests can run without URLSession or sandbox networking.
/// Both AnthropicClient and OpenAIClient depend on this rather than
/// URLSession directly.
protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
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
