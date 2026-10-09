import AppKit
import SwiftUI
import Testing
@testable import voxline

@MainActor
@Suite struct MainWindowControllerTests {

    @MainActor
    final class ContentProbe {
        var builds = 0
        var disappearances = 0
        var lastSelection: MainWindowSelection?
    }

    private static let frameName = "voxline.tests.mainWindow"

    private func makeController(_ probe: ContentProbe) -> MainWindowController {
        MainWindowController(frameAutosaveName: Self.frameName) { selection in
            probe.builds += 1
            probe.lastSelection = selection
            return AnyView(Color.clear.onDisappear { probe.disappearances += 1 })
        }
    }

    private func tearDown(_ controller: MainWindowController) {
        controller.window?.close()
        UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(Self.frameName)")
    }

    @Test func showing_twice_without_closing_builds_the_content_once() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { tearDown(controller) }

        controller.show(.home)
        controller.show(.home)

        #expect(probe.builds == 1)
    }

    @Test func showing_after_close_rebuilds_the_content() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { tearDown(controller) }

        controller.show(.home)
        controller.window?.close()
        controller.show(.home)

        #expect(probe.builds == 2)
    }

    @Test func closing_releases_the_window_and_tears_down_the_content() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { tearDown(controller) }

        controller.show(.home)
        controller.window?.close()

        #expect(controller.window == nil)
        #expect(probe.disappearances == 1)
    }

    @Test func show_general_selects_the_general_page() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { tearDown(controller) }

        controller.show(.general)

        #expect(probe.lastSelection?.page == .general)
    }
}
