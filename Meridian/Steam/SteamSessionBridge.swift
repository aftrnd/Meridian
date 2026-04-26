import Foundation
import Observation

private let log = MeridianLog(category: "SteamSessionBridge")

/// Bridges the macOS Steam client's session data into the Wine prefix.
///
/// Strategy (in priority order):
///
/// 1. **Credential auth tokens** — if the user authenticated via Meridian's
///    native credential auth flow, the resulting refresh token is stored here
///    and written to the prefix automatically during bootstrap. This is the
///    primary path for new users who authenticate through Meridian's onboarding.
///
/// 2. **Session file copy** — if Steam for Mac is installed, its
///    `loginusers.vdf`, `config/`, and `ssfn*` tokens are copied directly
///    into the Wine prefix's Steam directory. This achieves auto-login
///    without credentials.
///
/// 3. **No session available** — the user will need to sign into Steam once
///    inside the Wine Steam window. After that, Steam's own remember-me
///    tokens persist in the prefix.
@Observable
@MainActor
final class SteamSessionBridge {

    // MARK: - State

    /// Whether a macOS Steam install with usable session files was found.
    private(set) var hasMacSteamSession: Bool = false

    /// Populated from loginusers.vdf when macOS Steam is detected.
    private(set) var detectedAccountName: String?

