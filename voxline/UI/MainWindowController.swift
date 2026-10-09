import AppKit
import Observation
import SwiftUI

enum MainWindowPage: Hashable {
    case home, settings
}

@Observable
@MainActor
final class MainWindowSelection {
    var page: MainWindowPage? = .home
}

/// The app's one primary window: a sidebar with Home and Settings. Created
/// on first `show`, hidden (not released) on close.
@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let selection = MainWindowSelection()
    private let content: @MainActor (MainWindowSelection) -> AnyView

    init(content: @escaping @MainActor (MainWindowSelection) -> AnyView) {
        self.content = content
    }

    func show(_ page: MainWindowPage) {
        selection.page = page
        if let window {
            window.presentInAccessoryApp()
            return
        }
        let host = NSHostingController(rootView: content(selection))
        let win = NSWindow(contentViewController: host)
        win.title = "Voxline"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.toolbarStyle = .unified
        win.contentMinSize = NSSize(width: 720, height: 480)
        win.isReleasedWhenClosed = false
        if !win.setFrameUsingName("voxline.mainWindow") {
            win.setContentSize(NSSize(width: 880, height: 640))
            win.center()
        }
        win.setFrameAutosaveName("voxline.mainWindow")
        self.window = win
        win.presentInAccessoryApp()
    }
}

struct MainWindowView<Home: View, Settings: View>: View {
    @Bindable var selection: MainWindowSelection
    let home: Home
    let settings: Settings

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                Label("Home", systemImage: "house").tag(MainWindowPage.home)
                Label("Settings", systemImage: "gearshape").tag(MainWindowPage.settings)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch selection.page ?? .home {
            case .home: home
            case .settings: settings
            }
        }
    }
}
