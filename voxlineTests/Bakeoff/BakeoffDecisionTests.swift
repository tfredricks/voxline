import Testing
@testable import voxline

private func score(
    _ engine: EngineID,
    wer: Double = 0.05,
    miss: Double? = 0.1,
    finish: Int = 200,
    firstPartial: Int? = 300
) -> EngineScore {
    EngineScore(
        engine: engine,
        wer: wer,
        termMissRate: miss,
        finishMedianMs: finish,
        finishP90Ms: finish + 100,
        firstPartialMedianMs: firstPartial
    )
}

@Suite struct BakeoffDecisionTests {

    @Test func lower_miss_rate_wins_when_it_is_within_the_latency_margin() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 400),
            score(.whisperKit, miss: 0.30, finish: 150),
        ])
        #expect(result.winner == .apple)
    }

    @Test func lower_miss_rate_loses_when_more_than_the_margin_slower() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 600),
            score(.whisperKit, miss: 0.30, finish: 150),
        ])
        #expect(result.winner == .whisperKit)
        #expect(result.reason.contains("300 ms"))
    }

    @Test func margin_of_exactly_300_ms_keeps_the_lower_miss_rate() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 450),
            score(.whisperKit, miss: 0.30, finish: 150),
        ])
        #expect(result.winner == .apple)
    }

    @Test func input_order_does_not_matter() {
        let result = BakeoffDecision.winner([
            score(.whisperKit, miss: 0.30, finish: 150),
            score(.apple, miss: 0.10, finish: 600),
        ])
        #expect(result.winner == .whisperKit)
    }

    @Test func near_equal_miss_rates_go_to_the_lower_latency() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 700),
            score(.whisperKit, miss: 0.11, finish: 150),
        ])
        #expect(result.winner == .whisperKit)
        #expect(result.reason.contains("2 points"))
    }

    @Test func miss_rates_exactly_two_points_apart_count_as_near_equal() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 700),
            score(.whisperKit, miss: 0.12, finish: 150),
        ])
        #expect(result.winner == .whisperKit)
    }

    @Test func miss_rates_just_over_two_points_apart_are_not_near_equal() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 400),
            score(.whisperKit, miss: 0.13, finish: 150),
        ])
        #expect(result.winner == .apple)
    }

    @Test func the_cloud_engine_is_never_the_winner() {
        let result = BakeoffDecision.winner([
            score(.apple, wer: 0.10, miss: 0.40, finish: 300),
            score(.openAIRealtime, wer: 0.01, miss: 0, finish: 50),
        ])
        #expect(result.winner == .apple)
    }

    @Test func the_cloud_engine_does_not_set_the_wer_baseline() {
        let result = BakeoffDecision.winner([
            score(.apple, wer: 0.12, miss: 0.10, finish: 200),
            score(.whisperKit, wer: 0.14, miss: 0.30, finish: 150),
            score(.openAIRealtime, wer: 0.01, miss: 0, finish: 50),
        ])
        #expect(result.winner == .apple)
    }

    @Test func only_a_cloud_engine_means_no_winner() {
        let result = BakeoffDecision.winner([score(.openAIRealtime, miss: 0)])
        #expect(result.winner == nil)
        #expect(!result.reason.isEmpty)
    }

    @Test func no_scores_means_no_winner() {
        let result = BakeoffDecision.winner([])
        #expect(result.winner == nil)
        #expect(!result.reason.isEmpty)
    }

    @Test func an_engine_more_than_five_wer_points_behind_is_dropped() {
        let result = BakeoffDecision.winner([
            score(.apple, wer: 0.20, miss: 0.0, finish: 100),
            score(.whisperKit, wer: 0.10, miss: 0.5, finish: 900),
        ])
        #expect(result.winner == .whisperKit)
        #expect(result.reason.contains("5 WER points"))
    }

    @Test func an_engine_exactly_five_wer_points_behind_stays_in() {
        let result = BakeoffDecision.winner([
            score(.apple, wer: 0.15, miss: 0.0, finish: 100),
            score(.whisperKit, wer: 0.10, miss: 0.5, finish: 150),
        ])
        #expect(result.winner == .apple)
    }

    @Test func a_single_eligible_engine_wins() {
        let result = BakeoffDecision.winner([score(.whisperKit)])
        #expect(result.winner == .whisperKit)
        #expect(result.reason.contains("only"))
    }

    @Test func without_term_data_the_lowest_median_finish_wins() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: nil, finish: 500),
            score(.whisperKit, miss: nil, finish: 150),
        ])
        #expect(result.winner == .whisperKit)
        #expect(result.reason.contains("latency"))
    }

    @Test func an_engine_without_a_miss_rate_ranks_behind_engines_that_have_one() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: nil, finish: 100),
            score(.whisperKit, miss: 0.5, finish: 200),
        ])
        #expect(result.winner == .whisperKit)
    }

    @Test func a_cloud_engine_with_perfect_numbers_leaves_the_decision_to_the_two_on_device_engines() {
        let result = BakeoffDecision.winner([
            score(.apple, miss: 0.10, finish: 400),
            score(.whisperKit, miss: 0.30, finish: 150),
            score(.openAIRealtime, miss: 0.0, finish: 10),
        ])
        #expect(result.winner == .apple)
    }

    @Test func every_verdict_has_a_one_sentence_reason() {
        let verdicts = [
            BakeoffDecision.winner([]),
            BakeoffDecision.winner([score(.apple)]),
            BakeoffDecision.winner([score(.apple, miss: nil, finish: 1), score(.whisperKit, miss: nil, finish: 2)]),
            BakeoffDecision.winner([score(.apple, miss: 0.1), score(.whisperKit, miss: 0.5)]),
            BakeoffDecision.winner([score(.apple, miss: 0.1, finish: 900), score(.whisperKit, miss: 0.5, finish: 100)]),
            BakeoffDecision.winner([score(.apple, miss: 0.1), score(.whisperKit, miss: 0.11, finish: 100)]),
        ]
        for verdict in verdicts {
            #expect(verdict.reason.hasSuffix("."))
            #expect(!verdict.reason.contains("\n"))
        }
    }
}

