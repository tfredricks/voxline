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

/// The app's one primary window: a sidebar with Home and Settings. Built
/// fresh from `content` on each `show` after a close, and released on close
/// so the SwiftUI content disappears (its `.task`s cancel, `onDisappear`
/// runs) the way a SwiftUI `Settings` scene does.
@MainActor
final class MainWindowController {
    private(set) var window: NSWindow?
    private let selection = MainWindowSelection()
    private let frameAutosaveName: String
    private let content: @MainActor (MainWindowSelection) -> AnyView
    private var closeObserver: NSObjectProtocol?

    init(
        frameAutosaveName: String = "voxline.mainWindow",
        content: @escaping @MainActor (MainWindowSelection) -> AnyView
    ) {
        self.frameAutosaveName = frameAutosaveName
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
        if !win.setFrameUsingName(frameAutosaveName) {
            win.setContentSize(NSSize(width: 880, height: 640))
            win.center()
        }
        win.setFrameAutosaveName(frameAutosaveName)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.releaseWindow() }
        }
        self.window = win
        win.presentInAccessoryApp()
    }

    private func releaseWindow() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = nil
        guard let win = window else { return }
        win.saveFrame(usingName: frameAutosaveName)
        win.setFrameAutosaveName("")
        win.contentViewController = nil
        window = nil
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
