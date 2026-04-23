import Foundation
import Security
import Observation

private let log = MeridianLog(category: "SteamAuth")

/// Holds the user's Steam identity and Web API key.
///
/// Sign-in is driven by `SteamCredentialAuth` through `AuthView`. On success,
/// `setAuthenticatedFromCredentialFlow` captures the SteamID + account name and
/// `SteamSessionBridge` writes the resulting JWT into the Wine prefix's
/// `config/config.vdf` ConnectCache so `steam.exe -silent` can auto-login.
///
/// (April 22 2026: see `engine-research-findings.mdc` Pattern 6 for the
/// currently-known limitation on externally-written ConnectCache JWTs in
/// Steam 1773426488+.)
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
        // Wipe the DPAPI local.vdf backup so the next user doesn't inherit the
        // prior account's auto-login token.
        WinePrefix.clearSteamSessionBackup()
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

