import Testing
import Foundation
@testable import voxline

@Suite @MainActor struct TranscriptionEnginesTests {

    private func makeEngines() -> (TranscriptionEngines, AppSettings, AppleSpeechEngine, WhisperKitEngine) {
        let suiteName = "voxline-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        let apple = AppleSpeechEngine()
        let whisperKit = WhisperKitEngine(service: TranscriptionService())
        return (TranscriptionEngines(settings: settings, apple: apple, whisperKit: whisperKit), settings, apple, whisperKit)
    }

    @Test func maps_each_on_device_id_to_its_engine() {
        let (engines, _, apple, whisperKit) = makeEngines()
        #expect(engines.engine(for: .apple) === apple)
        #expect(engines.engine(for: .whisperKit) === whisperKit)
        #expect(engines.whisperKit === whisperKit)
    }

    @Test func cloud_id_maps_to_the_on_device_default_until_the_cloud_engine_lands() {
        let (engines, _, _, _) = makeEngines()
        #expect(engines.engine(for: .openAIRealtime) === engines.engine(for: .onDeviceDefault))
        #expect(engines.engine(for: .openAIRealtime).id.isOnDevice)
    }

    @Test func current_follows_the_setting_live() {
        let (engines, settings, apple, whisperKit) = makeEngines()
        #expect(engines.current === engines.engine(for: EngineID.default))
        var writer = settings
        writer.transcriptionEngine = .apple
        #expect(engines.current === apple)
        writer.transcriptionEngine = .whisperKit
        #expect(engines.current === whisperKit)
    }
}
