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
    var notesModel: String {
        didSet {
            guard !reloading else { return }
            settings.meetingNotesModel = notesModel
            onChange()
        }
    }
    var retention: MeetingAudioRetention { didSet { settings.meetingAudioRetention = retention; onChange() } }
    var showTimer: Bool { didSet { settings.showMeetingTimer = showTimer; onChange() } }
    var liveTranscript: Bool { didSet { settings.meetingLiveTranscript = liveTranscript; onChange() } }

    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private let presets: () -> [PresetShortcut]
    @ObservationIgnored private let chords: () -> ChordSet
    @ObservationIgnored private let onChange: () -> Void
    @ObservationIgnored private let translate: KeyComboValidator.Translator
    @ObservationIgnored private var reloading = false

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
        liveTranscript = settings.meetingLiveTranscript
    }

    /// Re-reads the notes model, which a provider change on another page
    /// clears, without writing it back.
    func reload() {
        let stored = settings.meetingNotesModel ?? ""
        guard stored != notesModel.trimmed else { return }
        reloading = true
        notesModel = stored
        reloading = false
    }

    /// The model notes use when `notesModel` is empty.
    var notesModelPlaceholder: String { settings.commandModel ?? settings.llmModel }

    func setNotesFolder(_ url: URL) {
        settings.meetingNotesFolder = url
        notesFolder = url
        onChange()
    }

    /// A rejected combo is not applied. An accepted one, with or without a
    /// warning, is applied and saved; `shortcutWarning` keeps showing the
    /// warning.
    @discardableResult
    func updateShortcut(_ combo: KeyCombo) -> KeyComboValidator.Verdict {
        if KeyInterceptor.presetMap(presets())[combo] != nil { return .rejected(Self.presetTaken) }
        let verdict = validate(combo)
        if case .rejected = verdict { return verdict }
        settings.meetingShortcut = combo
        shortcut = combo
        onChange()
        return verdict
    }

    /// The shortcut validated against the current chords: the app-shortcut
    /// or typed-character warning it was accepted with, or a conflict with a
    /// chord changed after it was recorded. Nil when there is no shortcut or
    /// it is clean.
    var shortcutWarning: String? {
        guard let shortcut else { return nil }
        switch validate(shortcut) {
        case .ok: return nil
        case .warning(let message), .rejected(let message): return message
        }
    }

    private func validate(_ combo: KeyCombo) -> KeyComboValidator.Verdict {
        KeyComboValidator.validate(combo, others: [], chords: chords(), translate: translate)
    }

    func clearShortcut() {
        settings.meetingShortcut = nil
        shortcut = nil
        onChange()
    }
}
