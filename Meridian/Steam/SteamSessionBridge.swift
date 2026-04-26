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
    /// **April 25 2026 architecture:** Steam owns its own auth state inside the
    /// bottle. After `SteamExeSignIn` drives `steam.exe -login`, Steam writes
    /// `loginusers.vdf` + a DPAPI-encrypted `local.vdf` whose JWT carries the
    /// Wine bottle's `machine_id` HMAC binding. CMsgClientLogon at next launch
    /// echoes the same `machine_id`, so Valve's CM accepts the token. Meridian
    /// MUST NOT touch that file — earlier versions injected an externally-minted
    /// JWT into `local.vdf` that lacked the `machine_id` claim, and Valve
    /// rejected the resulting CM logon with `Invalid Password`.
    ///
    /// Strategies in priority order:
    ///   1. `steamSelfManagedSession` — the user has signed in via
    ///       `SteamExeSignIn`; Steam owns its on-disk state. We just refresh
    ///       `loginusers.vdf` to pin the auto-login user and otherwise stay out
    ///       of Steam's way.
    ///   2. macOS Steam present — copy its `loginusers.vdf` + `ssfn*` so the
    ///       Wine Steam reuses the desktop client's session.
    ///   3. Nothing usable — the user signs in through the AuthView sheet.
    @discardableResult
    func prepare(prefix: WinePrefix, engine: WineEngine) async -> SessionStrategy {
        hasMacSteamSession = false
        detectedAccountName = nil

        let settings = AppSettings.shared

        // Strategy 1: Steam self-managed session (post-April-25-2026).
        if settings.steamSelfManagedSession {
            let localVdf = prefix.localAppDataSteamDir.appending(path: "local.vdf").path(percentEncoded: false)
            let exists = FileManager.default.fileExists(atPath: localVdf)
            log.info("[prepare] strategy=steamSelfManaged — Steam owns local.vdf (exists=\(exists))")
            if !settings.steamCredentialSteamID.isEmpty {
                let sid  = settings.steamCredentialSteamID
                let name = settings.steamCredentialAccountName
                try? prefix.writeLoginUsers(steamID: sid, accountName: name, personaName: name)
            }
            return .credentialAuth
        }

        // Strategy 2: macOS Steam install detected — copy its session files.
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