    /// Ensures `AppSettings.steamCredentialAccountName` is populated.
    /// When the user re-authenticated but the new credential storage code wasn't active,
    /// the username lives in `loginusers.vdf` but not in AppSettings. This syncs it.
    func syncAccountNameIfNeeded(prefix: WinePrefix) {
        guard AppSettings.shared.steamCredentialAccountName.isEmpty else { return }
        let vdfPath = prefix.steamConfigDir.appending(path: "loginusers.vdf").path(percentEncoded: false)
        guard let content = try? String(contentsOfFile: vdfPath, encoding: .utf8) else { return }
        // Parse "AccountName" "username" from VDF
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().contains("\"accountname\"") {
                let parts = t.components(separatedBy: "\"").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if let name = parts.last, parts.count >= 2 {
                    AppSettings.shared.steamCredentialAccountName = name
                    log.info("[syncAccountName] synced username=\(name) from loginusers.vdf")
                    return
                }
            }
        }
    }

    // MARK: - Public API

    /// Prepares the Wine prefix with Steam session data before launching `steam.exe`.
    ///
    /// **April 26 2026 architecture:** the setup sheet uses Steam's HTTPS
    /// credential flow with `remember_login=1` / `persistence=1`, then writes the
    /// returned refresh token into Steam's DPAPI-backed `local.vdf`. This is the
    /// durable path. A plain `steam.exe -login` can report `persistence: 0`, which
    /// authenticates only the currently running process and leaves no token for
    /// the next launch.
    ///
    /// Strategies in priority order:
    ///   1. Persisted credential token — rewrite `loginusers.vdf` + `local.vdf`
    ///      on every launch so Steam has a durable silent-login token.
    ///   2. `steamSelfManagedSession` — legacy/fallback Steam-owned state. Only
    ///      considered valid if a `local.vdf` is actually present.
    ///   3. macOS Steam present — copy its `loginusers.vdf` + `ssfn*` so the
    ///       Wine Steam reuses the desktop client's session.
    ///   4. Nothing usable — the user signs in through the AuthView sheet.
    @discardableResult
    func prepare(prefix: WinePrefix, engine: WineEngine) async -> SessionStrategy {
        hasMacSteamSession = false
        detectedAccountName = nil

        let settings = AppSettings.shared

        // Strategy 1: persisted credential token from Meridian's HTTPS auth.
        if settings.hasSteamCredentials {
            let sid = settings.steamCredentialSteamID
            let name = settings.steamCredentialAccountName
            let refreshToken = settings.steamCredentialRefreshToken
            do {
                try prefix.writeLoginUsers(steamID: sid, accountName: name, personaName: name)
                try await prefix.writeSteamSessionLocalVdf(
                    engine: engine,
                    steamID: sid,
                    accountName: name,
                    refreshToken: refreshToken
                )
                prefix.backupSteamSession()
                settings.steamSelfManagedSession = false
                log.info("[prepare] strategy=credentialAuth — local.vdf refreshed from persisted token ✓")
                return .credentialAuth
            } catch {
                log.warning("[prepare] persisted credential token could not be written: \(error.localizedDescription)")
            }
        }

        // Strategy 2: legacy Steam self-managed session.
        if settings.steamSelfManagedSession {
            let localVdf = prefix.localAppDataSteamDir.appending(path: "local.vdf").path(percentEncoded: false)
            if !FileManager.default.fileExists(atPath: localVdf) {
                log.warning("[prepare] steamSelfManaged but local.vdf missing — attempting backup restore")
                prefix.restoreSteamSession()
            }
            let exists = FileManager.default.fileExists(atPath: localVdf)
            log.info("[prepare] strategy=steamSelfManaged — Steam owns local.vdf (exists=\(exists))")
            if exists {
                if !settings.steamCredentialSteamID.isEmpty {
                    let sid  = settings.steamCredentialSteamID
                    let name = settings.steamCredentialAccountName
                    try? prefix.writeLoginUsers(steamID: sid, accountName: name, personaName: name)
                }
                return .credentialAuth
            }

            log.warning("[prepare] steamSelfManaged session has no local.vdf after restore — clearing flag and falling back to session discovery")
            settings.steamSelfManagedSession = false
        }

        // Strategy 3: macOS Steam install detected — copy its session files.
        log.info("[prepare] checking for macOS Steam install")
        guard let steamDataDir = macSteamDataDirectory() else {
            log.info("[prepare] no macOS Steam install found at ~/Library/Application Support/Steam")
            return .none
        }
        log.info("[prepare] macOS Steam found at \(steamDataDir.path(percentEncoded: false))")

        if let accountName = parseAccountName(from: steamDataDir) {
            detectedAccountName = accountName
            log.info("[prepare] detected account: \(accountName)")
        } else {
            log.warning("[prepare] could not parse account name from loginusers.vdf")
        }

        let copied = prefix.copySessionFiles(from: steamDataDir)
        if copied {
            hasMacSteamSession = true
            log.info("[prepare] strategy=sessionFileCopy ✓")
            return .sessionFileCopy
        }

        log.warning("[prepare] session files exist but copy failed — strategy=none")
        return .none
    }

    // MARK: - Session strategy

    enum SessionStrategy {
        case credentialAuth
        case sessionFileCopy
        case none
    }

    // MARK: - Private helpers

    private func macSteamDataDirectory() -> URL? {
        let steamDir = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam")

        let loginUsersPath = steamDir.appending(path: "config/loginusers.vdf").path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: loginUsersPath)
        log.debug("[macSteamDir] \(loginUsersPath) exists=\(exists)")

        return exists ? steamDir : nil
    }

    private func parseAccountName(from steamDir: URL) -> String? {
        let path = steamDir.appending(path: "config/loginusers.vdf")
        guard let data = try? String(contentsOf: path, encoding: .utf8) else {
            log.warning("[parseAccountName] failed to read \(path.path(percentEncoded: false))")
            return nil
        }

        log.debug("[parseAccountName] loginusers.vdf is \(data.count) chars")

        var bestName: String?
        var currentName: String?
        var isMostRecent = false

        for line in data.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased().contains("\"accountname\"") {
                let parts = trimmed.components(separatedBy: "\"")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if parts.count >= 2 {
                    currentName = parts.last
                    if bestName == nil { bestName = currentName }
                }
            }
            if trimmed.lowercased().contains("\"mostrecent\"") && trimmed.contains("\"1\"") {
                isMostRecent = true
            }
            if trimmed == "}" {
                if isMostRecent, let name = currentName {
                    log.info("[parseAccountName] found MostRecent account: \(name)")
                    return name
                }
                currentName = nil
                isMostRecent = false
            }
        }

        if let name = bestName {
            log.info("[parseAccountName] using first account (no MostRecent): \(name)")
        } else {
            log.warning("[parseAccountName] no AccountName found in loginusers.vdf")
        }
        return bestName
    }
}
