# Update Check Design

Date: 2026-05-20
Status: Approved, ready for implementation planning

## Goal

Give voxline users a reliable, low-friction path to new versions when the project releases them — without ever interrupting an in-flight dictation.

Concretely: an automatic background check plus a manual "Check for Updates…" menu item, a non-modal "update available" indicator, EdDSA-signed updates that auto-install with one click, and a release pipeline that produces notarized DMGs and an appcast feed.

## Non-goals

- Release channels (stable vs. beta). One channel only for now.
- Auto-install without user confirmation. Always prompt.
- In-app changelog rendering beyond what Sparkle shows from the appcast.
- Migration of existing users (there are no released versions yet).

## Approach

Use **Sparkle 2** as the update framework. Sparkle handles version comparison, EdDSA signature verification, download, in-place install, and relaunch. voxline supplies a thin wrapper, a non-modal user surface tuned for a menu-bar app, and a release pipeline that produces signed artifacts and the appcast feed.

Considered and rejected:

- **DIY against the GitHub Releases API.** Would reimplement Sparkle's download/install/verify machinery. Subtle bits (atomic replacement of a running app, app translocation, signature verification) are easy to get wrong. No benefit.
- **Homebrew Cask only.** Useful as a complementary distribution channel later, but doesn't cover users who don't use brew.

## Architecture

Four pieces — three in the app, one in CI:

1. **`Sparkle.framework`** — added as a Swift Package dependency (`https://github.com/sparkle-project/Sparkle`, pinned to 2.x).
2. **`UpdateService`** (Swift, in `voxline/Updates/`) — owns a single `SPUStandardUpdaterController` for the app's lifetime. Exposes `checkForUpdates()` for the menu item, `automaticallyChecksForUpdates: Bool` for the Settings toggle, and implements the user-driver delegate hooks that drive the non-modal indicator and the dictation-aware deferral logic. Wrapping Sparkle keeps the surface testable and prevents Sparkle types from leaking into the rest of the codebase.
3. **`appcast.xml`** — hosted on GitHub Pages at `https://tfredricks.github.io/voxline/appcast.xml`. Configured into `Info.plist` as `SUFeedURL`.
4. **Release workflow** (`.github/workflows/release.yml`, new) — triggered on `v*` tag push. Builds, signs, notarizes, packages a DMG, EdDSA-signs the DMG, regenerates the appcast, and publishes both artifact and feed.

`Info.plist` additions:

- `SUFeedURL` = the GitHub Pages appcast URL
- `SUPublicEDKey` = the EdDSA public key (the private half lives only in CI secrets)
- `SUEnableAutomaticChecks` = `YES`
- `SUScheduledCheckInterval` = `86400` (24h)

## Release pipeline

New workflow `.github/workflows/release.yml`, triggered on push of a tag matching `v*`. Steps:

1. **Checkout** with `fetch-depth: 0` (build number is `git rev-list --count`, matching current CI).
2. **Import signing assets** — Developer ID Application cert (`.p12`) and notarization API key, both stored as GitHub Actions secrets, imported into a temporary keychain that's torn down at job end.
3. **Build Release** — `xcodebuild -scheme voxline -configuration Release archive` → export `voxline.app` with Developer ID signing. Reuses the existing `xcbeautify` gate.
4. **Notarize** — `xcrun notarytool submit ... --wait` then `xcrun stapler staple voxline.app`. Hard fail if notarization fails.
5. **Package** — wrap the stapled `.app` in `voxline-<version>.dmg` (via `create-dmg` or `hdiutil`).
6. **EdDSA-sign the DMG** — `sign_update voxline-<version>.dmg` using the `SPARKLE_ED_PRIVATE_KEY` secret. Emits an ed25519 signature.
7. **Regenerate appcast** — `generate_appcast` reads the DMG + signature + tag annotation message and writes a new `<item>` to `appcast.xml`.
8. **Publish** — upload the DMG to the GitHub Release for the tag; commit the updated `appcast.xml` to the branch GitHub Pages serves (proposed: `gh-pages`).

