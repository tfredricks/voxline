import AppKit
import Observation
import SwiftUI

enum MainWindowPage: Hashable {
    case home
    case general, dictation, aiProvider, commands, vocabulary, meetings

    static let settingsPages: [MainWindowPage] = [.general, .dictation, .aiProvider, .commands, .vocabulary, .meetings]

    var title: String {
        switch self {
        case .home: "Home"
        case .general: "General"
        case .dictation: "Dictation"
        case .aiProvider: "AI Provider"
        case .commands: "Commands"
        case .vocabulary: "Vocabulary"
        case .meetings: "Meetings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .general: "gearshape"
        case .dictation: "mic"
        case .aiProvider: "sparkles"
        case .commands: "command"
        case .vocabulary: "character.book.closed"
        case .meetings: "person.2"
        }
    }
}

@Observable
@MainActor
final class MainWindowSelection {
    var page: MainWindowPage? = .home
}

/// The app's one primary window: a sidebar with Home and the settings pages.
/// Built fresh from `content` on each `show` after a close, and released on
/// close so the SwiftUI content disappears: its `.task`s cancel and
/// `onDisappear` runs.
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

    /// A Dock click: brings an open window forward on the page it shows, or
    /// opens Home when the window is closed.
    func reopen() {
        if let window {
            window.presentInAccessoryApp()
        } else {
            show(.home)
        }
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

struct MainWindowView: View {
    @Bindable var selection: MainWindowSelection
    let home: HomeViewModel
    let settings: SettingsModel
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.page) {
                sidebarRow(.home)
                Section("Settings") {
                    ForEach(MainWindowPage.settingsPages, id: \.self) { sidebarRow($0) }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            detail(for: selection.page ?? .home)
        }
        .task { settings.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            settings.refresh()
        }
        .task(id: settings.status.readinessKey) {
            await settings.status.refreshEngineReadiness()
        }
        .onChange(of: settings.learning.vocabularyRevision) { _, _ in
            settings.vocabulary.reload()
        }
        .onChange(of: appState.status) { oldStatus, newStatus in
            if oldStatus.blocksRecording && !newStatus.blocksRecording {
                Task { await settings.status.refreshEngineReadiness() }
            }
        }
    }

    private func sidebarRow(_ page: MainWindowPage) -> some View {
        let issue = settings.status.issues.first { $0.page == page }
        return HStack {
            Label(page.title, systemImage: page.systemImage)
            if let issue {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help(issue.text)
                    .accessibilityLabel("Needs setup")
            }
        }
        .tag(page)
    }

    @ViewBuilder
    private func detail(for page: MainWindowPage) -> some View {
        switch page {
        case .home:
            HomeView(model: home, issues: settings.status.issues, open: { selection.page = $0 })
        case .general:
            GeneralSettingsPage(general: settings.general)
        case .dictation:
            DictationSettingsPage(general: settings.general, keys: settings.apiKeys)
        case .aiProvider:
            AIProviderSettingsPage(general: settings.general, keys: settings.apiKeys)
        case .commands:
            CommandsSettingsPage(general: settings.general, command: settings.command)
        case .vocabulary:
            VocabularySettingsPage(vocabulary: settings.vocabulary, learning: settings.learningSettings)
        case .meetings:
            MeetingsSettingsPage(model: settings.meetings)
        }
    }
}
