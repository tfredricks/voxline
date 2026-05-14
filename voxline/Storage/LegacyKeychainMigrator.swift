import Foundation
import os

/// One-shot migration: lifts orphaned API keys out of the legacy file
/// keychain (where older builds with a broken DPK probe wrote them) into
/// the data-protection keychain. Runs at app launch; the completion flag
/// in UserDefaults prevents re-runs.
///
/// Safety properties:
///   1. If the modern keychain already has a value for an account, the
///      legacy value is discarded (not overwritten). The modern value is
///      assumed authoritative since it was written by a properly-signed
///      build.
///   2. The legacy entry is deleted unconditionally if it was present —
///      whether we copied it or not — so it can't shadow the modern entry
///      on a future build whose probe regresses.
///   3. If the modern write throws (e.g., DPK genuinely unreachable), the
///      completion flag is NOT set and the legacy entry is NOT deleted, so
///      a future run after signing is fixed can retry.
///
/// Delete this type (and `LegacyKeychain`) one release after this migration
/// has shipped and baked. By then every active install has either migrated
/// or had the legacy entries deleted by the reset script.
// TODO(post-2026-05-14-migration): delete this file (and the matching call
// site in voxlineApp.init()). See LegacyKeychain.swift for the rationale.
struct LegacyKeychainMigrator {

    static let completedKey = "voxline.keychain.legacyMigrated.v1"

    private static let log = Logger(subsystem: "com.voxline.app", category: "keychain-migration")

    let legacy: any KeychainStorage
    let modern: any KeychainStorage
    let defaults: UserDefaults

    init(
        legacy: any KeychainStorage = LegacyKeychain(),
        modern: any KeychainStorage = DataProtectionKeychain(),
        defaults: UserDefaults = .standard
    ) {
        self.legacy = legacy
        self.modern = modern
        self.defaults = defaults
    }

    func migrateIfNeeded() {
        guard !defaults.bool(forKey: Self.completedKey) else { return }

        var allOK = true
        var migratedCount = 0

        for account in KeychainAccount.all {
            let legacyValue: String?
            do {
                legacyValue = try legacy.string(forKey: account)
            } catch {
                Self.log.error("legacy read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                allOK = false
                continue
            }

            guard let legacyValue, !legacyValue.isEmpty else { continue }

            // Only adopt if modern has nothing — modern is authoritative.
            let modernHas: Bool
            do {
                let existing = try modern.string(forKey: account)
                modernHas = (existing?.isEmpty == false)
            } catch {
                Self.log.error("modern read failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                allOK = false
                continue
            }

            if !modernHas {
                do {
                    try modern.set(legacyValue, forKey: account)
                    migratedCount += 1
                    Self.log.info("migrated \(account, privacy: .public) from legacy to DPK")
                } catch {
                    Self.log.error("modern write failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public) — leaving legacy entry intact for retry")
                    allOK = false
                    continue
                }
            }

            // Delete legacy regardless of whether we adopted (stale shadow
            // entries should not survive). Only safe to do once we know
            // either (a) we copied it, or (b) modern already had a value.
            do {
                try legacy.delete(forKey: account)
            } catch {
                Self.log.error("legacy delete failed for \(account, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Non-fatal: the entry is shadowed by DPK now anyway.
            }
        }

        if allOK {
            defaults.set(true, forKey: Self.completedKey)
            Self.log.info("legacy keychain migration complete (migrated=\(migratedCount, privacy: .public))")
        } else {
            Self.log.error("legacy keychain migration partial — will retry next launch")
        }
    }
}
