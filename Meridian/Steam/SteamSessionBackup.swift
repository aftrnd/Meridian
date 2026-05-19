import Foundation

private let log = MeridianLog(category: "SteamSessionBackup")

/// Persists Steam's `local.vdf` auth token across prefix resets and cold starts.
///
/// Steam writes `local.vdf` after a successful `-login` auth handshake. This file
/// is the DPAPI-encrypted refresh token that lets `steam.exe -silent` auto-login on
/// subsequent cold starts. CrossOver inspection confirms this is the canonical
/// persistent auth mechanism — CrossOver has NO `ssfn*` files, only `local.vdf`.
///
/// ## Lifecycle
///  1. After `signIn()` succeeds, `snapshot()` copies `local.vdf` from the prefix
///     to `~/Library/Application Support/com.meridian.app/steam-session-backup/`.
///  2. On the next cold start, `restoreIfNeeded()` copies the backup back into the
///     prefix BEFORE steam.exe launches, so `-silent` auth succeeds from the token.
///  3. On sign-out, `clear()` removes the backup so the next user starts fresh.
///  4. `resetToEngineTemplate` calls `restoreIfNeeded()` implicitly (BootstrapManager
///     calls it every launch, which covers the post-reset case).
///
/// ## Why not ssfn?
///  Previous code chased `ssfn*` files. The April 2026 CrossOver bottle inspection
///  (May 2026) proves that wrong: CrossOver has zero ssfn files and stays persistently
///  logged in via `local.vdf` alone. Valve controls whether `persistence: 1` is granted
///  in the JWT it issues; `local.vdf` is what Steam actually uses to cache that token.
///
/// DO NOT DELETE THIS CLASS OR ITS CALL SITES. Deleting it caused months of wasted
/// work chasing ssfn (see engine-research-findings.mdc Pattern 7-11 and the May 2026
/// rewrite session notes).
enum SteamSessionBackup {

    // MARK: - Paths

    private static var backupDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/steam-session-backup")
    }

    static var localVdfBackupURL: URL {
        backupDir.appending(path: "local.vdf")
    }

    // MARK: - Public API

    /// Copy `local.vdf` from the prefix into the AppSupport backup directory.
    ///
    /// Called after a successful sign-in once Steam has had time to flush the file.
    /// Logs a clear diagnostic if the file does not exist — this is the GATE signal
    /// for Phase 3 (DPAPI helper exe) if it fires.
    static func snapshot(prefix: WinePrefix) {
        let fm = FileManager.default
        let source = prefix.localAppDataSteamDir.appending(path: "local.vdf")
        let sourcePath = source.path(percentEncoded: false)

        guard fm.fileExists(atPath: sourcePath) else {
            log.warning(
                "[snapshot] local.vdf NOT WRITTEN by Steam at \(sourcePath). " +
                "Steam returned persistence: 0 or has not yet flushed. " +
                "PHASE 3 MAY BE REQUIRED — check if DPAPI helper exe is needed."
            )
            return
        }

        // Guard against snapshotting an empty file.
        let size = (try? fm.attributesOfItem(atPath: sourcePath)[.size] as? Int) ?? 0
        guard size > 0 else {
            log.warning("[snapshot] local.vdf exists but is empty (\(sourcePath)) — skipping snapshot")
            return
        }

        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let dest = localVdfBackupURL
            // Atomic replace: write to a temp file, then rename.
            let tmp = backupDir.appending(path: "local.vdf.tmp")
            try fm.copyItem(at: source, to: tmp)
            _ = try? fm.replaceItem(at: dest, withItemAt: tmp, backupItemName: nil, options: .usingNewMetadataOnly, resultingItemURL: nil)
            try? fm.removeItem(at: tmp)
            log.info("[snapshot] local.vdf backed up ✓ (\(size) bytes)")
        } catch {
            log.error("[snapshot] failed to back up local.vdf: \(error.localizedDescription)")
        }
    }

    /// Restore `local.vdf` from the AppSupport backup into the prefix if it is absent.
    ///
    /// Called by BootstrapManager BEFORE steam.exe is launched so that `-silent` can
    /// find the token. No-op if the prefix already has local.vdf or no backup exists.
    static func restoreIfNeeded(prefix: WinePrefix) {
        let fm = FileManager.default
        let dest = prefix.localAppDataSteamDir.appending(path: "local.vdf")
        let destPath = dest.path(percentEncoded: false)

        // Already present — nothing to do.
        if fm.fileExists(atPath: destPath) {
            log.debug("[restoreIfNeeded] local.vdf already in prefix — no restore needed")
            return
        }

        let backup = localVdfBackupURL
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else {
            log.debug("[restoreIfNeeded] no backup to restore — first sign-in or cleared")
            return
        }

        do {
            try fm.createDirectory(
                at: prefix.localAppDataSteamDir,
                withIntermediateDirectories: true
            )
            try fm.copyItem(at: backup, to: dest)
            let size = (try? fm.attributesOfItem(atPath: destPath)[.size] as? Int) ?? 0
            log.info("[restoreIfNeeded] restored local.vdf to prefix (\(size) bytes)")
        } catch {
            log.error("[restoreIfNeeded] failed to restore local.vdf: \(error.localizedDescription)")
        }
    }

    /// Delete the backup. Called on sign-out so the next account starts clean.
    static func clear() {
        let fm = FileManager.default
        let backup = localVdfBackupURL
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else { return }
        do {
            try fm.removeItem(at: backup)
            log.info("[clear] session backup cleared")
        } catch {
            log.warning("[clear] failed to clear backup: \(error.localizedDescription)")
        }
    }
}
