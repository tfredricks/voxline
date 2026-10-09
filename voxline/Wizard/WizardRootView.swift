// voxline/Wizard/WizardRootView.swift
import AppKit
import SwiftUI

struct WizardRootView: View {
    @Bindable var vm: WizardViewModel
    @Bindable var state: AppState
    let engineName: String
    let chord: HotkeyChord
    let onRetryDownload: () -> Void
    @State private var permissionsGranted = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if showsQuit {
                    Button("Quit Voxline") { NSApp.terminate(nil) }
                }
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
        case .apiKey: WizardAPIKeyView(
            vm: vm.apiKeyVM,
            selectedProvider: $vm.selectedProvider
        )
        case .modelDownload: WizardModelDownloadView(state: state, engineName: engineName, onRetry: onRetryDownload)
        case .done: WizardDoneView(chord: chord)
        }
    }

    private var showsQuit: Bool {
        guard vm.currentStep == .modelDownload, case .error = state.status else { return false }
        return true
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
                .disabled(!vm.canAdvanceFromAPIKeyStep)
        default:
            Button("Continue") { vm.advance() }
                .keyboardShortcut(.defaultAction)
        }
    }

}
