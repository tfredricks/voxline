// voxline/Hotkey/ShortcutCaptureSuspender.swift
import Observation

/// Suspends hotkey input while a Settings recorder captures a shortcut
/// (issue 10). `suspend` runs once when `AppState.shortcutCaptureDepth`
/// leaves zero, and `resume` once when it returns to zero.
@MainActor
final class ShortcutCaptureSuspender {

    private(set) var isSuspended = false

    private weak var state: AppState?
    private let suspend: @MainActor () -> Void
    private let resume: @MainActor () -> Void

    init(
        state: AppState,
        suspend: @escaping @MainActor () -> Void,
        resume: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.suspend = suspend
        self.resume = resume
        sync()
        observe()
    }

    func sync() {
        guard let state else { return }
        let capturing = state.shortcutCaptureDepth > 0
        guard capturing != isSuspended else { return }
        isSuspended = capturing
        if capturing { suspend() } else { resume() }
    }

    private func observe() {
        guard let state else { return }
        withObservationTracking {
            _ = state.shortcutCaptureDepth
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }
}