@Suite struct EngineScoreAggregationTests {

    private func result(
        _ reference: String,
        _ hypothesis: String,
        finish: Int,
        firstPartial: Int? = nil
    ) -> BakeoffClipResult {
        BakeoffClipResult(reference: reference, hypothesis: hypothesis, finishMs: finish, firstPartialMs: firstPartial)
    }

    @Test func wer_is_pooled_over_all_reference_words() {
        let score = EngineScore(engine: .apple, terms: [], results: [
            result("one two", "one two", finish: 100),
            result("a b c d e f g h", "a b c d e f g x", finish: 100),
        ])
        #expect(score.wer == 0.1)
    }

    @Test func miss_rate_pools_term_hits_across_clips() {
        let score = EngineScore(engine: .apple, terms: ["LangGraph", "Argmax"], results: [
            result("I use LangGraph", "I use lang graph", finish: 100),
            result("Argmax ships it", "our max ships it", finish: 100),
        ])
        #expect(score.termMissRate == 0.5)
    }

    @Test func miss_rate_is_nil_without_terms_or_term_occurrences() {
        let noTerms = EngineScore(engine: .apple, terms: [], results: [result("hello", "hello", finish: 1)])
        #expect(noTerms.termMissRate == nil)
        let absent = EngineScore(engine: .apple, terms: ["Kubernetes"], results: [result("hello", "hello", finish: 1)])
        #expect(absent.termMissRate == nil)
    }

    @Test func latency_figures_come_from_the_per_clip_timings() {
        let score = EngineScore(engine: .whisperKit, terms: [], results: [
            result("a", "a", finish: 100, firstPartial: 400),
            result("a", "a", finish: 300, firstPartial: nil),
            result("a", "a", finish: 200, firstPartial: 600),
        ])
        #expect(score.finishMedianMs == 200)
        #expect(score.finishP90Ms == 300)
        #expect(score.firstPartialMedianMs == 500)
    }

    @Test func failed_clips_count_as_deletions_but_not_as_latency_samples() {
        let score = EngineScore(engine: .whisperKit, terms: ["Argmax"], results: [
            result("Argmax ships it", "Argmax ships it", finish: 300, firstPartial: 500),
            BakeoffClipResult(reference: "Argmax ships it", hypothesis: "", finishMs: 0, firstPartialMs: nil, failed: true),
            BakeoffClipResult(reference: "ships it", hypothesis: "", finishMs: 90_000, firstPartialMs: 80_000, failed: true),
        ])
        #expect(score.wer == 5.0 / 8.0)
        #expect(score.termMissRate == 0.5)
        #expect(score.finishMedianMs == 300)
        #expect(score.finishP90Ms == 300)
        #expect(score.firstPartialMedianMs == 500)
    }

    @Test func first_partial_median_is_nil_when_no_clip_produced_a_partial() {
        let score = EngineScore(engine: .apple, terms: [], results: [result("a", "a", finish: 100)])
        #expect(score.firstPartialMedianMs == nil)
    }
}
