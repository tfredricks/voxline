import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct DictationMetricsStoreTests {

    private func metrics(total: Int, transcribe: Int = 0) -> DictationMetrics {
        DictationMetrics(
            timestamp: Date(), kind: .dictation, audioDuration: 1.0,
            captureTailMs: 0, transcribeMs: transcribe, cleanupMs: 0, insertMs: 0, totalMs: total,
            engineID: "test", modelID: "test-model", wordCount: 3
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
}
