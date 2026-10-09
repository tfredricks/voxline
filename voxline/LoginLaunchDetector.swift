import AppKit
import Darwin

/// Reads the live launch signals. Call from `applicationWillFinishLaunching`,
/// while the open-application Apple event is still current.
enum LoginLaunchDetector {
    @MainActor static func capture() -> Bool {
        let appleEvent = appleEventSaysLogin()
        let sessionStart = consoleSessionStart()
        let now = Date()
        let result = LoginLaunch.isLoginLaunch(
            appleEventSaysLogin: appleEvent,
            sessionStart: sessionStart,
            launchedAt: now
        )
        let sessionAge = sessionStart.map { String(Int(now.timeIntervalSince($0))) } ?? "none"
        AppLog.pipeline.info(
            "launch: appleEvent=\(appleEvent, privacy: .public) sessionAge=\(sessionAge, privacy: .public) atLogin=\(result, privacy: .public)"
        )
        return result
    }

    @MainActor private static func appleEventSaysLogin() -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private static func consoleSessionStart() -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let entry = getutxent() {
            let e = entry.pointee
            guard e.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let user = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", user == NSUserName() else { continue }
            let start = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest.map({ start > $0 }) ?? true { latest = start }
        }
        return latest
    }
}
