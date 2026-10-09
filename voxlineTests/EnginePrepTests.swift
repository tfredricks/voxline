import Testing
@testable import voxline

@Suite struct EnginePrepTests {

    @Test func ready_engine_is_warmed() {
        #expect(EnginePrep.plan(for: .ready) == .warm)
    }

    @Test(arguments: [Optional(1_500), nil])
    func engine_needing_preparation_is_downloaded(downloadMB: Int?) {
        #expect(EnginePrep.plan(for: .needsPreparation(downloadMB: downloadMB)) == .download)
    }

    @Test func unavailable_engine_fails_with_its_reason() {
        let reason = "Apple Speech doesn't support this Mac's language."
        #expect(EnginePrep.plan(for: .unavailable(reason)) == .fail(reason))
    }
}
