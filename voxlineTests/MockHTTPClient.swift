import Foundation
@testable import voxline

/// Test double that captures the outbound request and returns a canned
/// `(data, status)` pair. Used by AnthropicClientTests, OpenAIClientTests, and
/// any other suite that needs to exercise an `HTTPClient` boundary.
final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var capturedRequest: URLRequest?
    var stubResponse: (data: Data, status: Int) = (Data(), 200)
    var stubError: Error?

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequest = request
        if let stubError { throw stubError }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: stubResponse.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (stubResponse.data, http)
    }
}
