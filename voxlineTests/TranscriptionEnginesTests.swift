import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct TranscriptionEnginesTests {

    private func makeEngines() -> (TranscriptionEngines, AppSettings, AppleSpeechEngine, WhisperKitEngine, OpenAIRealtimeEngine) {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let apple = AppleSpeechEngine()
        let whisperKit = WhisperKitEngine(service: TranscriptionService())
        let openAI = OpenAIRealtimeEngine(keychain: InMemoryKeychain(), transport: { _ in FakeRealtimeTransport() })
        let engines = TranscriptionEngines(settings: settings, apple: apple, whisperKit: whisperKit, openAI: openAI)
        return (engines, settings, apple, whisperKit, openAI)
    }

    @Test func maps_each_id_to_its_engine() {
        let (engines, _, apple, whisperKit, openAI) = makeEngines()
        #expect(engines.engine(for: .apple) === apple)
        #expect(engines.engine(for: .whisperKit) === whisperKit)
        #expect(engines.engine(for: .openAIRealtime) === openAI)
        #expect(engines.whisperKit === whisperKit)
    }

    @Test func the_on_device_default_is_never_the_cloud_engine() {
        let (engines, _, _, _, _) = makeEngines()
        #expect(engines.engine(for: .onDeviceDefault).id.isOnDevice)
    }

    @Test func current_follows_the_setting_live() {
        let (engines, settings, apple, whisperKit, openAI) = makeEngines()
        #expect(engines.current === engines.engine(for: EngineID.default))
        var writer = settings
        writer.transcriptionEngine = .apple
        #expect(engines.current === apple)
        writer.transcriptionEngine = .whisperKit
        #expect(engines.current === whisperKit)
        writer.transcriptionEngine = .openAIRealtime
        #expect(engines.current === openAI)
    }
}
