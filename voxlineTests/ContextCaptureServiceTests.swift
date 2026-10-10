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

    @Test func capture_aggregates_app_field_and_probe() async {
        let front = FakeFrontmost(); front.bundleID = "com.tinyspeck.slackmacgap"
        let inspector = FakeFieldInspector(); inspector.field = FocusedField(role: "AXTextArea", subrole: nil)
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "#sales-pipeline — Acme",
            textBeforeCursor: "Hey Kamil,",
            textAfterCursor: nil,
            selectedText: "highlighted"
        ))
        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Slack" },
            fieldInspector: inspector,
            axProbe: probe,
            isAXTrusted: { true },
            budgetMs: 50
        )

        let c = await svc.capture()
        #expect(c.appName == "Slack")
        #expect(c.bundleID == "com.tinyspeck.slackmacgap")
        #expect(c.windowTitle == "#sales-pipeline — Acme")
        #expect(c.fieldRole == "AXTextArea")
        #expect(c.isSecureField == false)
        #expect(c.textBeforeCursor == "Hey Kamil,")
        #expect(c.selectedText == "highlighted")
        #expect(c.customVocabulary.isEmpty, "the pipeline adds the vocabulary")
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
        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "1Password" },
            fieldInspector: inspector,
            axProbe: probe,
            isAXTrusted: { true },
            budgetMs: 50
        )

        let c = await svc.capture()
        #expect(c.isSecureField == true)
        #expect(c.textBeforeCursor == nil)
        #expect(c.textAfterCursor == nil)
        #expect(c.selectedText == nil)
        #expect(c.windowTitle == "Login")
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
        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Safari" },
            fieldInspector: inspector,
            axProbe: probe,
            isAXTrusted: { true },
            budgetMs: 50
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
        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { nil },
            fieldInspector: inspector,
            axProbe: probe,
            isAXTrusted: { true },
            budgetMs: 50
        )

        let c = await svc.capture()
        #expect(c.captureDurationMs >= 0)
        #expect(c.captureDurationMs <= 200)
    }

    @Test func capture_records_ax_not_trusted_note_and_skips_probe_when_ax_denied() async {
        let front = FakeFrontmost(); front.bundleID = "com.apple.Safari"
        let inspector = FakeFieldInspector(); inspector.field = nil
        // Probe would still return data if asked — but the orchestrator
        // should NOT ask it when AX is denied, so its results never land.
        let probe = StubProbe(result: AXContextProbeResult(
            windowTitle: "this would leak if probed",
            textBeforeCursor: "and so would this",
            textAfterCursor: nil,
            selectedText: nil
        ))
        let svc = DefaultContextCaptureService(
            frontmost: front,
            appNameProvider: { "Safari" },
            fieldInspector: inspector,
            axProbe: probe,
            isAXTrusted: { false },
            budgetMs: 50
        )

        let c = await svc.capture()
        // App identity still flows (no AX required).
        #expect(c.appName == "Safari")
        #expect(c.bundleID == "com.apple.Safari")
        // AX-dependent fields stayed unset; probe results never read.
        #expect(c.windowTitle == nil)
        #expect(c.textBeforeCursor == nil)
        // The diagnostic flag is set so the cleanup-debug log can show it.
        #expect(c.captureNotes.contains("ax-not-trusted"))
    }
}
