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
///    without credentials. Same approach used by Whisky and CrossOver.
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
        log.info("[setPendingTokens] stored pending session for steamID=\(steamID) accountName=\(accountName)")
    }

    func clearPendingTokens() {
        pendingSteamID = ""
        pendingAccountName = ""
        pendingRefreshToken = ""
    }

    var hasPendingTokens: Bool { !pendingRefreshToken.isEmpty }

    // MARK: - Public API

    /// Prepares the Wine prefix with session data before launching Steam.
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
