import Foundation

/// Facts about how this process was launched that change what startup may do.
enum LaunchEnvironment {

    /// True when this process is the host app of an XCTest / Swift Testing run.
    /// The test bundle loads into the real app, so launch-time side effects —
    /// data migration, the hotkey tap, model preparation — must not run against
    /// the developer's real data.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil || env["XCTestSessionIdentifier"] != nil {
            return true
        }
        return NSClassFromString("XCTestCase") != nil
    }()
}