Secrets to provision once:

- `APPLE_NOTARY_API_KEY` (+ key id + issuer id)
- `SPARKLE_ED_PRIVATE_KEY`

Release notes flow: tag annotation message → GitHub Release body → appcast `<description>`. One source of truth.

## In-app integration

Files added / touched:

- **`voxline/Updates/UpdateService.swift`** (new). Holds `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)`. Public surface:
  - `func checkForUpdates()` — forwards to the underlying updater (called from the menu item).
  - `var automaticallyChecksForUpdates: Bool { get set }` — mirrors `SPUUpdater.automaticallyChecksForUpdates`.
  - `var hasPendingUpdate: Bool` — observable, drives the menu-bar badge.
  - Delegate hooks: gentle-reminders mode (see below), dictation-aware deferral.
- **`voxline/App/AppDelegate.swift`** — instantiate one `UpdateService` at launch, retain for the app's lifetime. Sparkle owns its own scheduling thread.
- **Menu-bar menu** — insert "Check for Updates…" above "Quit". When `hasPendingUpdate == true`, also insert an "Install Update…" item near the top and decorate the menu-bar icon with a small badge.
- **Settings UI** — one new row: a toggle, "Automatically check for updates", bound to `updateService.automaticallyChecksForUpdates`. No release-channel picker, no interval slider, no pre-release toggle.
- **`Info.plist`** — the four keys listed in Architecture.

First-launch behavior: with `SUEnableAutomaticChecks=YES`, Sparkle skips its first-run opt-in prompt — voxline declares the default up front. Users who turn it off in Settings have that preference respected (stored in `UserDefaults`).

## User surface: non-modal by default

For a hold-to-talk app, a focus-stealing modal is uniquely bad — it could land mid-utterance or in the post-release text-injection window. Two layers:

**Layer 1 — gentle reminders mode for scheduled checks.**
Implement `SPUStandardUserDriverDelegate.standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` and return `andInImmediateFocus = false`. Sparkle then skips the modal sheet for scheduled checks and hands voxline the responsibility of surfacing the reminder. voxline surfaces it via:

- A small badge on the menu-bar icon while `hasPendingUpdate == true`.
- An "Update Available — Install…" item near the top of the menu.

Manual checks (the "Check for Updates…" item) still use Sparkle's normal modal flow because the user explicitly asked for it.

**Layer 2 — dictation-aware deferral.**
A `DictationActivityMonitor` exposes:

- `var isActive: Bool` — true between hotkey-down and text-injection-complete.
- `var lastActivityAt: Date?` — updated on session start, end, and injection completion.

`UpdateService` defers user-visible Sparkle steps from the **scheduled** code path (gentle reminder surfacing, install prompt, relaunch) while `isActive == true` **or** `Date() - lastActivityAt < 120 seconds`. Background download is allowed at any time (silent, no UI). The **manual** path ("Check for Updates…") bypasses deferral entirely — when the user explicitly asks, honor the request and let Sparkle's modal flow run as normal, even mid-dictation. The cost is rare and self-inflicted.

The 120-second idle window is a fixed constant — no user setting. It covers Slack-message bursts and the "compose, dictate, edit, dictate again" loop without making a user who walked away wait forever. Revisit if real usage data argues otherwise.

## Data flow

1. Maintainer pushes tag `v1.0.1`. Release workflow runs. On success: notarized DMG attached to GitHub Release; `appcast.xml` on Pages gains a new `<item>` with `version`, `enclosure url`, `sparkle:edSignature`, `length`, and release notes.
2. Running voxline checks the feed — either on its 24h timer or via the menu item. Sparkle GETs `SUFeedURL` over HTTPS.
3. Sparkle parses the appcast and compares each item's `sparkle:version` (the `CFBundleVersion`, stamped from `git rev-list --count`) against the running app's `CFBundleVersion`. Higher = update available.
4. Update presentation:
   - **Scheduled check** → gentle reminder (menu-bar badge + menu item), deferred during/after dictation per Layer 2.
   - **Manual check** → Sparkle's standard sheet with Install / Remind Later / Skip This Version; or "You're up-to-date" if nothing newer.
