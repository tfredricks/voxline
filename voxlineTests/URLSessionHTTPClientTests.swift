import Testing
import Foundation
@testable import voxline

@Suite struct URLSessionHTTPClientTests {

    @Test func defaultSessionHasDictationScaleTimeouts() {
        let client = URLSessionHTTPClient()
        let config = client.session.configuration
        #expect(config.timeoutIntervalForRequest == 15)
        #expect(config.timeoutIntervalForResource == 30)
    }

    @Test func defaultSessionDoesNotCacheToDisk() {
        // Transcripts and API traffic must not land in an on-disk URL cache.
        let client = URLSessionHTTPClient()
        #expect((client.session.configuration.urlCache?.diskCapacity ?? 0) == 0)
    }
}
