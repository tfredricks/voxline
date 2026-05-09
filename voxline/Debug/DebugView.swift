// voxline/Debug/DebugView.swift
//
// End-to-end diagnostic + manual-test screen. Opened from the menu bar
// "Open Debug Window…" item. Shows live state of permissions, the hotkey
// tap, the pipeline, and gives buttons to exercise each stage independently.
//
// Not shipped as user-facing functionality — this is a triage tool.

import AppKit
import SwiftUI

struct DebugView: View {
    @Bindable var state: AppState
    let coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                permissionsSection
                Divider()
                hotkeySection
                Divider()
                pipelineSection
                Divider()
                transcriptsSection
                Divider()
                modesSection
                Divider()
                testButtonsSection
                Divider()
                lastResultSection
            }
            .padding(20)
            .frame(minWidth: 520, alignment: .leading)
        }
    }

    private var transcriptsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Last chord cycle")
            Text("Heard (raw transcript from WhisperKit)")
                .font(.caption).foregroundStyle(.secondary)
            transcriptBox(state.lastTranscript ?? "(no transcript yet)")
            Text("Would paste (LLM-cleaned)")
                .font(.caption).foregroundStyle(.secondary)
            transcriptBox(state.lastCleanedText ?? "(no cleaned text yet)")
        }
    }

    @ViewBuilder
    private func transcriptBox(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .cornerRadius(6)
    }

    // MARK: - Sections

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Permissions")
            row("Microphone:", state.debugMicrophoneStatus)
            row("Accessibility:", state.debugAccessibilityStatus)
            row("Input Monitoring:", state.debugInputMonitoringStatus)
            HStack(spacing: 8) {
                Button("Open Accessibility Settings") {
                    openSystemSettings(pane: "Privacy_Accessibility")
                }
                Button("Open Input Monitoring Settings") {
                    openSystemSettings(pane: "Privacy_ListenEvent")
                }
                Button("Re-prompt Input Monitoring") {
                    _ = PermissionsService().requestInputMonitoring()
                    state.debugLastTestResult = "Triggered Input Monitoring prompt"
                }
                Button("Re-prompt Accessibility") {
                    PermissionsService().promptAccessibility()
                    state.debugLastTestResult = "Triggered Accessibility prompt"
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var hotkeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Hotkey")
            row("State:", state.debugHotkeyState)
            row("Tap installed:", state.debugTapInstalled ? "yes" : "no")
            HStack(spacing: 8) {
                Button("Force-finalize (unwedge)") {
                    coordinator.hotkeyMonitor?.recordingFinished()
                    state.debugLastTestResult = "Fed .recordingFinished to state machine"
                }
                Button("Reinstall tap") {
                    do {
                        try coordinator.hotkeyMonitor?.start()
                        state.debugLastTestResult = "Tap reinstalled"
                    } catch {
                        state.debugLastTestResult = "Reinstall failed: \(error)"
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var pipelineSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Pipeline")
            row("Status:", statusLabel)
            row("Phase:", state.debugPipelinePhase)
            if let started = state.recordingStartedAt {
                row("Recording started:", started.formatted(date: .omitted, time: .standard))
            }
            row("Audio level:", String(format: "%.3f", state.audioLevel))
        }
    }

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Routing")
            let frontID = coordinator.frontmost?.frontmostBundleID() ?? "(none)"
            row("Frontmost bundle:", frontID)
            let resolved = coordinator.modes?.mode(for: coordinator.frontmost?.frontmostBundleID())
            row("Resolved mode:", resolved.map { "\($0.displayName) [\($0.bundleID)]" } ?? "(no match)")
            if let m = resolved {
                row("Model override:", m.model ?? "(use default)")
                row("Temperature:", m.temperature.map { String(format: "%.2f", $0) } ?? "(default)")
            }
        }
    }

    private var testButtonsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("End-to-end tests")
            HStack(spacing: 8) {
                Button("Test paste 'voxline-test-\(Int(Date().timeIntervalSince1970) % 10000)'") {
                    Task { await runTestPaste() }
                }
                Button("Test LLM ('hello world' cleanup)") {
                    Task { await runTestLLM() }
                }
                Button("Test transcribe (silence)") {
                    Task { await runTestTranscribe() }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var lastResultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Last test result")
            Text(state.debugLastTestResult.isEmpty ? "(none)" : state.debugLastTestResult)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
        }
    }

    // MARK: - Actions

    private func runTestPaste() async {
        guard let injector = coordinator.injector else {
            state.debugLastTestResult = "No injector available"
            return
        }
        let stamp = "voxline test paste @ \(Date().formatted(date: .omitted, time: .standard))"
        do {
            try await injector.inject(stamp)
            state.debugLastTestResult = "Paste completed: \(stamp)"
        } catch {
            state.debugLastTestResult = "Paste failed: \(error)"
        }
    }

    private func runTestLLM() async {
        guard let llm = coordinator.llm else {
            state.debugLastTestResult = "No LLM service available"
            return
        }
        let bundleID = coordinator.frontmost?.frontmostBundleID()
        guard let mode = coordinator.modes?.mode(for: bundleID) else {
            state.debugLastTestResult = "No mode resolves for '\(bundleID ?? "nil")'"
            return
        }
        do {
            let cleaned = try await llm.cleanup(transcript: "hello world", mode: mode)
            state.debugLastTestResult = "LLM ok (\(mode.displayName)) → \(cleaned)"
        } catch {
            state.debugLastTestResult = "LLM failed (\(mode.displayName)): \(error)"
        }
    }

    private func runTestTranscribe() async {
        guard let transcriber = coordinator.transcriber else {
            state.debugLastTestResult = "No transcriber available"
            return
        }
        // 1 second of silence at 16 kHz mono. Whisper should return empty
        // string or a hallucinated noise tag — either way it confirms the
        // transcribe await completes.
        let samples = [Float](repeating: 0, count: 16_000)
        let start = Date()
        do {
            let text = try await transcriber.transcribe(samples: samples)
            let dt = Date().timeIntervalSince(start)
            state.debugLastTestResult = "Transcribe ok in \(String(format: "%.2f", dt))s → '\(text)'"
        } catch {
            state.debugLastTestResult = "Transcribe failed: \(error)"
        }
    }

    // MARK: - Helpers

    private var statusLabel: String {
        switch state.status {
        case .idle: return "idle"
        case .recording: return "recording"
        case .thinking: return "thinking"
        case .preparingModel: return "preparingModel"
        case .downloadingModel(let p): return "downloadingModel(\(Int(p * 100))%)"
        case .error(let msg): return "error: \(msg)"
        }
    }

    private func openSystemSettings(pane: String) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
        NSWorkspace.shared.open(url)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}

// MARK: - Window plumbing

@MainActor
final class DebugWindowController: NSObject {
    private var window: NSWindow?

    func show(state: AppState, coordinator: AppCoordinator) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: DebugView(state: state, coordinator: coordinator))
        let w = NSWindow(contentViewController: host)
        w.title = "voxline Debug"
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.setContentSize(NSSize(width: 600, height: 700))
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
