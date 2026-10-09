import Testing
import Foundation
@testable import voxline

/// A measurement, not a gate: it runs each available engine over the fixture
/// clips (see `BakeoffFixtures`), prints a report, writes it next to the
/// fixtures, and only fails when an engine returns almost nothing.
///
/// Opt-in: runs only with `VOXLINE_BAKEOFF=1` and fixtures present. Optional
/// env: `VOXLINE_BAKEOFF_DIR` (fixtures), `VOXLINE_BAKEOFF_SPEED` (pacing
/// multiplier; keep 1 for numbers that feed the decision rule), and
/// `VOXLINE_BAKEOFF_CLOUD=1` to add OpenAI (sends the clips to OpenAI with
/// the saved key; never eligible to win). Pass them to
/// `xcodebuild` as `TEST_RUNNER_<name>`:
/// `TEST_RUNNER_VOXLINE_BAKEOFF=1 xcodebuild test ... -only-testing:voxlineTests/EngineBakeoffTests`
@Suite(.serialized, .enabled(if: BakeoffFixtures.isEnabled, "Set VOXLINE_BAKEOFF=1 with bake-off fixtures present"))
@MainActor
struct EngineBakeoffTests {

    private static let chunkSamples = 1_600

    @MainActor
    private final class FirstPartialProbe {
        var firstNonEmptyAt: ContinuousClock.Instant?
    }

    private struct ClipOutcome {
        let result: BakeoffClipResult
        let error: String?
    }

    private struct EngineRun {
        let engine: EngineID
        let metricsID: String
        let outcomes: [ClipOutcome]
        let score: EngineScore
    }

    @Test func run_bakeoff() async throws {
        let fixtures = try BakeoffFixtures.load()
        try #require(!fixtures.clips.isEmpty)
        let speed = max(Double(ProcessInfo.processInfo.environment["VOXLINE_BAKEOFF_SPEED"] ?? "1") ?? 1, 0.01)

        var engines: [any TranscriptionEngine] = [AppleSpeechEngine()]
        if TranscriptionService.isModelCached(.largeV3Turbo) {
            engines.append(WhisperKitEngine(service: TranscriptionService(model: .largeV3Turbo)))
        }
        if ProcessInfo.processInfo.environment["VOXLINE_BAKEOFF_CLOUD"] == "1" {
            engines.append(OpenAIRealtimeEngine(keychain: DataProtectionKeychain()))
        }

        var runs: [EngineRun] = []
        for engine in engines {
            try await engine.prepare { _ in }
            var outcomes: [ClipOutcome] = []
            for clip in fixtures.clips {
                outcomes.append(await Self.measure(clip, on: engine, terms: fixtures.terms, speed: speed))
            }
            runs.append(EngineRun(
                engine: engine.id,
                metricsID: engine.metricsID,
                outcomes: outcomes,
                score: EngineScore(engine: engine.id, terms: fixtures.terms, results: outcomes.map(\.result))
            ))
        }

        let verdict = BakeoffDecision.winner(runs.map(\.score))
        let report = Self.markdown(clips: fixtures.clips, terms: fixtures.terms, speed: speed, runs: runs, verdict: verdict)
        print(report)
        try report.write(
            to: BakeoffFixtures.directory.appending(path: "bakeoff-report.md"),
            atomically: true,
            encoding: .utf8
        )

        for run in runs {
            let transcribed = run.outcomes.filter { !$0.result.hypothesis.isEmpty }.count
            #expect(
                transcribed * 2 >= run.outcomes.count,
                "\(run.engine.bakeoffLabel) returned text for only \(transcribed) of \(run.outcomes.count) clips"
            )
        }
    }

    private static func measure(
        _ clip: BakeoffFixtures.Clip,
        on engine: any TranscriptionEngine,
        terms: [String],
        speed: Double
    ) async -> ClipOutcome {
        let clock = ContinuousClock()
        let probe = FirstPartialProbe()
        var audioStart: ContinuousClock.Instant?
        var collector: Task<Void, Never>?
        var session: (any TranscriptionSession)?
        var hypothesis = ""
        var finishMs = 0
        var failure: String?
        do {
            let opened = try await engine.openSession(SessionConfig(vocabularyHints: terms))
            session = opened
            collector = Task {
                for await partial in opened.partials where probe.firstNonEmptyAt == nil && !partial.isEmpty {
                    probe.firstNonEmptyAt = clock.now
                }
            }
            audioStart = clock.now
            var offset = 0
            while offset < clip.samples.count {
                let end = min(offset + chunkSamples, clip.samples.count)
                opened.append(Array(clip.samples[offset..<end]))
                offset = end
                if offset < clip.samples.count {
                    try await Task.sleep(for: .milliseconds(Int(100 / speed)))
                }
            }
            let finishStart = clock.now
            hypothesis = try await opened.finish()
            finishMs = milliseconds(clock.now - finishStart)
            await collector?.value
        } catch {
            session?.cancel()
            collector?.cancel()
            failure = String(describing: error)
        }
        var firstPartialMs: Int?
        if let start = audioStart, let firstAt = probe.firstNonEmptyAt {
            firstPartialMs = milliseconds(firstAt - start)
        }
        return ClipOutcome(
            result: BakeoffClipResult(
                reference: clip.reference,
                hypothesis: hypothesis,
                finishMs: finishMs,
                firstPartialMs: firstPartialMs,
                failed: failure != nil
            ),
            error: failure
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }

    private static func markdown(
        clips: [BakeoffFixtures.Clip],
        terms: [String],
        speed: Double,
        runs: [EngineRun],
        verdict: (winner: EngineID?, reason: String)
    ) -> String {
        func percent(_ value: Double?) -> String { value.map { String(format: "%.1f", $0 * 100) } ?? "n/a" }
        func ms(_ value: Int?) -> String { value.map(String.init) ?? "n/a" }

        var lines = [
            "# Engine bake-off",
            "",
            "\(clips.count) clips, \(terms.count) dictionary terms, pacing x\(speed), \(Date().formatted(.iso8601)).",
            "",
            "| Engine | WER % | Term miss % | Finish median ms | Finish p90 ms | First partial median ms |",
            "|---|---|---|---|---|---|",
        ]
        for run in runs {
            let s = run.score
            lines.append(
                "| \(run.engine.bakeoffLabel) (\(run.metricsID)) | \(percent(s.wer)) | \(percent(s.termMissRate)) | \(s.finishMedianMs) | \(s.finishP90Ms) | \(ms(s.firstPartialMedianMs)) |"
            )
        }
        lines += ["", "## Hypotheses", ""]
        for (index, clip) in clips.enumerated() {
            lines += ["### \(clip.name)", "", "- Reference: \(clip.reference)"]
            for run in runs {
                let outcome = run.outcomes[index]
                let wer = TranscriptScoring.wordErrorRate(reference: clip.reference, hypothesis: outcome.result.hypothesis)
                var line = "- \(run.engine.bakeoffLabel): \(outcome.result.hypothesis) (WER \(percent(wer))%, finish \(outcome.result.finishMs) ms)"
                if let error = outcome.error { line += " [error: \(error)]" }
                lines.append(line)
            }
            lines.append("")
        }
        let winnerName = verdict.winner?.bakeoffLabel ?? "none"
        lines.append("**Winner:** \(winnerName) — \(verdict.reason)")
        return lines.joined(separator: "\n") + "\n"
    }
}
