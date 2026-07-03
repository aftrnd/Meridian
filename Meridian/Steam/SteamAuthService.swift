import Foundation
import Security
import Observation

private let log = MeridianLog(category: "SteamAuth")

/// Holds the user's Steam identity and Web API key.
///
/// Sign-in is driven by `SteamExeSignIn` through `AuthView`. On success,
/// `setAuthenticatedFromCredentialFlow` captures the SteamID + account name.
/// Steam writes its own `ssfn*` device-trust token during sign-in; subsequent
/// cold starts use `steam.exe -silent` which auto-logs in via the ssfn — no
/// password, no 2FA push.
@Observable
@MainActor
final class SteamAuthService: NSObject {

    // MARK: - Published state

    private(set) var isAuthenticated: Bool = false
    private(set) var steamID: String = ""
    private(set) var displayName: String = ""
    private(set) var avatarURL: URL?
    private(set) var authError: String?
    var isAuthenticating: Bool = false

    /// True when the user has signed in but their API key is not yet stored.
    /// Drives the post-sign-in API key prompt in the UI.
    var needsAPIKey: Bool {
        isAuthenticated && !apiKeyPromptDismissed && (loadSecret(key: KeychainKey.apiKey) ?? "").isEmpty
    }

    /// Set to true when the user explicitly skips the API key prompt.
    /// Stored as an @Observable tracked property so SwiftUI bindings on `needsAPIKey`
    /// update immediately when this changes. Persisted to UserDefaults via didSet.
    var apiKeyPromptDismissed: Bool = UserDefaults.standard.bool(forKey: "apiKeyPromptDismissed") {
        didSet { UserDefaults.standard.set(apiKeyPromptDismissed, forKey: "apiKeyPromptDismissed") }
    }

    /// Dismisses the API key prompt without saving a key.
    func dismissAPIKeyPrompt() {
        apiKeyPromptDismissed = true
    }

    // MARK: - Keychain keys

    private enum KeychainKey {
        static let steamID        = "meridian.steam.steamid"
        static let apiKey         = "meridian.steam.apikey"
        static let steamPassword  = "meridian.steam.password"
    }

    /// Stores the Steam password in Keychain for SteamCMD re-authentication.
    /// SteamCMD has its own credential cache that gets wiped on prefix reset.
    /// When that happens, we need the password to re-authenticate automatically.
    func saveSteamPassword(_ password: String) {
        saveSecret(password, key: KeychainKey.steamPassword)
    }

    /// Retrieves the stored Steam password for SteamCMD auto-authentication.
    func loadSteamPassword() -> String? {
        loadSecret(key: KeychainKey.steamPassword)
    }

    // MARK: - Computed credential accessors

