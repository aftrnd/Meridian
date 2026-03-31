import Foundation
import Observation
import os.log

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

    /// Prepares the Wine prefix with session data before launching Steam.
    ///
    /// On every call, if credential-auth tokens were persisted from a prior session,
    /// they are re-written to the prefix as a fresh minimal config.vdf. This ensures
    /// Steam always starts with a clean ConnectCache entry rather than the complex
    /// config.vdf that Steam writes after its first authenticated session.
    @discardableResult
    func prepare(prefix: WinePrefix) async -> SessionStrategy {
        hasMacSteamSession = false
        detectedAccountName = nil

        // Priority 1: Use pending credential-auth tokens from onboarding
        if hasPendingTokens {
            log.info("[prepare] strategy=credentialAuth — writing pending tokens to prefix")
            do {
                try prefix.writeLoginUsers(
                    steamID: pendingSteamID,
                    accountName: pendingAccountName,
                    personaName: pendingAccountName
                )
                try prefix.writeConnectCache(
                    steamID: pendingSteamID,
                    refreshToken: pendingRefreshToken,
                    accountName: pendingAccountName
                )
                clearPendingTokens()
                log.info("[prepare] strategy=credentialAuth ✓")
                return .credentialAuth
            } catch {
                log.error("[prepare] failed to write credential-auth tokens: \(error.localizedDescription)")
                clearPendingTokens()
            }
        }

        // Priority 1b: Re-write ConnectCache from persisted credentials.
        // When the user authenticated in a prior session, the credentials were saved
        // to AppSettings. Re-writing them here ensures the minimal config.vdf format
        // that Steam's ConnectCache mechanism requires is always present — Steam's own
        // flushed config.vdf adds extra keys that can prevent reliable auto-login.
        let settings = AppSettings.shared
        if settings.hasSteamCredentials {
            log.info("[prepare] strategy=credentialAuthRefresh — re-writing ConnectCache from stored credentials")
            do {
                try prefix.writeConnectCache(
                    steamID: settings.steamCredentialSteamID,
                    refreshToken: settings.steamCredentialRefreshToken,
                    accountName: settings.steamCredentialAccountName
                )
                log.info("[prepare] strategy=credentialAuthRefresh ✓")
                return .credentialAuth
            } catch {
                log.warning("[prepare] could not re-write ConnectCache from stored credentials: \(error.localizedDescription)")
            }
        }

        log.info("[prepare] checking for macOS Steam install")

        guard let steamDataDir = macSteamDataDirectory() else {
            log.info("[prepare] no macOS Steam install found at ~/Library/Application Support/Steam")
            // Detect and clear a stale web-audience ConnectCache token. If the prefix has a
            // ConnectCache entry but no credentials are stored in AppSettings, the token was
            // obtained with the old platform_type=2 (WebBrowser) code, producing aud:["web"].
            // The Steam desktop client requires aud:["client"] (platform_type=1) for
            // ConnectCache auto-login — it silently discards web-audience tokens and stays
            // [Logged Off, 0, 0], preventing all downloads. Wipe the stale entry and reset
            // loginusers.vdf so hasSteamLoginSession() returns false, triggering re-auth.
            clearStaleConnectCache(prefix: prefix)
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

    // MARK: - Stale token cleanup

    /// Detects and wipes a ConnectCache entry written by the old platform_type=2 code.
    ///
    /// The old `BeginAuthSessionViaCredentials` call used `platform_type: "2"` (WebBrowser),
    /// producing a JWT with `aud: ["web", "renew", "derive"]`. The Steam desktop client
    /// requires `aud: ["client"]` (platform_type: "1", SteamClient) for ConnectCache
    /// auto-login. It silently discards web-audience tokens, causing Steam to stay at
    /// `[Logged Off, 0, 0]` every session.
    ///
    /// Detection: if no credentials are stored in AppSettings (they are only populated by
    /// the fixed code that uses platform_type=1) AND the prefix has a loginusers.vdf
    /// (leftover from the old session), the old token had the wrong audience. This method:
    ///   1. Overwrites config.vdf with an empty InstallConfigStore (no ConnectCache).
    ///   2. Deletes loginusers.vdf entirely so hasSteamLoginSession() returns false,
    ///      which causes ContentView to present the re-auth sheet.
    private func clearStaleConnectCache(prefix: WinePrefix) {
        // Only run this migration ONCE. After the first re-auth with platform_type=1,
        // we set this flag so subsequent launches don't wipe the session every time.
        guard !UserDefaults.standard.bool(forKey: "didMigratePlatformType1") else { return }

        let fm = FileManager.default
        let loginPath = prefix.steamConfigDir.appending(path: "loginusers.vdf").path(percentEncoded: false)
        guard fm.fileExists(atPath: loginPath) else {
            // No loginusers.vdf — nothing to migrate, mark as done
            UserDefaults.standard.set(true, forKey: "didMigratePlatformType1")
            return
        }

        log.warning("[clearStaleConnectCache] stale session detected (no stored credentials) — clearing to force re-auth with correct platform_type=1 (SteamClient)")

        let configPath = prefix.steamConfigDir.appending(path: "config.vdf").path(percentEncoded: false)
        let emptyConfig = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t}
        \t\t}
        \t}
        }
        """
        try? emptyConfig.write(toFile: configPath, atomically: true, encoding: .utf8)
        log.info("[clearStaleConnectCache] config.vdf cleared ✓")

        try? fm.removeItem(atPath: loginPath)
        log.info("[clearStaleConnectCache] loginusers.vdf deleted ✓")

        UserDefaults.standard.set(true, forKey: "didMigratePlatformType1")
        log.info("[clearStaleConnectCache] migration flag set — will not run again")
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