5. Download — Sparkle pulls the DMG into a sandboxed staging area.
6. **Signature verification.** Sparkle verifies the DMG's EdDSA signature against `SUPublicEDKey`. Mismatch → abort. Independently, Gatekeeper verifies Developer ID + notarization on first launch.
7. Install + relaunch. Sparkle's autoupdate helper mounts the DMG, copies `voxline.app` over the installed bundle, quits the old process, relaunches the new one. `UserDefaults` and Keychain entries survive the swap.

Two independent trust roots, intentionally: EdDSA proves the binary came from voxline's release pipeline; Developer ID + notarization proves Apple sees it as the binary it notarized. Either failing kills the install.

## Error handling

- **Offline / DNS failure on feed fetch.** Sparkle default: silent on scheduled checks, error dialog on manual. Wrapper logs `didAbortWithError` so failures show up in `tail-logs.sh`.
- **GitHub Pages 404 / malformed appcast.** Same path. Mitigation lives in CI: the release workflow validates the generated `appcast.xml` (well-formed XML; at least one `<item>` newer than the previous run) before publishing. A bad appcast never goes live.
- **EdDSA signature mismatch.** Hard fail. No fallback path. Log expected vs. actual key fingerprint so a botched release (or tampering attempt) is diagnosable.
- **Download interrupted mid-stream.** Sparkle handles resume / retry.
- **`/Applications` not writable.** Sparkle prompts for admin or falls back to in-place at the running bundle's actual path.
- **Update prompt collides with dictation.** Handled by Layer 2 (see User surface). Scheduled reminders are deferred until the 120s idle window opens; manual checks bypass deferral because they're user-initiated.
- **Notarization fails during a release.** CI job fails, no artifact published, no appcast update. Producer-side only.

## Testing

**Unit tests** (`voxlineTests/UpdateServiceTests.swift`):

- Dictation-gating: given a fake `DictationActivityMonitor`, assert `shouldAllowUpdateUI` returns `false` while active, `false` within the 120s idle window, `true` after. Boundary cases at 0s, 119s, 121s.
- Settings binding: toggling `automaticallyChecksForUpdates` writes through and reads back the expected `UserDefaults` value.
- `SPUUpdater` itself is not mocked — we trust the framework.

**Release-pipeline tests** (CI):

- Dry-run job on every PR touching `release.yml` or `Info.plist`: build → sign with a dummy cert → `generate_appcast` against a fixture DMG → `xmllint` validation + assert the result contains a well-formed `<enclosure>` with a non-empty `sparkle:edSignature`.
- Appcast schema sanity: `xmllint --noout appcast.xml`; assert `sparkle:version` is monotonically non-decreasing across items.

**Manual end-to-end** (before each release, until automated):

- Run a debug build with `SUFeedURL` pointed at a staging appcast. Confirm: scheduled check finds the update silently → menu badge appears → manual click → Sparkle UI → install → relaunch into the new build. Verify `defaults read com.voxline.app SUEnableAutomaticChecks` survives the swap.
- Tamper test: change one byte of `sparkle:edSignature` in the staging feed; confirm voxline refuses to install and logs the mismatch.
- Dictation-gating: with a pending update, start a dictation; confirm the gentle scheduled reminder does not surface until 120s after the dictation ends. Separately, trigger a *manual* check while dictating and confirm Sparkle's modal does appear (manual bypasses deferral).

Out of scope: testing Sparkle's own download/install/relaunch machinery.

## Open questions / future work

- **Homebrew Cask** as a complementary channel — separate, smaller spec.
- **Pre-release / beta channel** — deferred. Single channel for now.
- **Release-notes formatting** — start with the GitHub Release body verbatim. If that turns out to render poorly inside Sparkle's sheet, revisit with a separate, sanitized notes file.
- **EdDSA key rotation procedure** — losing the private key means baking a new public key into a future app version. Documenting the rotation runbook is a follow-up.
