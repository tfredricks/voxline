import Testing
@testable import voxline

@Suite struct LaunchEnvironmentTests {

    @Test func isRunningTests_isTrueInsideTheTestHarness() {
        #expect(LaunchEnvironment.isRunningTests)
    }
}
