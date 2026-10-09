import Foundation

/// Every settings view model, built once per main-window build and shared by
/// all the settings pages, so switching pages keeps unsaved state.
@MainActor
final class SettingsModel {
    let general: GeneralSettingsViewModel
    let apiKeys: APIKeysSettingsViewModel
    let command: CommandSettingsViewModel
    let meetings: MeetingSettingsViewModel
    let vocabulary: CustomVocabularyListViewModel
    let learningSettings: LearningSettingsViewModel
    let status: SettingsStatusViewModel
    let learning: LearningCoordinator

    init(
        general: GeneralSettingsViewModel,
        apiKeys: APIKeysSettingsViewModel,
        command: CommandSettingsViewModel,
        meetings: MeetingSettingsViewModel,
        learning: LearningCoordinator,
        vocabularyStore: CustomVocabularyStore = CustomVocabularyStore(),
        engineReadiness: @escaping @MainActor (EngineID) async -> EngineReadiness?
    ) {
        self.general = general
        self.apiKeys = apiKeys
        self.command = command
        self.meetings = meetings
        self.learning = learning
        self.vocabulary = CustomVocabularyListViewModel(
            store: vocabularyStore,
            onRemoveLearned: { [weak learning] in learning?.learnedWordsRemoved($0) },
            onAdd: { [weak learning] in learning?.wordAddedByUser($0) }
        )
        self.learningSettings = LearningSettingsViewModel(learning: learning, vocabulary: vocabularyStore)
        self.status = SettingsStatusViewModel(general: general, keys: apiKeys, engineReadiness: engineReadiness)
    }

    func refresh() {
        general.refreshFromUserDefaults()
        general.refreshLoginItemStatus()
    }
}
