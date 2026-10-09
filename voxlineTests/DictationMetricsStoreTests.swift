import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct DictationMetricsStoreTests {

    private func metrics(
        total: Int,
        transcribe: Int = 0,
        insert: Int = 0,
        kind: DictationMetrics.Kind = .dictation,
        firstPartial: Int? = nil,
        skippedCleanup: Bool = false
    ) -> DictationMetrics {
        DictationMetrics(
            timestamp: Date(), kind: kind, audioDuration: 1.0,
            captureTailMs: 0, transcribeMs: transcribe, cleanupMs: 0, insertMs: insert, totalMs: total,
            engineID: "test", modelID: "test-model", wordCount: 3,
            firstPartialMs: firstPartial, skippedCleanup: skippedCleanup
        )
    }

    @Test func record_keepsNewestFirst_andCapsAtCapacity() {
        let store = DictationMetricsStore()
        for i in 0..<(DictationMetricsStore.capacity + 5) {
            store.record(metrics(total: i))
        }
        #expect(store.items.count == DictationMetricsStore.capacity)
        #expect(store.items.first?.totalMs == DictationMetricsStore.capacity + 4)
        #expect(store.items.last?.totalMs == 5)
    }

    @Test func median_isNilWhenEmpty() {
        #expect(DictationMetricsStore().median(\.totalMs) == nil)
    }

    @Test func median_oddCount_isMiddleValue() {
        let store = DictationMetricsStore()
        for t in [900, 100, 500] { store.record(metrics(total: t)) }
        #expect(store.median(\.totalMs) == 500)
    }

    @Test func median_evenCount_averagesTheMiddlePair() {
        let store = DictationMetricsStore()
        for t in [100, 400, 200, 300] { store.record(metrics(total: t)) }
        #expect(store.median(\.totalMs) == 250)
    }

    @Test func median_followsTheRequestedField() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 1000, transcribe: 10))
        store.record(metrics(total: 2000, transcribe: 30))
        store.record(metrics(total: 3000, transcribe: 20))
        #expect(store.median(\.transcribeMs) == 20)
    }

    @Test func median_filtersByKind_defaultingToDictation() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 100, kind: .dictation))
        store.record(metrics(total: 9_000, kind: .command))
        store.record(metrics(total: 9_500, kind: .command))
        store.record(metrics(total: 300, kind: .dictation))
        #expect(store.median(\.totalMs) == 200)
        #expect(store.median(\.totalMs, kind: .dictation) == 200)
        #expect(store.median(\.totalMs, kind: .command) == 9_250)
    }

    @Test func median_isNilWhenNoRowsOfTheKind() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 100, kind: .command))
        #expect(store.median(\.totalMs) == nil)
    }

    @Test func median_excludingZero_dropsZeroRows() {
        let store = DictationMetricsStore()
        for insert in [0, 40, 0, 60, 0] { store.record(metrics(total: 1, insert: insert)) }
        #expect(store.median(\.insertMs) == 0)
        #expect(store.median(\.insertMs, excludingZero: true) == 50)
    }

    @Test func median_excludingZero_isNilWhenEveryRowIsZero() {
        let store = DictationMetricsStore()
        for _ in 0..<3 { store.record(metrics(total: 1, insert: 0)) }
        #expect(store.median(\.insertMs, excludingZero: true) == nil)
    }

    @Test func median_ofOptionalField_skipsMissingValues() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 1, firstPartial: nil))
        store.record(metrics(total: 1, firstPartial: 300))
        store.record(metrics(total: 1, firstPartial: 500))
        store.record(metrics(total: 1, kind: .command, firstPartial: 10))
        #expect(store.median(\.firstPartialMs) == 400)
    }

    @Test func median_ofOptionalField_isNilWhenNoneRecorded() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 1, firstPartial: nil))
        #expect(store.median(\.firstPartialMs) == nil)
    }

    @Test func count_followsKind() {
        let store = DictationMetricsStore()
        store.record(metrics(total: 1, kind: .dictation))
        store.record(metrics(total: 1, kind: .command))
        store.record(metrics(total: 1, kind: .dictation))
        #expect(store.count(kind: .dictation) == 2)
        #expect(store.count(kind: .command) == 1)
    }
}
