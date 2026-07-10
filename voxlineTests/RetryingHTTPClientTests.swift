import Testing
import Foundation
@testable import voxline

@Suite struct RetryingHTTPClientTests {

    /// Returns queued (data, status) pairs in order; records the call count.
    /// (MockHTTPClient returns one fixed stub, which can't express
    /// "429 then 200", hence a dedicated sequenced double here.)
    final class SequencedHTTPClient: HTTPClient, @unchecked Sendable {
        private var responses: [(data: Data, status: Int)]
        private(set) var callCount = 0
        init(_ responses: [(data: Data, status: Int)]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            callCount += 1
            let next = responses.isEmpty ? (data: Data(), status: 200) : responses.removeFirst()
            let http = HTTPURLResponse(
                url: request.url!, statusCode: next.status,
                httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (next.data, http)
        }
    }

    private func request() -> URLRequest {
        URLRequest(url: URL(string: "https://api.example.com/v1/messages")!)
    }

    private func makeClient(_ inner: HTTPClient) -> RetryingHTTPClient {
        var client = RetryingHTTPClient(wrapped: inner)
        client.sleeper = { _ in }  // no real sleeping in tests; closure type inferred
        return client
    }

    @Test func successPassesThroughWithoutRetry() async throws {
        let inner = SequencedHTTPClient([(Data("ok".utf8), 200)])
        let (data, response) = try await makeClient(inner).send(request())
        #expect(response.statusCode == 200)
        #expect(data == Data("ok".utf8))
        #expect(inner.callCount == 1)
    }

    @Test func retriesOnceOn429ThenSucceeds() async throws {
        let inner = SequencedHTTPClient([(Data(), 429), (Data("ok".utf8), 200)])
        let (data, response) = try await makeClient(inner).send(request())
        #expect(response.statusCode == 200)
        #expect(data == Data("ok".utf8))
        #expect(inner.callCount == 2)
    }

    @Test func retriesOnceOn504ThenSucceeds() async throws {
        let inner = SequencedHTTPClient([(Data(), 504), (Data("ok".utf8), 200)])
        let (data, response) = try await makeClient(inner).send(request())
        #expect(response.statusCode == 200)
        #expect(data == Data("ok".utf8))
        #expect(inner.callCount == 2)
    }

    @Test func retriesOnceOn529ThenReturnsTheSecondFailure() async throws {
        let inner = SequencedHTTPClient([(Data(), 529), (Data(), 529)])
        let (_, response) = try await makeClient(inner).send(request())
        #expect(response.statusCode == 529, "exactly one retry; the second failure is returned for normal error mapping")
        #expect(inner.callCount == 2)
    }

    @Test func nonTransient400IsNotRetried() async throws {
        let inner = SequencedHTTPClient([(Data(), 400)])
        let (_, response) = try await makeClient(inner).send(request())
        #expect(response.statusCode == 400)
        #expect(inner.callCount == 1)
    }

    @Test func transportErrorsPropagateWithoutRetry() async throws {
        // URLSessionHTTPClient already owns the -1005 retry; a timeout here
        // must not be retried on top (it would double the worst-case wait).
        final class ThrowingClient: HTTPClient, @unchecked Sendable {
            private(set) var callCount = 0
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                callCount += 1
                throw URLError(.timedOut)
            }
        }
        let inner = ThrowingClient()
        let client = makeClient(inner)
        await #expect(throws: URLError.self) {
            _ = try await client.send(self.request())
        }
        #expect(inner.callCount == 1)
    }
}
