import AuthenticationServices
import Security
import Observation
import os.log

private let log = MeridianLog(category: "SteamAuth")

/// Handles Steam OpenID authentication via ASWebAuthenticationSession.
///
/// Sign-in flow:
/// 1. Open Steam OpenID in a browser overlay via ASWebAuthenticationSession.
/// 2. Steam redirects to meridian://auth/callback?openid.claimed_id=...
/// 3. Extract the verified 64-bit SteamID from the claimed_id URL.
/// 4. Store SteamID securely in Keychain.
/// 5. Fetch display name / avatar directly from Steam Web API using the user's API key.
///
/// Wine prefix sign-in:
/// SteamSessionBridge copies macOS Steam session files into the Wine prefix so the
/// Windows Steam client auto-logs in without any additional prompt. If no macOS Steam
/// session is found, the user signs into Steam once inside the Wine window.
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

    // MARK: - Private — auth session lifetime management

    /// Held strongly for the lifetime of an active ASWebAuthenticationSession.
    /// Without this, ARC can release the session object as soon as the
    /// `withCheckedThrowingContinuation` closure returns, causing the sheet to
    /// dismiss itself and the completion handler to fire with canceledLogin.
    private var activeAuthSession: ASWebAuthenticationSession?

    /// Held strongly so the loopback server socket stays open until auth completes.
    private var activeAuthServer: SteamLocalAuthServer?

    /// The window captured on the main actor before the auth session starts.
    ///
    /// `ASWebAuthenticationPresentationContextProviding` is an Objective-C protocol.
    /// Its method is invoked via ObjC messaging — Swift's @MainActor dispatch is
    /// bypassed. On macOS 26, NSApp.keyWindow has dispatch_assert_queue(main) so
    /// it must not be accessed from a background thread. We capture the window
    /// up-front on the main actor and return it from the nonisolated delegate method.
    @ObservationIgnored
    nonisolated(unsafe) private var capturedPresentationWindow: ASPresentationAnchor?

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

    /// Launches the Steam OpenID browser overlay and waits for the callback.
    ///
    /// Steam's OpenID endpoint rejects custom URI schemes (e.g. meridian://) as
    /// `return_to` values — it only accepts http:// or https://. We work around
    /// this without a backend by running a temporary localhost HTTP server that
    /// receives Steam's redirect, extracts the SteamID, and immediately issues a
    /// 302 to meridian://auth/callback which ASWebAuthenticationSession intercepts.
    ///
    /// This is the RFC 8252 §7.3 "loopback interface" pattern used by VS Code,
    /// Spotify, and other native desktop apps for OAuth/OpenID flows.
    func signIn() async {
        guard !isAuthenticating else {
            log.warning("[signIn] already authenticating — ignoring")
            return
        }
        log.info("[signIn] starting Steam OpenID sign-in")
        isAuthenticating = true
        authError = nil
        defer {
            isAuthenticating = false
            activeAuthSession = nil
            activeAuthServer?.stop()
            activeAuthServer = nil
            capturedPresentationWindow = nil
        }

        // Capture (or create) the presentation window NOW, while we are guaranteed to
        // be on the main actor. ASWebAuthenticationPresentationContextProviding is an
        // ObjC protocol — its delegate method is invoked via ObjC messaging which
        // bypasses Swift's @MainActor isolation. On macOS 26+, both NSApp.keyWindow
        // AND NSWindow() enforce dispatch_assert_queue(main_queue) and will crash if
        // touched from any other thread.
        //
        // We store a guaranteed-non-nil window here. The delegate method returns it
        // directly with no AppKit calls of its own, so it is safe to call from any
        // thread (including the Safari XPC queue that ASWebAuthenticationSession uses).
        capturedPresentationWindow = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApplication.shared.windows.first
            ?? NSWindow()   // last resort — must happen on main actor (we are here)

        let server = SteamLocalAuthServer()
        activeAuthServer = server

        do {
            // 1. Bind the loopback socket and get the return_to URL.
            //    The server's only job is to accept one HTTP GET from Steam's
            //    redirect and reply with 302 → meridian://. It has no continuation
            //    of its own — we drive everything from ASWebAuthenticationSession.
            let returnToURL = try server.start()

            // 2. Start listening in the background. Fire-and-forget: no Task to
            //    race with, no CheckedContinuation to accidentally double-resume.
            server.startListening()

            // 3. Build the Steam OpenID URL pointing at our loopback return_to.
            guard let authURL = buildOpenIDURL(returnTo: returnToURL.absoluteString) else {
                authError = "Failed to construct Steam authentication URL."
                return
            }

            // 4. Open the Steam sign-in sheet. The completion handler is created
            //    inside `makeWebAuthSession` — a nonisolated free function — so Swift 6
            //    cannot infer @MainActor on the closure. Safe to call from XPC queue.
            let callbackURL: URL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                let session = makeWebAuthSession(url: authURL, cont: cont)
                session.prefersEphemeralWebBrowserSession = false
                session.presentationContextProvider = self
                session.start()
                // Store strongly — without this, ARC releases the session as soon
                // as this closure returns, causing an immediate canceledLogin.
                self.activeAuthSession = session
            }

            try await handleCallback(callbackURL)

        } catch ASWebAuthenticationSessionError.canceledLogin {
            log.info("[signIn] user cancelled sign-in")
        } catch {
            log.error("[signIn] failed: \(error.localizedDescription)")
            authError = error.localizedDescription
        }
    }

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
        log.info("[signOut] Keychain cleared, account data reset")
    }

    // MARK: - Private helpers

    private func buildOpenIDURL(returnTo: String) -> URL? {
        // Steam requires return_to to use http:// or https://.
        // We pass our localhost broker URL (http://127.0.0.1:{port}/openid/callback).
        // The realm must be a prefix of return_to — using the loopback origin.
        guard
            let returnToURL = URL(string: returnTo),
            let host = returnToURL.host,
            let port = returnToURL.port
        else { return nil }

        let realm = "http://\(host):\(port)/"

        var components = URLComponents(string: "https://steamcommunity.com/openid/login")
        components?.queryItems = [
            .init(name: "openid.ns",         value: "http://specs.openid.net/auth/2.0"),
            .init(name: "openid.mode",        value: "checkid_setup"),
            .init(name: "openid.return_to",   value: returnTo),
            .init(name: "openid.realm",       value: realm),
            .init(name: "openid.identity",    value: "http://specs.openid.net/auth/2.0/identifier_select"),
            .init(name: "openid.claimed_id",  value: "http://specs.openid.net/auth/2.0/identifier_select"),
        ]
        return components?.url
    }

    private func handleCallback(_ url: URL) async throws {
        log.info("[handleCallback] url=\(url.absoluteString)")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        guard
            let id = components?.queryItems?.first(where: { $0.name == "steamid" })?.value,
            id.count >= 17,
            id.allSatisfy(\.isNumber)
        else {
            log.error("[handleCallback] invalid callback — no valid steamid in URL")
            throw AuthError.invalidCallback
        }

        let extractedID = id
        log.info("[handleCallback] extracted steamID=\(extractedID)")

        steamID = extractedID
        saveSecret(extractedID, key: KeychainKey.steamID)

        await refreshProfile(steamID: extractedID)

        isAuthenticated = true
        log.info("[handleCallback] sign-in complete ✓")
    }

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

