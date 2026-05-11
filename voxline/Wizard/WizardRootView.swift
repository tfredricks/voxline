// voxline/Wizard/WizardRootView.swift
import SwiftUI

struct WizardRootView: View {
    @Bindable var vm: WizardViewModel
    @Bindable var state: AppState
    let model: WhisperModel
    let chord: HotkeyChord
    let onRetryDownload: () -> Void
    @State private var permissionsGranted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if vm.canGoBack {
                    Button("Back") { vm.goBack() }
                }
                Spacer()
                primaryButton
            }
            .padding()
        }
        .frame(width: 600, height: 480)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.currentStep {
        case .welcome: WizardWelcomeView()
        case .permissions: WizardPermissionsView(allGranted: $permissionsGranted)
        case .apiKey: WizardAPIKeyView(vm: vm.apiKeyVM, selectedProvider: $vm.selectedProvider)
        case .modelDownload: WizardModelDownloadView(state: state, model: model, onRetry: onRetryDownload)
        case .done: WizardDoneView(chord: chord)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch vm.currentStep {
        case .done:
            Button("Get started") { vm.complete() }
                .keyboardShortcut(.defaultAction)
        case .modelDownload:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(state.status != .idle)
        case .permissions:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!permissionsGranted)
        case .apiKey:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasAnyAPIKey)
        default:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var hasAnyAPIKey: Bool {
        // Require a key for the *selected* provider so Continue doesn't enable
        // off a leftover key for the other provider. Matches what complete()
        // will actually use.
        let ws = CharacterSet.whitespacesAndNewlines
        switch vm.selectedProvider {
        case .anthropic: return !vm.apiKeyVM.anthropicKey.trimmingCharacters(in: ws).isEmpty
        case .openai:    return !vm.apiKeyVM.openaiKey.trimmingCharacters(in: ws).isEmpty
        }
    }
}
