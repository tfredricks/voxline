import Testing
import Foundation
@testable import voxline

@Suite struct FakeTranscriptionSessionTests {

    @Test func cancel_before_finish_throws_without_hanging() async {
        let s = FakeTranscriptionSession()
        s.holdFinish = true
        s.cancel()
        await #expect(throws: CancellationError.self) { try await s.finish() }
        #expect(s.cancelCount == 1)
        #expect(s.finishCount == 1)
    }

    @Test func release_before_wait_does_not_hang() async throws {
        let s = FakeTranscriptionSession()
        s.holdFinish = true
        s.finishResult = .success("done")
        s.releaseFinish()
        #expect(try await s.finish() == "done")
    }

    @Test func release_after_wait_resumes_finish() async throws {
        let s = FakeTranscriptionSession()
        s.holdFinish = true
        s.finishResult = .success("done")
        let task = Task { try await s.finish() }
        while s.finishCount == 0 { await Task.yield() }
        s.releaseFinish()
        #expect(try await task.value == "done")
    }

    @Test func cancel_during_wait_throws() async {
        let s = FakeTranscriptionSession()
        s.holdFinish = true
        let task = Task { try await s.finish() }
        while s.finishCount == 0 { await Task.yield() }
        s.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
