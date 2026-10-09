import Foundation
@testable import voxline

struct EngineScore: Equatable {
    let engine: EngineID
    let wer: Double
    /// Nil when no dictionary term occurs in any reference.
    let termMissRate: Double?
    let finishMedianMs: Int
    let finishP90Ms: Int
    let firstPartialMedianMs: Int?
}

/// One engine's result for one fixture clip. `finishMs` is the `finish()`
/// call to its return; `firstPartialMs` runs from the first appended chunk to
/// the first non-empty partial.
struct BakeoffClipResult: Equatable {
    let reference: String
    let hypothesis: String
    let finishMs: Int
    let firstPartialMs: Int?
}

extension EngineScore {
    /// WER and term misses are pooled over all clips rather than averaged per
    /// clip, so long clips weigh in proportion to their length.
    init(engine: EngineID, terms: [String], results: [BakeoffClipResult]) {
        var distance = 0
        var referenceWords = 0
        var termOccurrences = 0
        var termHits = 0
        for result in results {
            let edits = TranscriptScoring.wordEdits(reference: result.reference, hypothesis: result.hypothesis)
            distance += edits.distance
            referenceWords += edits.referenceCount
            for term in terms {
                let hits = TranscriptScoring.termHits(
                    term: term,
                    reference: result.reference,
                    hypothesis: result.hypothesis
                )
                termOccurrences += hits.inReference
                termHits += hits.hits
            }
        }
        let finishTimes = results.map(\.finishMs)
        let firstPartials = results.compactMap(\.firstPartialMs)
        self.init(
            engine: engine,
            wer: referenceWords == 0 ? (distance == 0 ? 0 : 1) : Double(distance) / Double(referenceWords),
            termMissRate: termOccurrences == 0 ? nil : 1 - Double(termHits) / Double(termOccurrences),
            finishMedianMs: TranscriptScoring.median(finishTimes),
            finishP90Ms: TranscriptScoring.percentile(finishTimes, 0.9),
            firstPartialMedianMs: firstPartials.isEmpty ? nil : TranscriptScoring.median(firstPartials)
        )
    }
}

extension EngineID {
    var bakeoffLabel: String {
        switch self {
        case .apple:          return "Apple Speech"
        case .whisperKit:     return "WhisperKit"
        case .openAIRealtime: return "OpenAI Realtime"
        }
    }
}

/// The decision rule from the spec ("Decision rule"), fixed before any run.
enum BakeoffDecision {
    static let werMargin = 0.05
    static let missRateTieMargin = 0.02
    static let finishMarginMs = 300
    private static let epsilon = 1e-9

    static func winner(_ scores: [EngineScore]) -> (winner: EngineID?, reason: String) {
        let eligible = scores.filter { $0.engine.isOnDevice }
        guard let bestWER = eligible.map(\.wer).min() else {
            return (nil, "No on-device engine was scored, so there is no winner.")
        }
        let contenders = eligible.filter { $0.wer - bestWER <= werMargin + epsilon }
        if contenders.count == 1, let only = contenders.first {
            let reason = eligible.count == 1
                ? "\(only.engine.bakeoffLabel) is the only eligible on-device engine."
                : "\(only.engine.bakeoffLabel) is the only on-device engine within 5 WER points of the best."
            return (only.engine, reason)
        }

        if contenders.allSatisfy({ $0.termMissRate == nil }) {
            let fastest = contenders.min { $0.finishMedianMs < $1.finishMedianMs }!
            return (
                fastest.engine,
                "\(fastest.engine.bakeoffLabel) has the lowest median finish latency (\(fastest.finishMedianMs) ms) because no dictionary terms were scored."
            )
        }

        let ranked = contenders.sorted {
            let lhs = $0.termMissRate ?? 1
            let rhs = $1.termMissRate ?? 1
            return lhs != rhs ? lhs < rhs : $0.finishMedianMs < $1.finishMedianMs
        }
        let top = ranked[0]
        let runnerUp = ranked[1]
        let topMiss = top.termMissRate ?? 1
        let runnerUpMiss = runnerUp.termMissRate ?? 1

        if runnerUpMiss - topMiss <= missRateTieMargin + epsilon {
            let faster = runnerUp.finishMedianMs < top.finishMedianMs ? runnerUp : top
            let slower = faster.engine == top.engine ? runnerUp : top
            return (
                faster.engine,
                "\(faster.engine.bakeoffLabel) wins on lower median finish latency (\(faster.finishMedianMs) ms vs \(slower.finishMedianMs) ms) because the two lowest term miss rates are within 2 points."
            )
        }

        if top.finishMedianMs - runnerUp.finishMedianMs > finishMarginMs {
            return (
                runnerUp.engine,
                "\(runnerUp.engine.bakeoffLabel) wins because \(top.engine.bakeoffLabel), the lowest term miss rate, finishes more than 300 ms slower at the median (\(top.finishMedianMs) ms vs \(runnerUp.finishMedianMs) ms)."
            )
        }
        return (
            top.engine,
            "\(top.engine.bakeoffLabel) has the lowest term miss rate (\(percent(topMiss)) vs \(percent(runnerUpMiss))) and finishes within 300 ms of the runner-up at the median."
        )
    }

    private static func percent(_ rate: Double) -> String {
        String(format: "%.1f%%", rate * 100)
    }
}
