import AppKit
import SwiftUI
import Testing
@testable import voxline

@MainActor
@Suite struct HistoryWindowControllerTests {

    @MainActor
    final class ContentProbe {
        var builds = 0
        var disappearances = 0
    }

    private let store = DictationHistoryStore(defaults: UserDefaults(suiteName: "voxline.tests.history.\(UUID().uuidString)")!)

    private func makeController(_ probe: ContentProbe) -> HistoryWindowController {
        HistoryWindowController { _, _ in
            probe.builds += 1
            return AnyView(Color.clear.onDisappear { probe.disappearances += 1 })
        }
    }

    @Test func showing_twice_without_closing_builds_the_content_once() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { controller.window?.close() }

        controller.show(store: store, state: AppState())
        controller.show(store: store, state: AppState())

        #expect(probe.builds == 1)
    }

    /// Relative times ("1 min. ago") are computed when the content is built,
    /// so a reopened window must not reuse the old content.
    @Test func showing_after_close_rebuilds_the_content() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { controller.window?.close() }

        controller.show(store: store, state: AppState())
        controller.window?.close()
        controller.show(store: store, state: AppState())

        #expect(probe.builds == 2)
    }

    @Test func closing_releases_the_window_and_tears_down_the_content() {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { controller.window?.close() }

        controller.show(store: store, state: AppState())
        controller.window?.close()

        #expect(controller.window == nil)
        #expect(probe.disappearances == 1)
    }

    @Test func a_reopened_window_keeps_the_frame_it_was_closed_with() throws {
        let probe = ContentProbe()
        let controller = makeController(probe)
        defer { controller.window?.close() }

        controller.show(store: store, state: AppState())
        let moved = NSRect(x: 120, y: 140, width: 940, height: 500)
        try #require(controller.window).setFrame(moved, display: false)
        controller.window?.close()
        controller.show(store: store, state: AppState())

        #expect(controller.window?.frame == moved)
    }
}
