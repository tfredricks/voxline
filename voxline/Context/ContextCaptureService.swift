import Foundation
import AppKit

/// Captures the user's current dictation context at push-to-talk press time.
/// Implementations run AX queries under a total time budget and must NEVER
/// throw — return a partial `CapturedContext` instead. Called from background
/// queues; must be `Sendable`.
protocol ContextCapturing: Sendable {
    /// Snapshot of the user's current focus + surroundings. Always returns;
    /// fields fall back to nil/empty when the underlying signal is unavailable.
    func capture() async -> CapturedContext
}

/// Default orchestrator. Runs probes in cheapest-first order under a single
/// total time budget. Never throws — returns a partial `CapturedContext`
/// with `captureNotes` describing what was skipped.
struct DefaultContextCaptureService: ContextCapturing {

    let frontmost: FrontmostAppProviding
    let appNameProvider: @Sendable () -> String?
    let fieldInspector: FocusedFieldInspecting
    let axProbe: AXContextProbing
    let labelsWalker: AXVisibleLabelsWalking
    let vocabulary: CustomVocabularyStore
    let budgetMs: Int

    /// Production initializer: resolves `appName` from `NSWorkspace.frontmostApplication`
    /// at call time and wires up the real AX probes.
    init(
        frontmost: FrontmostAppProviding = FrontmostApp(),
        appNameProvider: @escaping @Sendable () -> String? = {
            NSWorkspace.shared.frontmostApplication?.localizedName
        },
        fieldInspector: FocusedFieldInspecting = AXFocusedFieldInspector(),
        axProbe: AXContextProbing = DefaultAXContextProbe(),
        labelsWalker: AXVisibleLabelsWalking = DefaultAXVisibleLabelsWalker(),
        vocabulary: CustomVocabularyStore = CustomVocabularyStore(),
        budgetMs: Int = 150
    ) {
        self.frontmost = frontmost
        self.appNameProvider = appNameProvider
        self.fieldInspector = fieldInspector
        self.axProbe = axProbe
        self.labelsWalker = labelsWalker
        self.vocabulary = vocabulary
        self.budgetMs = budgetMs
    }

    func capture() async -> CapturedContext {
        let deadline = CaptureDeadline(totalMilliseconds: budgetMs)
        var c = CapturedContext.empty

        // Step 1: frontmost app (cheap; no AX).
        c.bundleID = frontmost.frontmostBundleID()
        c.appName = appNameProvider()

        // Step 2: focused field role/subrole + secure-field gate.
        let field = fieldInspector.inspect()
        c.fieldRole = field?.role
        c.fieldSubrole = field?.subrole
        if field?.kind == .secure {
            c.isSecureField = true
            c.captureNotes.append("secure-field")
        }

        // Step 3: probe value-bearing AX attributes. Window title is always
        // useful (it helps the LLM distinguish e.g. a login screen from an
        // in-app password change); the value/selection fields are suppressed
        // for secure fields so we don't ferry passwords into the prompt.
        if !deadline.isExpired {
            let probe = axProbe.probe(deadline: deadline)
            c.windowTitle = probe.windowTitle
            if !c.isSecureField {
                c.textBeforeCursor = probe.textBeforeCursor
                c.textAfterCursor = probe.textAfterCursor
                c.selectedText = probe.selectedText
            }
        }

        // Step 4: visible-labels BFS — runs for both normal and secure fields.
        if !deadline.isExpired {
            c.visibleLabels = labelsWalker.walk(deadline: deadline)
        }

        // Step 5: custom vocabulary (cheap; UserDefaults).
        c.customVocabulary = vocabulary.load()

        c.captureDurationMs = deadline.elapsedMilliseconds()
        // Single ax-timeout note covers any case where the deadline expired
        // before capture completed (probe ate the budget, walk skipped, etc.).
        if deadline.isExpired {
            c.captureNotes.append("ax-timeout")
        }
        return c
    }
}
