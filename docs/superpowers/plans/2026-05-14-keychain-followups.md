# Keychain Refactor Followups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close out two followup items surfaced by the keychain storage refactor: (1) stop `AppSettings.llmProvider`'s setter from clearing the `Key.model` override on no-op writes, and (2) add target-release deletion markers to `LegacyKeychain.swift` and `LegacyKeychainMigrator.swift` so the one-shot migration code doesn't drift indefinitely.

**Architecture:** Followup 1 is a single-file fix at the data layer: the `llmProvider` setter compares the new value against what's already in `UserDefaults` and only triggers the model-override clear when the provider actually changes. This makes the setter idempotent on no-op writes and removes the side-effect amplification that turned every settings save (mic, chord, whisper model, hotkey sounds) into a model-override wipe. Followup 2 is a comment-only change adding a `TODO(release-after-this-ships)` marker so a future reader knows when the migration scaffolding can go.

**Tech Stack:** Swift 6, UserDefaults, Swift Testing.

**Context for the engineer reading this cold:**
- The keychain storage refactor that just landed (plan at `docs/superpowers/plans/2026-05-14-keychain-storage-refactor.md`) introduced `LegacyKeychain` and `LegacyKeychainMigrator` as one-shot migration code. They should be deleted one release after this ships. Followup 2 adds the markers.
- `AppSettings` lives at `voxline/Storage/AppSettings.swift`. The `llmProvider` setter currently unconditionally calls `defaults.removeObject(forKey: Key.model)` after writing the new provider value. That clear-on-write was added so a model id from one provider (e.g. `claude-haiku-4-5`) doesn't survive a switch to another provider where it's invalid (`gpt-4.1-nano`).
- The bug surfaced in the keychain recon: `GeneralSettingsViewModel.commit()` (`voxline/Settings/GeneralSettingsViewModel.swift:158-173`) rebuilds the entire `AppSettings` snapshot and writes every field, including `s.llmProvider = provider`, on EVERY settings change. So changing the mic device or hotkey clobbers any custom `Key.model` override the user set. The wizard guards against this with a `!=` check (`WizardViewModel.swift:74`), but Settings doesn't.
- Fixing the issue at the setter (Followup 1's approach) makes every caller benefit automatically. The wizard's existing guard becomes redundant but stays — it's harmless and matches a defensive pattern.
- Existing test at `voxlineTests/AppSettingsTests.swift:36` (`explicit_model_override_persists_across_provider_switch`) verifies the clear-on-change behavior. It must keep passing — Followup 1 only relaxes the setter for the no-op-write case.
- Project uses Swift Testing (`@Suite`/`@Test`/`#expect`), not XCTest. PBXFileSystemSynchronizedRootGroup means no pbxproj edits needed.
- README.md has unrelated working-tree changes from the user — do NOT stage it in any commit.

---

## File Structure

**Files modified:**
- `voxline/Storage/AppSettings.swift:38-41` — tighten the `llmProvider` setter.
- `voxlineTests/AppSettingsTests.swift` — add two regression tests below the existing `explicit_model_override_persists_across_provider_switch` test.
- `voxline/Storage/LegacyKeychain.swift:4-10` (the existing header doc-comment block) — append a deletion-target line.
- `voxline/Storage/LegacyKeychainMigrator.swift:20-23` (the existing header doc-comment block) — append a deletion-target line.

No new files, no deletions.

---

## Task 1: Tighten `AppSettings.llmProvider` setter so no-op writes preserve the model override

**Files:**
- Modify: `voxline/Storage/AppSettings.swift:30-42`
- Test: `voxlineTests/AppSettingsTests.swift` (add two `@Test` functions to the existing `AppSettingsTests` suite, placed immediately after `explicit_model_override_persists_across_provider_switch`)

### Step 1: Add the failing tests

- [ ] Open `voxlineTests/AppSettingsTests.swift` and find the test `explicit_model_override_persists_across_provider_switch` (around line 36). Immediately after that test's closing brace, add these two tests:

```swift
    @Test func reassigning_same_provider_preserves_model_override() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        s.llmModel = "claude-3-5-sonnet-latest"
        #expect(s.llmModel == "claude-3-5-sonnet-latest")

        // Re-writing the SAME provider must not clear the model override.
        // Without this guard, every unrelated settings change that flows
        // through GeneralSettingsViewModel.commit() wipes the override
        // (commit() writes every field on every change, including provider).
        s.llmProvider = .anthropic
        #expect(s.llmModel == "claude-3-5-sonnet-latest")
    }

    @Test func reassigning_same_provider_when_no_override_is_a_noop() {
        let defaults = makeDefaults()
        var s = AppSettings(defaults: defaults)
        s.llmProvider = .anthropic
        // No explicit model set — llmModel returns the spec default.
        #expect(s.llmModel == .anthropic.defaultModel)
        s.llmProvider = .anthropic
        #expect(s.llmModel == .anthropic.defaultModel)
    }
```

The `makeDefaults()` helper exists in the file (used by the other tests). If for any reason it doesn't, fall back to the same inline pattern the existing test uses for its UserDefaults setup.

### Step 2: Run the new tests to verify they fail

- [ ] Run:

```
xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests/reassigning_same_provider_preserves_model_override -only-testing:voxlineTests/AppSettingsTests/reassigning_same_provider_when_no_override_is_a_noop 2>&1 | tail -20
```

Expected outcome:
- `reassigning_same_provider_preserves_model_override` FAILS — after the second `s.llmProvider = .anthropic` the model override gets wiped by the unconditional `removeObject`, so `s.llmModel` returns the spec default instead of `"claude-3-5-sonnet-latest"`.
- `reassigning_same_provider_when_no_override_is_a_noop` PASSES today — there's nothing to clear, so the buggy clear-on-every-write is invisible in this scenario. It's included as a guardrail to make sure the fix doesn't break the no-override case.

### Step 3: Tighten the setter

- [ ] Open `voxline/Storage/AppSettings.swift`. Find the `llmProvider` computed property (lines ~30-42). The current setter is:

```swift
    var llmProvider: LLMProvider {
        get {
            guard
                let raw = defaults.string(forKey: Key.provider),
                let p = LLMProvider(rawValue: raw)
            else { return .anthropic }
            return p
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.provider)
            defaults.removeObject(forKey: Key.model)
        }
    }
```

Replace the SETTER body (lines 38-41) so it reads:

```swift
        set {
            // Read the previous value off disk so we can detect no-op writes.
            // The model-override clear is intentional on a real provider change
            // (a model id from one provider is almost never valid for another),
            // but it must NOT fire when the same provider is re-assigned —
            // GeneralSettingsViewModel.commit() rebuilds the whole snapshot on
            // every unrelated settings change, and an unconditional clear here
            // would wipe Key.model on every mic / chord / sound toggle.
            let previous = defaults.string(forKey: Key.provider).flatMap(LLMProvider.init(rawValue:))
            defaults.set(newValue.rawValue, forKey: Key.provider)
            if previous != newValue {
                defaults.removeObject(forKey: Key.model)
            }
        }
```

The full computed property after the edit should be:

```swift
    var llmProvider: LLMProvider {
        get {
            guard
                let raw = defaults.string(forKey: Key.provider),
                let p = LLMProvider(rawValue: raw)
            else { return .anthropic }
            return p
        }
        set {
            // Read the previous value off disk so we can detect no-op writes.
            // The model-override clear is intentional on a real provider change
            // (a model id from one provider is almost never valid for another),
            // but it must NOT fire when the same provider is re-assigned —
            // GeneralSettingsViewModel.commit() rebuilds the whole snapshot on
            // every unrelated settings change, and an unconditional clear here
            // would wipe Key.model on every mic / chord / sound toggle.
            let previous = defaults.string(forKey: Key.provider).flatMap(LLMProvider.init(rawValue:))
            defaults.set(newValue.rawValue, forKey: Key.provider)
            if previous != newValue {
                defaults.removeObject(forKey: Key.model)
            }
        }
    }
```

The block-comment above the property declaration (lines 27-29) should be updated too, since it currently says the setter clears the override unconditionally. Change:

```swift
    /// LLM provider choice. Defaults to .anthropic.
    /// Setting a new provider clears any model override so the spec default
    /// for the new provider takes over (a model id from one provider is
    /// almost never valid for another).
```

to:

```swift
    /// LLM provider choice. Defaults to .anthropic.
    /// Changing the provider clears any model override so the spec default
    /// for the new provider takes over (a model id from one provider is
    /// almost never valid for another). Re-assigning the same provider is
    /// a no-op — the override survives.
```

### Step 4: Run the new tests to verify they pass

- [ ] Run:

```
xcodebuild test -scheme voxline -destination 'platform=macOS' -only-testing:voxlineTests/AppSettingsTests 2>&1 | tail -20
```

Expected: every test in `AppSettingsTests` passes, including the existing `explicit_model_override_persists_across_provider_switch` (the clear-on-change behavior is preserved) and the two new tests.

### Step 5: Run the full test suite

- [ ] Run:

```
xcodebuild test -scheme voxline -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: all tests pass EXCEPT `VocabCleanupIntegrationTests.cleanup_normalizes_phonetic_misses_to_canonical_terms`, which is a pre-existing flaky integration test (it requires a live API key in DPK and throws `.invalidAPIKey` when none is present). That failure is unrelated to this fix.

If any OTHER test fails — for example, anything in `GeneralSettingsViewModelTests` or `WizardViewModelTests` — investigate before committing. The wizard's existing `!=` guard becomes redundant after this fix but it's harmless; the wizard tests should still pass unchanged.

### Step 6: Commit

- [ ] Stage and commit only the two changed files:

```
git add voxline/Storage/AppSettings.swift voxlineTests/AppSettingsTests.swift
git commit -m "fix(settings): preserve model override on no-op provider writes"
```

Verify `git status` shows README.md is still unstaged (it has unrelated changes).

---

## Task 2: Add deletion markers to `LegacyKeychain` and `LegacyKeychainMigrator`

**Files:**
- Modify: `voxline/Storage/LegacyKeychain.swift` (header doc comment)
- Modify: `voxline/Storage/LegacyKeychainMigrator.swift` (header doc comment)

Comment-only change. No tests.

### Step 1: Update `LegacyKeychain.swift` header

- [ ] Open `voxline/Storage/LegacyKeychain.swift`. The current header doc comment (lines 4-10) reads:

```swift
/// Wrapper around the legacy file keychain (`~/Library/Keychains/login.keychain-db`).
/// Exists ONLY for `LegacyKeychainMigrator` to lift orphaned entries written
/// by older voxline builds whose DPK probe returned false. Production reads
/// and writes never touch this type.
///
/// Delete this file (and `LegacyKeychainMigrator`) one release after the
/// migration has shipped and baked.
```

Append one line so it reads:

```swift
/// Wrapper around the legacy file keychain (`~/Library/Keychains/login.keychain-db`).
/// Exists ONLY for `LegacyKeychainMigrator` to lift orphaned entries written
/// by older voxline builds whose DPK probe returned false. Production reads
/// and writes never touch this type.
///
/// Delete this file (and `LegacyKeychainMigrator`) one release after the
/// migration has shipped and baked.
// TODO(post-2026-05-14-migration): delete this file. The keychain storage
// refactor that introduced it shipped on 2026-05-14; one user-facing release
// after that, every active install has either migrated or been reset.
```

### Step 2: Update `LegacyKeychainMigrator.swift` header

- [ ] Open `voxline/Storage/LegacyKeychainMigrator.swift`. The current header doc comment (lines 4-23) ends with:

```swift
/// Delete this type (and `LegacyKeychain`) one release after this migration
/// has shipped and baked. By then every active install has either migrated
/// or had the legacy entries deleted by the reset script.
```

Append the same `TODO` marker immediately after the doc-comment block closes (so it sits between the doc comment and the `struct LegacyKeychainMigrator {` line):

```swift
/// Delete this type (and `LegacyKeychain`) one release after this migration
/// has shipped and baked. By then every active install has either migrated
/// or had the legacy entries deleted by the reset script.
// TODO(post-2026-05-14-migration): delete this file (and the matching call
// site in voxlineApp.init()). See LegacyKeychain.swift for the rationale.
```

Also delete the corresponding entry from `voxlineApp.init()` when this followup is honored, but that's a future change — NOT part of this task. This task only adds the marker.

### Step 3: Verify the project still builds

- [ ] Run:

```
xcodebuild -scheme voxline -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: `BUILD SUCCEEDED`. Comment-only edits cannot break the build, but verify anyway as a sanity check.

### Step 4: Commit

- [ ] Stage and commit:

```
git add voxline/Storage/LegacyKeychain.swift voxline/Storage/LegacyKeychainMigrator.swift
git commit -m "chore(keychain): mark LegacyKeychain + migrator for post-migration deletion"
```

Verify `git status` shows README.md still unstaged.

---

## Summary of Final File State

After both tasks land:

**Modified:**
- `voxline/Storage/AppSettings.swift` — `llmProvider` setter now no-op-safe on same-provider writes; updated doc comment.
- `voxlineTests/AppSettingsTests.swift` — two regression tests added.
- `voxline/Storage/LegacyKeychain.swift` — deletion marker appended.
- `voxline/Storage/LegacyKeychainMigrator.swift` — deletion marker appended.

**No new files, no deletions.**