    /// The user's Steam Web API key, stored in Keychain.
    var apiKey: String {
        get { loadSecret(key: KeychainKey.apiKey) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                deleteSecret(key: KeychainKey.apiKey)
            } else {
                saveSecret(trimmed, key: KeychainKey.apiKey)
            }
        }
    }

    // MARK: - Init

    override init() {
        super.init()
        restoreSession()

        // Route install/launch-time token-expiry back to re-auth. The
        // install path posts this when DepotDownloader reports exit 3
        // (REFRESH_TOKEN_INVALID) — a genuinely dead token, distinct from
        // the anti-abuse AccessDenied case which is handled silently in
        // `renewSessionIfNeeded`.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSessionExpiredNotification),
            name: .meridianSteamSessionExpired,
            object: nil
        )
    }

    @objc private func handleSessionExpiredNotification() {
        Task { @MainActor in self.markSessionExpired() }
    }

    // MARK: - Public API

    /// Called after successful credential auth in onboarding (before bootstrap/prefix exists).
    /// Stores the SteamID in Keychain and marks the session as authenticated so the
    /// app can proceed to the API key step and then bootstrap.
    /// The displayName defaults to accountName until the profile is fetched post-API-key-entry.
    func setAuthenticatedFromCredentialFlow(steamID: String, accountName: String) {
        log.info("[setAuthenticated] credential auth: steamID=\(steamID) accountName=\(accountName)")
        self.steamID = steamID
        self.displayName = accountName
        saveSecret(steamID, key: KeychainKey.steamID)
        isAuthenticated = true
        log.info("[setAuthenticated] session established ✓")
    }

    func signOut() {
        log.info("[signOut] signing out steamID=\(self.steamID)")
        isAuthenticated = false
        steamID = ""
        displayName = ""
        avatarURL = nil
        deleteSecret(key: KeychainKey.steamID)
        deleteSecret(key: KeychainKey.apiKey)
        deleteSecret(key: KeychainKey.steamPassword)
        apiKeyPromptDismissed = false
        AppSettings.shared.clearAccountData()
        // Clear the local.vdf session backup so the next account starts clean.
        // Also delete the live local.vdf inside the prefix so Steam doesn't try
        // to auto-login with this account's now-orphaned token.
        SteamSessionBackup.clear()
        WinePrefix.clearSteamSessionBackup()   // cleans legacy backup dirs
        let liveLocalVdf = WinePrefix.defaultPrefix.localAppDataSteamDir.appending(path: "local.vdf")
        try? FileManager.default.removeItem(at: liveLocalVdf)
        log.info("[signOut] Keychain cleared, account data + session backup reset")
    }

    // MARK: - Private helpers

    /// Fetches the player profile and updates displayName / avatarURL.
    /// Safe to call any time; silently does nothing if the API key is absent.
    func refreshProfile(steamID: String) async {
        let key = apiKey
        guard !key.isEmpty else {
            log.debug("[refreshProfile] no API key — skipping profile fetch")
            displayName = displayName.isEmpty ? "Steam User" : displayName
            return
        }
        log.info("[refreshProfile] fetching profile for steamID=\(steamID)")
        do {
            let summary = try await SteamAPIService.shared.fetchPlayerSummary(
                steamID: steamID, apiKey: key
            )
            displayName = summary.personaName
            avatarURL   = URL(string: summary.avatarFull)
            log.info("[refreshProfile] got displayName=\(summary.personaName)")
        } catch {
            log.error("[refreshProfile] failed: \(error.localizedDescription)")
        }
    }

    private func restoreSession() {
        guard let savedID = loadSecret(key: KeychainKey.steamID), !savedID.isEmpty else {
            log.info("[restoreSession] no saved session")
            return
        }
        // A Keychain identity WITHOUT a stored refresh token is a broken
        // half-session (Keychain survived but UserDefaults were reset, or a
        // partial sign-out). Installs and DRM launches require the token, so
        // restoring this as "authenticated" produces an app that looks signed
        // in but can't do anything token-gated. Fail fast: route to the
        // sign-in sheet instead (API key + password are preserved).
        guard !AppSettings.shared.steamCredentialRefreshToken.isEmpty else {
            log.warning("[restoreSession] steamID present but no refresh token — stale half-session, prompting sign-in")
            markSessionExpired()
            return
        }

        log.info("[restoreSession] restored steamID=\(savedID)")
        steamID = savedID
        isAuthenticated = true

        // If there is no API key in the keychain, the API key prompt was never
        // legitimately completed — reset the dismissed flag so the user is prompted
        // on the next launch. This prevents apiKeyPromptDismissed=true (persisted
        // in UserDefaults from a partial onboarding run) from permanently hiding
        // the API key step even when no key is actually stored.
        if (loadSecret(key: KeychainKey.apiKey) ?? "").isEmpty {
            apiKeyPromptDismissed = false
        }

        Task {
            await refreshProfile(steamID: savedID)
        }

        // Proactively renew the OAuth refresh token on every cold start so it
        // never silently ages out mid-session (Pattern 23 / handoff v6). Pure
        // HTTPS; runs off the main actor.
        Task { await renewSessionIfNeeded() }
    }

    /// Validates (and rotates, if Valve returns a new one) the stored OAuth
    /// refresh token. Called at startup from `restoreSession`.
    ///
    /// - `.renewed`      → persist the rotated token.
    /// - `.valid`        → nothing to do.
    /// - `.networkError` → keep the token, retry next launch (offline-safe).
    /// - `.accessDenied` → KEEP the token, do NOT force re-auth. Valve's
    ///   anti-abuse lockout (EResult 15) rejects the *exchange* while the
    ///   library + installed games keep working; re-minting only feeds the
    ///   lockout (Pattern 23). Staying signed in is the harm-reduction path.
    /// - `.invalid`      → KEEP the token, do NOT force re-auth from this
    ///   startup probe. `GenerateAccessTokenForApp` returns an empty
    ///   `{"response":{}}` body (no access_token, no rotation) with a FLAPPING
    ///   eresult (15 vs 63 on back-to-back calls) for some accounts, even for a
    ///   freshly-minted, structurally-valid token (CLI-verified July 2 2026 on
    ///   a token QR-minted minutes earlier). An empty body is Valve declining
    ///   to mint a new access token, NOT proof the refresh token is dead —
    ///   so treating it as dead here logs the user out on every launch despite
    ///   a perfectly good session. The AUTHORITATIVE dead-token signal is a
    ///   token-gated operation actually failing: DepotDownloader exit 3
    ///   (`.refreshTokenInvalid`) → `.meridianSteamSessionExpired` →
    ///   `markSessionExpired()` (observed in `init`). The startup probe is
    ///   advisory only: it rotates the token when Valve offers a new one and
    ///   otherwise leaves the session intact. Matches the ContentView gate
    ///   comment ("if the refresh_token is genuinely expired, the
    ///   install/launch path surfaces that").
    func renewSessionIfNeeded() async {
        let settings = AppSettings.shared
        let sid   = settings.steamCredentialSteamID
        let token = settings.steamCredentialRefreshToken
        guard !sid.isEmpty, !token.isEmpty else {
            log.debug("[renewSession] no stored token — skipping")
            return
        }

        let outcome = await SteamCredentialAuth.renewRefreshToken(steamID: sid, refreshToken: token)
        switch outcome {
        case .renewed(let newToken):
            settings.steamCredentialRefreshToken = newToken
            log.info("[renewSession] persisted rotated refresh token ✓")
        case .valid:
            log.info("[renewSession] stored token still valid ✓")
        case .networkError:
            log.info("[renewSession] transient network error — keeping token, will retry next launch")
        case .accessDenied:
            // EResult 15. Keep the token; do NOT sign out. Re-minting feeds the
            // anti-abuse lockout and 2FAs the user every launch (Pattern 23).
            log.warning("[renewSession] AccessDenied (EResult 15) — keeping token, staying signed in (anti-abuse; not code-fixable)")
        case .invalid:
            // Empty/ambiguous exchange response — NOT proof the token is dead.
            // Keep the session; the install/launch path (DepotDownloader exit 3)
            // is the authoritative dead-token signal and will route to re-auth
            // if the token actually fails in use. Signing out here logged users
            // out on every launch with a perfectly valid token (July 2 2026).
            log.info("[renewSession] renewal exchange returned no token — keeping session (point-of-use will detect a genuinely dead token)")
        }
    }

    /// Drops the authenticated state (→ sign-in sheet) and clears the dead
    /// refresh token + live `local.vdf`, but PRESERVES the Web API key and
    /// saved password (unlike `signOut()`) so the library keeps working and
    /// re-auth is one tap. Used when a token is genuinely dead (Pattern 23).
    func markSessionExpired() {
        log.warning("[markSessionExpired] clearing dead session — preserving API key + password for one-tap re-auth")
        isAuthenticated = false
        steamID = ""
        displayName = ""
        avatarURL = nil
        deleteSecret(key: KeychainKey.steamID)
        AppSettings.shared.steamCredentialRefreshToken = ""
        // Drop the live local.vdf so Steam doesn't try to auto-login with the
        // now-orphaned token. Backups / API key / password remain intact.
        let liveLocalVdf = WinePrefix.defaultPrefix.localAppDataSteamDir.appending(path: "local.vdf")
        try? FileManager.default.removeItem(at: liveLocalVdf)
    }

    // MARK: - Keychain helpers

    private func saveSecret(_ value: String, key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.meridian.app",
            kSecAttrAccount as String: key,
            kSecValueData as String:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadSecret(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.meridian.app",
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteSecret(key: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.meridian.app",
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Error types

    // Defined as a typealias so call sites stay the same.
    // The actual type lives outside the @MainActor class so it is accessible
    // from nonisolated contexts (e.g. the session factory below).
    typealias AuthError = SteamAuthServiceError
}

// MARK: - Error type (nonisolated — must be outside @MainActor class)

/// Auth errors for SteamAuthService. Declared at file scope so they can be
/// referenced from nonisolated helper functions without triggering actor checks.
enum SteamAuthServiceError: LocalizedError {
    case noCallback
    case invalidCallback

    var errorDescription: String? {
        switch self {
        case .noCallback:      return "Steam did not return an authentication callback."
        case .invalidCallback: return "Steam returned an unrecognised callback URL."
        }
    }
}

