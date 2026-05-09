// voxline/Wizard/WizardRootView.swift
import SwiftUI

struct WizardRootView: View {
    @Bindable var vm: WizardViewModel
    @Bindable var state: AppState
    let model: WhisperModel
    let chord: HotkeyChord
    let onRetryDownload: () -> Void

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
        case .permissions: WizardPermissionsView()
        case .apiKey: WizardAPIKeyView(vm: vm.apiKeyVM)
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
        default:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
