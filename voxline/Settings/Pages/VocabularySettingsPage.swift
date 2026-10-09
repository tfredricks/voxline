import SwiftUI

struct VocabularySettingsPage: View {
    let vocabulary: CustomVocabularyListViewModel
    let learning: LearningSettingsViewModel

    var body: some View {
        SettingsPage(.vocabulary) {
            CustomVocabularyListView(viewModel: vocabulary)
            LearningSection(model: learning)
        }
    }
}
