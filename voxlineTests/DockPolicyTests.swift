import AppKit
import Testing
@testable import voxline

@Suite struct DockPolicyTests {

    private func window(
        titled: Bool = true,
        panel: Bool = false,
        level: NSWindow.Level = .normal,
        visible: Bool = true,
        miniaturized: Bool = false
    ) -> WindowSnapshot {
        WindowSnapshot(isTitled: titled, isPanel: panel, level: level, isVisible: visible, isMiniaturized: miniaturized)
    }

    @Test func setting_on_is_regular_even_with_no_windows() {
        #expect(DockPolicy.policy(showInDock: true, windows: []) == .regular)
    }

    @Test func setting_off_with_no_windows_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: []) == .accessory)
    }

    @Test func visible_titled_window_is_regular() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window()]) == .regular)
    }

    @Test func miniaturized_window_keeps_regular() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(visible: false, miniaturized: true)]) == .regular)
    }

    @Test func ordered_out_titled_window_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(visible: false)]) == .accessory)
    }

    @Test func visible_panels_alone_are_accessory() {
        let alert = window(panel: true, level: .modalPanel)
        let pill = window(titled: false, panel: true, level: .statusBar)
        #expect(DockPolicy.policy(showInDock: false, windows: [alert, pill]) == .accessory)
    }

    @Test func titled_window_above_normal_level_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(level: .floating)]) == .accessory)
    }

    @Test func untitled_window_is_accessory() {
        #expect(DockPolicy.policy(showInDock: false, windows: [window(titled: false)]) == .accessory)
    }

    @Test func one_qualifying_window_among_others_is_regular() {
        let windows = [window(visible: false), window(panel: true), window()]
        #expect(DockPolicy.policy(showInDock: false, windows: windows) == .regular)
    }
}
