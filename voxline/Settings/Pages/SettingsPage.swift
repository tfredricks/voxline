import SwiftUI

/// The frame every settings page shares: a grouped form that fills the
/// detail column, titled with the page's name.
struct SettingsPage<Content: View>: View {
    let page: MainWindowPage
    @ViewBuilder let content: Content

    init(_ page: MainWindowPage, @ViewBuilder content: () -> Content) {
        self.page = page
        self.content = content()
    }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .navigationTitle(page.title)
    }
}
