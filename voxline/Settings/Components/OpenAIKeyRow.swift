import SwiftUI

/// The OpenAI key row. Shown by the Cleanup section when OpenAI cleans up,
/// and by Recognition when OpenAI only transcribes.
struct OpenAIKeyRow: View {

    @Bindable var general: GeneralSettingsViewModel
    @Bindable var keys: APIKeysSettingsViewModel
    @Binding var revealed: Bool

    var body: some View {
        APIKeyRow(
            title: "OpenAI",
            provider: .openai,
            key: $keys.openaiKey,
            revealed: $revealed,
            getKeyURL: URL(string: "https://platform.openai.com/api-keys")!,
            expectedPrefix: "sk-",
            isPersisted: keys.isPersisted(.openai),
            testing: keys.testing,
            testResult: keys.testResult,
            lastError: keys.lastError,
            onCommit: {
                keys.commitOpenAI()
                general.openAIKeyDidChange()
            },
            onTest: { Task { await keys.testConnection(.openai) } }
        )
    }
}
