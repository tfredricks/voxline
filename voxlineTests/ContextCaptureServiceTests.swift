import Testing
import Foundation
@testable import voxline

@Suite struct ContextCaptureServiceTests {

    final class FakeFrontmost: FrontmostAppProviding, @unchecked Sendable {
        var bundleID: String?
        func frontmostBundleID() -> String? { bundleID }
    }

    final class FakeFieldInspector: FocusedFieldInspecting, @unchecked Sendable {
        var field: FocusedField?
        func inspect() -> FocusedField? { field }
    }

    struct StubProbe: AXContextProbing {
        let result: AXContextProbeResult
        func probe(deadline: CaptureDeadline) -> AXContextProbeResult { result }
    }

    struct StubWalker: AXVisibleLabelsWalking {
        let labels: [String]
        func walk(deadline: CaptureDeadline) -> [String] { labels }
    }

    private func suite() -> UserDefaults {
        let name = "voxline-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func capture_aggregates_app_field_probe_labels_and_vocab() async {
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector(); inspector.field = FocusedField(role: "AXTextArea", subrole: nil)
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "#sales-pipeline — Acme",
            textBeforeCursor: "Hey Kamil,",
            textAfterCursor: nil,
            selectedText: "highlighted"
        ))
        let walker = StubWalker(labels: ["Kamil Szczerba", "Q4 Renewal"])
        let vocab = CustomVocabularyStore(defaults: suite())
        vocab.save(["Cursor", "LangGraph"])

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Slack" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            isAXTrusted: { true },
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.appName == "Slack")
        #expect(c.bundleID == "com.tinyspeck.slackmacgap")
        #expect(c.windowTitle == "#sales-pipeline — Acme")
        #expect(c.fieldRole == "AXTextArea")
        #expect(c.isSecureField == false)
        #expect(c.textBeforeCursor == "Hey Kamil,")
        #expect(c.selectedText == "highlighted")
        #expect(c.visibleLabels == ["Kamil Szczerba", "Q4 Renewal"])
        #expect(c.customVocabulary == ["Cursor", "LangGraph"])
        #expect(c.captureNotes.contains("ax-not-trusted") == false)
    }

    @Test func capture_marks_secure_field_and_suppresses_value_lines() async {
        let front = FakeFrontmost(); front.bundleID = "com.1password.1password"
        let inspector = FakeFieldInspector()
        inspector.field = FocusedField(role: "AXTextField", subrole: "AXSecureTextField")
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "Login",
            textBeforeCursor: "hunter2",
            textAfterCursor: nil,
            selectedText: "hunter2"
        ))
        let walker = StubWalker(labels: ["Email", "Password"])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "1Password" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            isAXTrusted: { true },
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.isSecureField == true)
        #expect(c.textBeforeCursor == nil)
        #expect(c.textAfterCursor == nil)
        #expect(c.selectedText == nil)
        #expect(c.windowTitle == "Login")
        #expect(c.visibleLabels == ["Email", "Password"])
        #expect(c.captureNotes.contains("secure-field"))
    }

    @Test func capture_leaves_field_role_nil_when_inspector_returns_nil_but_still_keeps_probe_signals() async {
        // The field inspector and the AX probe both go directly to AX; they
        // can disagree. When the inspector returns nil (no role info), we
        // must NOT also drop the probe's window/cursor signals — the probe
        // can still succeed for an unrecognized field type.
        let front = FakeFrontmost(); front.bundleID = "com.apple.Safari"
        let inspector = FakeFieldInspector(); inspector.field = nil
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "Voxline | Speech to text",
            textBeforeCursor: "let x = ",
            textAfterCursor: nil,
            selectedText: nil
        ))
        let walker = StubWalker(labels: [])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Safari" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            isAXTrusted: { true },
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.appName == "Safari")
        #expect(c.bundleID == "com.apple.Safari")
        #expect(c.fieldRole == nil)
        #expect(c.fieldSubrole == nil)
        #expect(c.isSecureField == false)
        // Probe's signals still flow through — inspector nil does NOT gate the probe.
        #expect(c.windowTitle == "Voxline | Speech to text")
        #expect(c.textBeforeCursor == "let x = ")
    }

    @Test func capture_records_duration_in_ms() async {
        let front = FakeFrontmost(); front.bundleID = "com.foo"
        let inspector = FakeFieldInspector()
        let probe = StubProbe(result: AXContextProbeResult())
        let walker = StubWalker(labels: [])
        let vocab = CustomVocabularyStore(defaults: suite())

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { nil },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            isAXTrusted: { true },
            budgetMs: 150
        )

        let c = await svc.capture()
        #expect(c.captureDurationMs >= 0)
        #expect(c.captureDurationMs <= 200)
    }

    @Test func capture_records_ax_not_trusted_note_and_skips_probes_when_ax_denied() async {
        let front = FakeFrontmost(); front.bundleID = "com.apple.Safari"
        let inspector = FakeFieldInspector(); inspector.field = nil
        // Probes/walker would still return data if asked — but the orchestrator
        // should NOT ask them when AX is denied, so their results never land.
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "this would leak if probed",
            textBeforeCursor: "and so would this",
            textAfterCursor: nil,
            selectedText: nil
        ))
        let walker = StubWalker(labels: ["leaky", "labels"])
        let vocab = CustomVocabularyStore(defaults: suite())
        vocab.save(["term"])

        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Safari" },
            fieldInspector: inspector,
            axProbe: probe,
            labelsWalker: walker,
            vocabulary: vocab,
            isAXTrusted: { false },
            budgetMs: 150
        )

        let c = await svc.capture()
        // App identity + vocabulary still flow (no AX required).
        #expect(c.appName == "Safari")
        #expect(c.bundleID == "com.apple.Safari")
        #expect(c.customVocabulary == ["term"])
        // AX-dependent fields stayed unset; probe/walker results never read.
        #expect(c.windowTitle == nil)
        #expect(c.textBeforeCursor == nil)
        #expect(c.visibleLabels == [])
        // The diagnostic flag is set so the cleanup-debug log can show it.
        #expect(c.captureNotes.contains("ax-not-trusted"))
    }
}
