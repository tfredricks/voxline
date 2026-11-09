import SwiftUI

struct VocabularySettingsPage: View {
    let vocabulary: CustomVocabularyListViewModel

    var body: some View {
        SettingsPage(.vocabulary) {
            CustomVocabularyListView(viewModel: vocabulary)
        }
    }
}
