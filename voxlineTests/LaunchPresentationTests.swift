import Foundation
import Testing
@testable import voxline

@Suite struct LaunchPresentationTests {

    @Test func first_run_shows_the_wizard_whatever_else_is_true() {
        for granted in [true, false] {
            for login in [true, false] {
                #expect(LaunchPresentation.decide(firstRunComplete: false, requiredPermissionsGranted: granted, launchedAtLogin: login) == .wizard)
            }
        }
    }

    @Test func missing_permissions_show_home_even_at_login() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: false, launchedAtLogin: true) == .home)
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: false, launchedAtLogin: false) == .home)
    }

    @Test func login_launch_with_permissions_stays_hidden() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: true, launchedAtLogin: true) == .none)
    }

    @Test func manual_launch_with_permissions_shows_home() {
        #expect(LaunchPresentation.decide(firstRunComplete: true, requiredPermissionsGranted: true, launchedAtLogin: false) == .home)
    }

    @Test func apple_event_login_flag_wins() {
        #expect(LoginLaunch.isLoginLaunch(appleEventSaysLogin: true, sessionStart: nil, launchedAt: Date()))
    }

    @Test func launch_soon_after_session_start_is_login() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: start, launchedAt: start.addingTimeInterval(45)))
    }

    @Test func launch_long_after_session_start_is_manual() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: start, launchedAt: start.addingTimeInterval(61)))
    }

    @Test func no_signals_is_manual() {
        #expect(!LoginLaunch.isLoginLaunch(appleEventSaysLogin: false, sessionStart: nil, launchedAt: Date()))
    }
}
