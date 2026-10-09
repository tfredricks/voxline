import Testing
@testable import voxline

@Suite struct MainWindowPageTests {

    @Test func settings_pages_are_listed_in_sidebar_order() {
        #expect(MainWindowPage.settingsPages == [.general, .dictation, .aiProvider, .commands, .vocabulary, .meetings])
    }

    @Test func pages_have_their_titles() {
        let titles = ([.home] + MainWindowPage.settingsPages).map(\.title)
        #expect(titles == ["Home", "General", "Dictation", "AI Provider", "Commands", "Vocabulary", "Meetings"])
    }

    @Test func pages_have_their_symbols() {
        let symbols = ([.home] + MainWindowPage.settingsPages).map(\.systemImage)
        #expect(symbols == ["house", "gearshape", "mic", "sparkles", "command", "character.book.closed", "person.2"])
    }
}
