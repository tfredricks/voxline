import AppKit
import SwiftUI

/// Hosts ModelDownloadView in a regular activating NSWindow. Shown on launch
/// only when the speech-recognition model isn't yet cached on disk.
@MainActor
final class ModelDownloadWindow {
    private var window: NSWindow?

    func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = ModelDownloadView(state: state)
        let host = NSHostingView(rootView: view)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Preparing Voxline"
        win.contentView = host
        win.center()
        win.isReleasedWhenClosed = false

        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.orderOut(nil)
        window = nil
    }
}

struct ModelDownloadView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(headline)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isPreparing {
                ProgressView()
                    .progressViewStyle(.linear)
            } else {
                ProgressView(value: progress, total: 1.0) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var isPreparing: Bool {
        if case .preparingModel = state.status { return true }
        return false
    }

    private var headline: String {
        isPreparing ? "Preparing model…" : "Downloading speech recognition model"
    }

    private var detail: String {
        if isPreparing {
            return "Compiling for Apple Neural Engine. This can take up to a minute on first launch — subsequent launches are fast."
        }
        return "One-time download (~1.5 GB) used to transcribe your voice. Voxline can stay open while it completes."
    }

    private var progress: Double {
        if case .downloadingModel(let p) = state.status { return p }
        return 1.0
    }
}
