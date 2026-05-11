// voxline/Debug/DebugView.swift
//
// Triage tool for the developer + power users opening it during a bug report.
// Three panels, top to bottom, organized by the question being asked:
//   1. Last attempt          — "what just happened?"
//   2. Inputs healthy?       — "can it record?"
//   3. If it's wrong         — recovery + bisect
//
// Not user-facing functionality. Audience is the developer plus a power user
// who can read fields back over a bug report. Diagnostics that are not
// human-readable do not belong here.

import AppKit
import SwiftUI

struct DebugView: View {
    @Bindable var state: AppState
    let coordinator: AppCoordinator

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                lastAttemptSection
                Divider()
                inputsSection
                Divider()
                troubleshootingSection
            }
            .padding(20)
            .frame(minWidth: 520, alignment: .leading)
        }
    }

    // MARK: - Panel 1: Last attempt

    private var lastAttemptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Last attempt")
            row("Status:", statusLabel)

            Text("Heard (raw transcript from WhisperKit)")
                .font(.caption).foregroundStyle(.secondary)
            transcriptBox(heardText)

            Text("Cleaned (would paste — LLM output)")
                .font(.caption).foregroundStyle(.secondary)
            transcriptBox(cleanedText)

            row("Mode:", modeLine)
            if let overrideLine = modeOverrideLine {
                row("", overrideLine)
            }
            if let duration = state.lastRecordingDuration {
                row("Duration:", String(format: "%.1fs · peak %.3f", duration, state.lastPeakLevel))
            }
            if let t = state.lastTranscribeDuration, let c = state.lastCleanupDuration {
                row("Timing:", String(format: "transcribe %.2fs · cleanup %.2fs", t, c))
            } else if let t = state.lastTranscribeDuration {
                row("Timing:", String(format: "transcribe %.2fs · cleanup —", t))
            }
            row("Insertion:", state.debugLastInsertionResult)
            if showFinalizeReason {
                row("Reason:", state.debugLastFinalizeReason)
            }
        }
    }

    private var heardText: String {
        guard let t = state.lastTranscript else { return "(no recording yet)" }
        return t.isEmpty ? "(empty — WhisperKit returned no text)" : t
    }

    private var cleanedText: String {
        guard let t = state.lastCleanedText else { return "(no cleaned text yet)" }
        return t.isEmpty ? "(empty)" : t
    }

    /// "<displayName>  (<bundleID>)" or "(no match)" if no mode resolves.
    private var modeLine: String {
        let bundleID = coordinator.frontmost?.frontmostBundleID() ?? "(none)"
        guard let mode = coordinator.modes?.mode(for: coordinator.frontmost?.frontmostBundleID()) else {
            return "(no match) — frontmost \(bundleID)"
        }
        return "\(mode.displayName)  (\(bundleID))"
    }

    /// "override: <model> @ <temp>" if either is set on the resolved mode.
    private var modeOverrideLine: String? {
        guard let mode = coordinator.modes?.mode(for: coordinator.frontmost?.frontmostBundleID()) else {
            return nil
        }
        let model = mode.model
        let temp = mode.temperature
        if model == nil && temp == nil { return nil }
        let modelPart = model ?? "(default)"
        let tempPart = temp.map { String(format: "%.2f", $0) } ?? "(default)"
        return "override: \(modelPart) @ \(tempPart)"
    }

    /// Hide the reason row when it is the default ("(none yet)") or the
    /// expected chord-release case — both are noise. Surface anything else
    /// (max-duration / app-deactivated / tap-disabled) since those explain
    /// a too-short recording.
    private var showFinalizeReason: Bool {
        let r = state.debugLastFinalizeReason
        return !(r == "(none yet)" || r.lowercased().contains("chord-release"))
    }

    // MARK: - Panel 2: Inputs healthy?

    private var inputsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Inputs healthy?")
            permissionRow("Microphone:", state.debugMicrophoneStatus, settingsPane: nil)
            permissionRow("Accessibility:", state.debugAccessibilityStatus, settingsPane: "Privacy_Accessibility")
            permissionRow("Input Monitoring:", state.debugInputMonitoringStatus, settingsPane: "Privacy_ListenEvent")
            row("Hotkey state:", state.debugHotkeyState)
            row("Tap installed:", state.debugTapInstalled ? "yes" : "no")
        }
    }

    @ViewBuilder
    private func permissionRow(_ label: String, _ value: String, settingsPane: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 160, alignment: .leading)
            Text(permissionMark(value) + " " + value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            if let pane = settingsPane, !isAuthorized(value) {
                Button("Open Settings") { openSystemSettings(pane: pane) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Spacer()
        }
    }

    /// Permission strings from `PermissionsService` are free-form; treat any
    /// status starting with "authorized"/"granted" as the healthy case. If the
    /// match is wrong we lose the green check, not correctness.
    private func isAuthorized(_ value: String) -> Bool {
        let v = value.lowercased()
        return v.hasPrefix("authorized") || v.hasPrefix("granted") || v.hasPrefix("ok")
    }

    private func permissionMark(_ value: String) -> String {
        if isAuthorized(value) { return "✓" }
        if value == "?" { return "·" }
        return "✗"
    }

    // MARK: - Panel 3: If it's wrong

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("If it's wrong")
            HStack(spacing: 8) {
                Button("Force-finalize") {
                    coordinator.hotkeyMonitor?.recordingFinished()
                    state.debugLastTestResult = "Fed .recordingFinished to state machine"
                }
                Button("Reinstall tap") {
                    do {
                        try coordinator.hotkeyMonitor?.start()
                        state.debugLastTestResult = "Tap reinstalled"
                    } catch {
                        state.debugLastTestResult = "Reinstall failed: \(error.localizedDescription)"
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 8) {
                Button("Test paste") { Task { await runTestPaste() } }
                Button("Test LLM") { Task { await runTestLLM() } }
                Button("Test transcribe") { Task { await runTestTranscribe() } }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Text("Last test result").font(.caption).foregroundStyle(.secondary)
            Text(state.debugLastTestResult.isEmpty ? "(none)" : state.debugLastTestResult)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
        }
    }

    // MARK: - Test actions

    private func runTestPaste() async {
        guard let injector = coordinator.injector else {
            state.debugLastTestResult = "No injector available"
            return
        }
        let stamp = "voxline test paste @ \(Date().formatted(date: .omitted, time: .standard))"
        do {
            let outcome = try await injector.inject(stamp)
            state.debugLastInsertionResult = outcome.description
            state.debugLastTestResult = "Paste completed (\(outcome.description)): \(stamp)"
        } catch {
            state.debugLastTestResult = "Paste failed: \(error.localizedDescription)"
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
            // Use localizedDescription rather than `\(error)`: the latter prints
            // the LLMError case literal, which for .badStatus includes the
            // response body — providers (Anthropic, OpenAI) echo the offending
            // API key prefix in 401 bodies.
            state.debugLastTestResult = "LLM failed (\(mode.displayName)): \(error.localizedDescription)"
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
            state.debugLastTestResult = "Transcribe failed: \(error.localizedDescription)"
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
        case .error(let category, let msg): return "error[\(category)]: \(msg)"
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
        w.identifier = WindowVisibilityCoordinator.dockworthyIdentifier
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