// MARK: - Nonisolated session factory

/// Creates the ASWebAuthenticationSession in a context that has NO actor isolation.
///
/// Root cause of the crash (Swift 6.2 / macOS 26):
/// `withCheckedThrowingContinuation(isolation: #isolation)` captures the calling
/// actor's executor inside the `CheckedContinuation` value. Any closure that captures
/// a `CheckedContinuation` created on `@MainActor` is therefore inferred by the Swift 6
/// compiler as `@MainActor`-isolated — even with an explicit capture list. The runtime
/// inserts `_swift_task_checkIsolatedSwift` at the closure entry, which calls
/// `dispatch_assert_queue(main_queue)`. When `ASWebAuthenticationSession` fires its
/// completion handler on the Safari XPC queue (`com.apple.SafariLaunchAgent`), that
/// assertion fails and the app crashes.
///
/// By constructing the session (and its completion handler closure) inside a
/// `nonisolated` free function, the closure is in a genuinely non-actor scope.
/// Swift 6 cannot infer `@MainActor` on it regardless of what `cont` carries internally.
/// The XPC queue can call the handler freely, and `cont.resume` re-schedules
/// `signIn()` back onto `@MainActor` automatically — no assertion, no crash.
private func makeWebAuthSession(
    url: URL,
    cont: CheckedContinuation<URL, any Error>
) -> ASWebAuthenticationSession {
    // This function is nonisolated. The closure below therefore has no actor context.
    ASWebAuthenticationSession(
        url: url,
        callback: .customScheme("meridian")
    ) { (callbackURL: URL?, error: (any Error)?) in
        if let error {
            cont.resume(throwing: error)
        } else if let callbackURL {
            cont.resume(returning: callbackURL)
        } else {
            cont.resume(throwing: SteamAuthServiceError.noCallback)
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SteamAuthService: ASWebAuthenticationPresentationContextProviding {
    /// This method is called via Objective-C messaging, bypassing Swift's @MainActor
    /// dispatch. NSApp.keyWindow and NSWindow() both enforce
    /// dispatch_assert_queue(main_queue) on macOS 26+ and will crash if called from
    /// a background thread (e.g. the Safari XPC queue ASWebAuthenticationSession uses).
    /// We return the window that was captured — or created — on the main actor in
    /// signIn() before the session was started. It is always non-nil at call time.
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // capturedPresentationWindow is always set before session.start() is called.
        // Force-unwrap is intentional: if it were nil here something is deeply wrong
        // with call ordering, and a clear crash is better than a silent wrong window.
        capturedPresentationWindow!
    }
}
