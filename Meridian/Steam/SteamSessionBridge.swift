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

    /// Pending credential-auth tokens written by onboarding before prefix exists.
    /// Bootstrap writes these into the prefix during syncingSession and clears them.
    private(set) var pendingSteamID: String = ""
    private(set) var pendingAccountName: String = ""
    private(set) var pendingRefreshToken: String = ""

    /// Called from AuthView after successful credential auth, before bootstrap.
    func setPendingTokens(steamID: String, accountName: String, refreshToken: String) {
        pendingSteamID = steamID
        pendingAccountName = accountName
        pendingRefreshToken = refreshToken
        // Persist the credentials so subsequent sessions can re-write the ConnectCache
        // before each persistent Steam startup, ensuring the minimal config.vdf format
        // that Steam expects for ConnectCache auto-login is always present.
        AppSettings.shared.steamCredentialSteamID = steamID
        AppSettings.shared.steamCredentialAccountName = accountName
        AppSettings.shared.steamCredentialRefreshToken = refreshToken
        log.info("[setPendingTokens] stored pending session for steamID=\(steamID) accountName=\(accountName)")
    }

    func clearPendingTokens() {
        pendingSteamID = ""
        pendingAccountName = ""
        pendingRefreshToken = ""
    }

    var hasPendingTokens: Bool { !pendingRefreshToken.isEmpty }

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
    /// The current (April 23 2026+) authentication path uses a DPAPI-encrypted
    /// `local.vdf` written into `drive_c/users/crossover/AppData/Local/Steam/`.
    /// See `WinePrefix.writeSteamSessionLocalVdf` for the full mechanism; see
    /// `engine-research-findings.mdc` Pattern 6 for why `config.vdf`'s
    /// `ConnectCache` block stopped working with Steam client `1773426488`.
    ///
    /// The function:
    ///   1. Writes `loginusers.vdf` so Steam knows which user to auto-select.
    ///   2. Calls `meridian-dpapi.exe encrypt` (via `wine64`) on the JWT refresh
    ///      token, then writes the resulting encrypted blob to `local.vdf`.
    ///   3. Returns a `SessionStrategy` indicating which data source won.
    @discardableResult
    func prepare(prefix: WinePrefix, engine: WineEngine) async -> SessionStrategy {
        hasMacSteamSession = false
        detectedAccountName = nil

        // Priority 1: Pending credential-auth tokens from the just-finished sign-in.
        if hasPendingTokens {
            log.info("[prepare] strategy=credentialAuth — writing pending tokens to prefix")
            let sid    = pendingSteamID
            let name   = pendingAccountName
            let token  = pendingRefreshToken
            do {
                try prefix.writeLoginUsers(steamID: sid, accountName: name, personaName: name)
                try await prefix.writeSteamSessionLocalVdf(
                    engine: engine,
                    steamID: sid,
                    accountName: name,
                    refreshToken: token
                )
                clearPendingTokens()
                log.info("[prepare] strategy=credentialAuth ✓")
                return .credentialAuth
            } catch {
                log.error("[prepare] failed to write credential-auth session: \(error.localizedDescription)")
                clearPendingTokens()
            }
        }

        // Priority 1b: Persisted credentials from a prior session. Re-write
        // loginusers.vdf + local.vdf on every launch so the prefix is in a
        // known-good state regardless of what Steam itself did last time.
        let settings = AppSettings.shared
        if settings.hasSteamCredentials {
            log.info("[prepare] strategy=credentialAuthRefresh — re-writing loginusers.vdf + local.vdf from stored credentials")
            let sid   = settings.steamCredentialSteamID
            let name  = settings.steamCredentialAccountName
            let token = settings.steamCredentialRefreshToken
            do {
                try prefix.writeLoginUsers(steamID: sid, accountName: name, personaName: name)
                try await prefix.writeSteamSessionLocalVdf(
                    engine: engine,
                    steamID: sid,
                    accountName: name,
                    refreshToken: token
                )
                log.info("[prepare] strategy=credentialAuthRefresh ✓")
                return .credentialAuth
            } catch {
                log.warning("[prepare] could not re-write session files from stored credentials: \(error.localizedDescription)")
            }
        }

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
