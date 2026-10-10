import CoreServices
import Testing
@testable import voxline

@Suite struct QuitReasonTests {

    @Test(arguments: [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map { OSType($0) })
    func logout_restart_and_shutdown_end_the_session(reason: OSType) {
        #expect(QuitReason.endsSession(reason))
    }

    @Test func a_quit_without_a_reason_does_not_end_the_session() {
        #expect(!QuitReason.endsSession(nil))
    }

    /// `kAEQuitAll` comes from an installer or another app asking everything
    /// to quit, which the user can still cancel; 0 is a reason that couldn't
    /// be read.
    @Test(arguments: [OSType(kAEQuitAll), OSType(kAEQuitApplication), 0])
    func other_reasons_do_not_end_the_session(reason: OSType) {
        #expect(!QuitReason.endsSession(reason))
    }
}
