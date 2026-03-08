import AuthenticationServices
import Security
import Observation

/// Handles Steam OpenID authentication via ASWebAuthenticationSession.
///
/// Sign-in flow:
/// 1. Open Steam OpenID in a browser overlay via ASWebAuthenticationSession.
/// 2. Steam redirects to meridian://auth/callback?openid.claimed_id=...
/// 3. Extract the verified 64-bit SteamID from the claimed_id URL.
/// 4. Store SteamID securely in Keychain.
/// 5. Fetch display name / avatar directly from Steam Web API using the user's API key.
///
/// VM sign-in:
/// SteamSessionBridge detects macOS Steam session files and shares them into the VM
/// via virtio-fs so the Linux Steam client can sign in without any additional prompt.
/// If no macOS Steam is present, a Steam credential pair (username/password) stored
/// in Keychain is injected at launch time as a fallback.
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
    /// Persisted in UserDefaults so it survives across launches.
    var apiKeyPromptDismissed: Bool {
        get { UserDefaults.standard.bool(forKey: "apiKeyPromptDismissed") }
        set { UserDefaults.standard.set(newValue, forKey: "apiKeyPromptDismissed") }
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
    nonisolated(unsafe) private var capturedPresentationWindow: ASPresentationAnchor?

    // MARK: - Keychain keys

    private enum KeychainKey {
        static let steamID        = "meridian.steam.steamid"
        static let apiKey         = "meridian.steam.apikey"
        static let vmUsername     = "meridian.steam.vm.username"
        static let vmPassword     = "meridian.steam.vm.password"
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

    /// Optional Steam username for VM auto-login fallback.
    var vmUsername: String {
        get { loadSecret(key: KeychainKey.vmUsername) ?? "" }
        set {
            if newValue.isEmpty { deleteSecret(key: KeychainKey.vmUsername) }
            else { saveSecret(newValue, key: KeychainKey.vmUsername) }
        }
    }

    /// Optional Steam password for VM auto-login fallback (stored encrypted in Keychain).
    var vmPassword: String {
        get { loadSecret(key: KeychainKey.vmPassword) ?? "" }
        set {
            if newValue.isEmpty { deleteSecret(key: KeychainKey.vmPassword) }
            else { saveSecret(newValue, key: KeychainKey.vmPassword) }
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
        guard !isAuthenticating else { return }
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
            // User dismissed the sheet — not an error.
        } catch {
            authError = error.localizedDescription
        }
    }

    func signOut() {
        isAuthenticated = false
        steamID = ""
        displayName = ""
        avatarURL = nil
        deleteSecret(key: KeychainKey.steamID)
        apiKeyPromptDismissed = false
        // Intentionally preserve apiKey, vmUsername, vmPassword across sign-out
        // so users don't have to re-enter them if they sign back in.
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
        // Our localhost server issues a redirect to:
        //   meridian://auth/callback?steamid=<steamID64>
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        guard
            let id = components?.queryItems?.first(where: { $0.name == "steamid" })?.value,
            id.count >= 17,
            id.allSatisfy(\.isNumber)
        else {
            throw AuthError.invalidCallback
        }

        let extractedID = id

        steamID = extractedID
        saveSecret(extractedID, key: KeychainKey.steamID)

        // Fetch display name + avatar if we already have an API key stored.
        await refreshProfile(steamID: extractedID)

        isAuthenticated = true
    }

    /// Fetches the player profile and updates displayName / avatarURL.
    /// Safe to call any time; silently does nothing if the API key is absent.
    func refreshProfile(steamID: String) async {
        let key = apiKey
        guard !key.isEmpty else {
            displayName = displayName.isEmpty ? "Steam User" : displayName
            return
        }
        if let summary = try? await SteamAPIService.shared.fetchPlayerSummary(
            steamID: steamID, apiKey: key
        ) {
            displayName = summary.personaName
            avatarURL   = URL(string: summary.avatarFull)
        }
    }

    private func restoreSession() {
        guard let savedID = loadSecret(key: KeychainKey.steamID), !savedID.isEmpty else { return }
        steamID = savedID
        isAuthenticated = true
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
