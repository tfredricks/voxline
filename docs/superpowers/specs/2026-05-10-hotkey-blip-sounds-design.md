# Hotkey blip sounds — design

Date: 2026-05-10

## Goal

Give the user audible feedback when hold-to-talk recording starts and stops. A short "Tink" plays when the chord is pressed (recording begins), and a short "Pop" plays when it is released (recording ends, before transcription runs).

## Why

Voxline is push-to-talk. Without feedback the user has to guess whether the chord registered. Visual cues exist (the recording pill window) but eyes are usually on the target field, not the menu bar. Audio is the right channel.

## Non-goals

- No completion sound after transcription/insertion. The stop blip fires on key release, not on text-arrival.
- No custom audio assets — system sounds only.
- No per-mode sound customization.
- No volume slider; system volume controls everything.

## User-facing surface

- **Sounds:** `Tink` (start) and `Pop` (stop), both built-in macOS system sounds at `/System/Library/Sounds/`.
- **Toggle:** General settings gains a `Sounds` section with one checkbox: "Play sound on record start/stop". Default ON.
- **Persisted key:** `voxline.sounds.hotkey` in `UserDefaults`. Absence-of-key means ON (so existing users get the sound on next launch without an explicit migration).

## Architecture

### New component: `HotkeySoundPlayer`

Location: `voxline/Audio/HotkeySoundPlayer.swift`.

Responsibilities:
- Expose `playStart()` and `playStop()`.
- On each call, read `AppSettings.playHotkeySounds`. If false, return.
- If true, call `NSSound(named: "Tink")?.play()` (or `"Pop"`). Fire-and-forget.

Constructor injection of a `playSound: (String) -> Void` closure (defaulted to the `NSSound` implementation) makes the unit tests possible without making real noise.

### Settings plumbing

1. `AppSettings.Key.playHotkeySounds = "voxline.sounds.hotkey"`.
2. `AppSettings.playHotkeySounds: Bool` — getter returns `true` when the key is unset (using `defaults.object(forKey:) == nil` to distinguish unset from explicit `false`); setter writes the bool.
3. `GeneralSettingsViewModel`:
   - new `var playHotkeySounds: Bool` initialized from settings;
   - `save()` writes it back.
4. `GeneralSettingsSnapshot` gains `playHotkeySounds: Bool`. The `AppCoordinator.apply(_:)` body does not need to push it anywhere — `HotkeySoundPlayer` reads `AppSettings` live each call. (We carry it through the snapshot for symmetry/testability.)
5. `GeneralSettingsView` adds:
   ```swift
   Section("Sounds") {
       Toggle("Play sound on record start/stop", isOn: $vm.playHotkeySounds)
   }
   ```

### Wiring into the hotkey path

In `voxlineApp.installHotkey`:

```swift
monitor.onStartRecording = { [weak self, weak state] in
    self?.soundPlayer?.playStart()
    self?.pipeline?.startRecording()
    if let state { self?.pillWindow?.updateVisibility(state: state) }
}
monitor.onFinalizeRecording = { [weak self, weak state] in
    self?.soundPlayer?.playStop()
    Task { @MainActor in
        await self?.pipeline?.finalizeRecording()
        ...
    }
}
```

Stop sound fires synchronously on the main thread before the `await`, so the user hears it the instant they release the keys — independent of transcription latency.

`AppCoordinator` gains a `soundPlayer: HotkeySoundPlayer` property, constructed once during init.

## Data flow

```
chord pressed
  → HotkeyMonitor.onStartRecording fires
  → AppCoordinator: soundPlayer.playStart()  → NSSound("Tink").play()
                  : pipeline.startRecording()

chord released
  → HotkeyMonitor.onFinalizeRecording fires
  → AppCoordinator: soundPlayer.playStop()   → NSSound("Pop").play()
                  : Task { await pipeline.finalizeRecording() ... }
```

## Mic-bleed tradeoff

`NSSound.play()` routes to the default output device. A user on speakers with a nearby mic may capture ~50ms of "Tink" tail at the very front of their recording. Acceptable: Whisper handles short transients; the alternative (gating mic-open on sound-finished callbacks) would add user-perceptible start latency to every dictation. The stop blip has no such concern — capture has already ended.

## Testing

### Unit tests

- `AppSettingsTests`:
  - `playHotkeySounds defaults to true when unset`.
  - `playHotkeySounds round-trips true and false`.
- `HotkeySoundPlayerTests` (using injected closure):
  - `playStart calls underlying with "Tink" when enabled`.
  - `playStop calls underlying with "Pop" when enabled`.
  - `playStart and playStop do nothing when disabled`.
  - `disabling mid-session takes effect on next call` (mutate `AppSettings`, verify next call no-ops).
- Extend `GeneralSettingsViewModelTests`:
  - `loads_current_values_on_init` covers `playHotkeySounds`.
  - `save_persists_and_calls_applier` covers `playHotkeySounds`.

### Manual smoke

1. Launch app, press chord — hear "Tink", release — hear "Pop".
2. Open General settings, uncheck the toggle, Save.
3. Press/release chord — silent.
4. Re-check toggle, Save — sounds return.

## Files touched

| File | Change |
|---|---|
| `voxline/Audio/HotkeySoundPlayer.swift` | new |
| `voxline/Storage/AppSettings.swift` | add key + accessor |
| `voxline/Settings/GeneralSettingsApplier.swift` | add `playHotkeySounds` to snapshot |
| `voxline/Settings/GeneralSettingsViewModel.swift` | property + save |
| `voxline/Settings/GeneralSettingsView.swift` | new Section |
| `voxline/voxlineApp.swift` | construct player, call from hotkey callbacks |
| `voxlineTests/AppSettingsTests.swift` | new tests (or extend existing) |
| `voxlineTests/HotkeySoundPlayerTests.swift` | new |
| `voxlineTests/GeneralSettingsViewModelTests.swift` | extend |
