import Foundation
import Observation

/// Settings → Meetings. Every change writes through to `AppSettings` and
/// then calls `onChange`, so the key interceptor and timer pick it up.
@Observable
@MainActor
final class MeetingSettingsViewModel {

    static let presetTaken = "A preset already uses this shortcut."

    private(set) var notesFolder: URL
    private(set) var shortcut: KeyCombo?
    var notesModel: String { didSet { settings.meetingNotesModel = notesModel; onChange() } }
    var retention: MeetingAudioRetention { didSet { settings.meetingAudioRetention = retention; onChange() } }
    var showTimer: Bool { didSet { settings.showMeetingTimer = showTimer; onChange() } }

    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let presets: () -> [PresetShortcut]
    @ObservationIgnored private let chords: () -> ChordSet
    @ObservationIgnored private let onChange: () -> Void
    @ObservationIgnored private let translate: KeyComboValidator.Translator

    init(
        settings: AppSettings = AppSettings(),
        presets: @escaping () -> [PresetShortcut],
        chords: @escaping () -> ChordSet,
        onChange: @escaping () -> Void,
        translate: @escaping KeyComboValidator.Translator = KeyComboValidator.liveTranslator
    ) {
        self.settings = settings
        self.presets = presets
        self.chords = chords
        self.onChange = onChange
        self.translate = translate
        notesFolder = settings.meetingNotesFolder
        shortcut = settings.meetingShortcut
        notesModel = settings.meetingNotesModel ?? ""
        retention = settings.meetingAudioRetention
        showTimer = settings.showMeetingTimer
    }

    /// The model notes use when `notesModel` is empty.
    var notesModelPlaceholder: String { settings.commandModel ?? settings.llmModel }

    func setNotesFolder(_ url: URL) {
        settings.meetingNotesFolder = url
        notesFolder = url
        onChange()
    }

    @discardableResult
    func updateShortcut(_ combo: KeyCombo) -> KeyComboValidator.Verdict {
        if KeyInterceptor.presetMap(presets())[combo] != nil { return .rejected(Self.presetTaken) }
        let verdict = KeyComboValidator.validate(combo, others: [], chords: chords(), translate: translate)
        if case .rejected = verdict { return verdict }
        settings.meetingShortcut = combo
        shortcut = combo
        onChange()
        return verdict
    }

    func clearShortcut() {
        settings.meetingShortcut = nil
        shortcut = nil
        onChange()
    }
}
