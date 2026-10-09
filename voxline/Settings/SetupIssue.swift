import Foundation

/// Something that stops dictation or cleanup from working, and the settings
/// page that fixes it. Drives the sidebar marks and Home's Setup rows.
struct SetupIssue: Equatable, Identifiable {
    let text: String
    let page: MainWindowPage
    var id: String { text }
}
