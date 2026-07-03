import Foundation
import Security
import Observation

private let log = MeridianLog(category: "SteamCredentialAuth")

/// Authenticates to Steam natively via Steam's IAuthenticationService REST API.
///
/// No Wine processes or Steam UI windows are involved at any point. Credentials
/// go directly to Steam's HTTPS endpoints; the resulting refresh token is written
/// into the Wine prefix so Wine's Steam auto-logins silently on next start.
///
/// Flow:
///   1. GetPasswordRSAPublicKey  → RSA-encrypt the password (Security framework)
///   2. BeginAuthSessionViaCredentials → get client_id, request_id, steamid
///   3. (optional) UpdateAuthSessionWithSteamGuardCode → submit email/TOTP code
///   4. PollAuthSessionStatus   → wait for refresh_token + access_token
///   5. Write loginusers.vdf + config.vdf into the Wine prefix
///   6. Kill current unauthenticated Steam, start new authenticated persistent Steam
@Observable
@MainActor
final class SteamCredentialAuth {

    // MARK: - Auth step

    enum AuthStep: Equatable {
        case idle
        case authenticating          // RSA fetch + BeginSession
        case awaitingGuardCode(GuardType)  // waiting for user to type a code
        case polling                 // PollAuthSessionStatus loop
        case done
    }

    /// The type of Steam Guard challenge the server requires.
    enum GuardType: Int, Equatable {
        case emailCode = 2           // 6-digit code sent to account email
        case deviceCode = 3          // TOTP code from mobile authenticator
        case deviceConfirmation = 4  // tap approve on phone — no code to type
        case emailConfirmation = 5   // click link in email — no code to type
    }

    private(set) var step: AuthStep = .idle
    private(set) var errorMessage: String?

    /// The `challenge_url` returned by `BeginAuthSessionViaQR`, rendered as a
    /// QR code natively (CoreImage) inside Meridian's onboarding sheet. Set
    /// while a QR sign-in is in flight; nil otherwise. Scanning + approving in
    /// the Steam Mobile app completes the same `PollAuthSessionStatus` loop the
    /// password flow uses — no typed username/password/2FA, no Steam window.
    private(set) var qrChallengeURL: String?

    /// True once Valve reports the QR has been scanned but not yet approved
    /// (`had_remote_interaction`). Lets the UI nudge "now tap Approve".
    private(set) var qrScanned: Bool = false

    /// When `deviceConfirmation` is the primary path but a typed-code option is also
    /// available, this is set to the fallback type so the UI can offer "use a code instead".
    /// The user calls `submitFallbackCode(_:)` while polling is already running —
    /// the next poll cycle will pick up the approved auth automatically.
    private(set) var fallbackCodeType: GuardType?

    @ObservationIgnored private var authTask: Task<Void, Never>?
    @ObservationIgnored private var guardContinuation: CheckedContinuation<String, Error>?

    /// Stored during auth so `submitFallbackCode` can call the right endpoint.
    @ObservationIgnored private var pendingClientID: String = ""
    @ObservationIgnored private var pendingSteamID: String = ""

    // MARK: - Public API

    /// Begins the authentication flow against Steam's API servers.
    ///
    /// This is a pure-HTTPS operation — no Wine processes, no prefix access.
    /// On success, `onAuthenticated` is called with (steamID, accountName, refreshToken).
    /// The caller decides what to do with those tokens (onboarding: store them for bootstrap;
    /// re-auth from SetupSheet: write them directly into the prefix and restart Steam).
    ///
    /// `step` transitions to `.done` after `onAuthenticated` completes.
    func authenticate(
        username: String,
        password: String,
        onAuthenticated: @escaping @MainActor (String, String, String) async -> Void = { _, _, _ in }
    ) {
        guard authTask == nil else { return }
        step = .authenticating
        errorMessage = nil

        let trimmed = username.trimmingCharacters(in: .whitespaces)

        authTask = Task { @MainActor [weak self] in
            do {
                try await self?.runAuthFlow(
                    username: trimmed,
                    password: password,
                    onAuthenticated: onAuthenticated
                )
                self?.step = .done
            } catch is CancellationError {
                log.info("[auth] authentication cancelled")
                self?.step = .idle
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.step = .idle
                self?.guardContinuation?.resume(throwing: error)
                self?.guardContinuation = nil
            }
            self?.authTask = nil
        }
    }

    /// Begins a QR sign-in flow — the seamless, no-typing path.
    ///
    /// Calls `BeginAuthSessionViaQR`, publishes `qrChallengeURL` (which the UI
    /// renders as a QR image via CoreImage), and polls `PollAuthSessionStatus`.
    /// The user scans the QR with the Steam Mobile app and taps Approve; the
    /// poll loop then returns a `persistence: 1` refresh token — identical to
    /// the password flow's output, so every downstream consumer (DepotDownloader,
    /// local.vdf, Online-mode steam.exe) is unchanged.
    ///
    /// This is the CrossOver-equivalent auth: Steam authenticates the session
    /// through its own trusted QR channel; Meridian never types credentials
    /// into `steam.exe` and never shows a Steam window. `persistence: 1` is
    /// guaranteed for QR logins (email-Guard accounts cannot use QR at all).
    func authenticateWithQR(
        onAuthenticated: @escaping @MainActor (String, String, String) async -> Void = { _, _, _ in }
    ) {
        guard authTask == nil else { return }
        step = .authenticating
        errorMessage = nil
        qrChallengeURL = nil
        qrScanned = false

        authTask = Task { @MainActor [weak self] in
            do {
                try await self?.runQRFlow(onAuthenticated: onAuthenticated)
                self?.step = .done
            } catch is CancellationError {
                log.info("[auth] QR authentication cancelled")
                self?.step = .idle
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.step = .idle
            }
            self?.authTask = nil
            self?.qrChallengeURL = nil
        }
    }

    /// Submit the Steam Guard code entered by the user.
    /// Only valid while `step == .awaitingGuardCode` for a code-entry type.
    func submitGuardCode(_ code: String) {
        guardContinuation?.resume(returning: code)
        guardContinuation = nil
        step = .polling
    }

    /// Submits a typed code while `deviceConfirmation` polling is already running.
    ///
    /// Used when the user has both a push notification AND a TOTP/email option and
    /// chooses to enter a code instead of tapping Approve. The ongoing `pollForTokens`
    /// loop will detect the completed auth on its next cycle.
    func submitFallbackCode(_ code: String) {
        guard let fallbackType = fallbackCodeType, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let clientID = pendingClientID
        let steamID  = pendingSteamID
        Task { @MainActor [weak self] in
            do {
                try await self?.submitSteamGuardCode(
                    clientID: clientID,
                    steamID: steamID,
                    code: code,
                    codeType: fallbackType
                )
                log.info("[auth] fallback code accepted — polling will complete auth")
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    /// Cancel any in-progress authentication and return to idle.
    func cancel() {
        authTask?.cancel()
        authTask = nil
        guardContinuation?.resume(throwing: CancellationError())
        guardContinuation = nil
        step = .idle
        errorMessage = nil
        fallbackCodeType = nil
        pendingClientID = ""
        pendingSteamID = ""
        qrChallengeURL = nil
        qrScanned = false
    }

    func reset() {
        cancel()
    }

    // MARK: - Refresh-token renewal (Pattern 23)

    /// Outcome of a `GenerateAccessTokenForApp` refresh-token exchange.
    ///
    /// The authoritative signal is the `x-eresult` HTTP header (CLI-verified
    /// Pattern 23), NOT the (frequently empty) JSON body.
    enum RenewalOutcome: Equatable {
        /// Valve rotated the refresh token — persist the new one.
        case renewed(String)
        /// Token still valid; no rotation needed.
        case valid
        /// Token is genuinely dead (revoked / password change / aged out) —
        /// route the user to re-auth.
        case invalid
        /// `x-eresult: 15` (EResult.AccessDenied). Valve's anti-abuse system
        /// is denying this account's client-token exchange server-side. NOT a
        /// dead token and NOT code-fixable — keep the token and do NOT force
        /// re-auth (re-minting only feeds the lockout, Pattern 23).
        case accessDenied
        /// Transient network / 5xx error — keep the token and retry next launch.
        case networkError
    }

    /// Validates (and, if Valve rotates it, renews) the stored OAuth refresh
    /// token against `IAuthenticationService/GenerateAccessTokenForApp`.
    ///
    /// `nonisolated static` so it can be awaited from any context (startup
    /// `restoreSession`, install-time re-check) without hopping to the main
    /// actor. Pure HTTPS; no Wine, no prefix access.
    ///
    /// Classification (Pattern 23, CLI-verified Jun 20 2026):
    /// - HTTP 5xx / transport error → `.networkError` (token preserved).
    /// - body has a rotated `refresh_token` → `.renewed`.
    /// - body has an `access_token` (no rotation) → `.valid`.
    /// - empty body + `x-eresult: 15` → `.accessDenied` (account anti-abuse; keep token).
    /// - empty body + any other eresult → `.invalid` (dead → re-auth).
    nonisolated static func renewRefreshToken(
        steamID: String,
        refreshToken: String
    ) async -> RenewalOutcome {
        guard !steamID.isEmpty, !refreshToken.isEmpty else { return .invalid }

        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/GenerateAccessTokenForApp/v1/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = formEncodeStatic([
            "steamid":       steamID,
            "refresh_token": refreshToken,
            // renewal_type=1 permits Valve to rotate the token in the response.
            "renewal_type":  "1",
        ]).data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .networkError }

            // 5xx = transient server-side issue; never treat as a dead token.
            if (500...599).contains(http.statusCode) { return .networkError }

            let eresult = http.value(forHTTPHeaderField: "x-eresult").flatMap { Int($0) }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let resp = json?["response"] as? [String: Any]

            if let rotated = resp?["refresh_token"] as? String, !rotated.isEmpty {
                return .renewed(rotated)
            }
            if let access = resp?["access_token"] as? String, !access.isEmpty {
                return .valid
            }
            // Empty response body — the eresult header decides.
            if eresult == 15 { return .accessDenied }
            return .invalid
        } catch {
            return .networkError
        }
    }

    /// `nonisolated` form encoder for use by `renewRefreshToken`.
    /// Same strict percent-encoding contract as the instance `formEncode`.
    nonisolated private static func formEncodeStatic(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
    }

    // MARK: - Auth flow

    private func runAuthFlow(
        username: String,
        password: String,
        onAuthenticated: @escaping @MainActor (String, String, String) async -> Void
    ) async throws {

        // 1. Get RSA public key for this account name
        log.info("[auth] fetching RSA public key for user=\(username)")
        let rsaKey = try await getRSAPublicKey(accountName: username)

        // 2. RSA-encrypt the password using Apple's Security framework
        log.info("[auth] encrypting password (key bits=\(rsaKey.publicKeyMod.count * 4))")
        let encryptedPassword = try encryptPassword(
            password,
            modulusHex: rsaKey.publicKeyMod,
            exponentHex: rsaKey.publicKeyExp
        )

        // 3. Begin authentication session with Steam
        log.info("[auth] beginning auth session")
        let session = try await beginAuthSession(
            accountName: username,
            encryptedPassword: encryptedPassword,
            encryptionTimestamp: rsaKey.timestamp
        )
        log.info("[auth] session started | steamid=\(session.steamID) client_id=\(session.clientID)")

        // 4. Handle Steam Guard if required.
        let codeGuardType = session.allowedConfirmations.first(where: { $0 != .deviceConfirmation })

        pendingClientID = session.clientID
        pendingSteamID  = session.steamID

        if session.allowedConfirmations.contains(.deviceConfirmation) {
            fallbackCodeType = codeGuardType
            log.info("[auth] device confirmation required (tap on phone); fallback=\(String(describing: codeGuardType))")
            step = .awaitingGuardCode(.deviceConfirmation)
            try? await Task.sleep(for: .seconds(1))
            step = .polling

        } else if let guardType = codeGuardType {
            log.info("[auth] Steam Guard code required: type=\(guardType.rawValue)")
            step = .awaitingGuardCode(guardType)

            let code: String = try await withCheckedThrowingContinuation { cont in
                guardContinuation = cont
            }

            log.info("[auth] submitting guard code")
            try await submitSteamGuardCode(
                clientID: session.clientID,
                steamID: session.steamID,
                code: code,
                codeType: guardType
            )
            step = .polling

        } else {
            step = .polling
        }

        // 5. Poll for tokens
        log.info("[auth] polling for session tokens")
        let tokens = try await pollForTokens(
            clientID: session.clientID,
            requestID: session.requestID,
            interval: session.interval
        )
        log.info("[auth] tokens received for account=\(tokens.accountName)")

        // 6. Hand tokens to the caller — they decide what to do (write to prefix,
        //    store for later, etc.). This is a pure-auth method; no Wine operations.
        await onAuthenticated(session.steamID, tokens.accountName, tokens.refreshToken)
        log.info("[auth] authentication complete ✓ steamID=\(session.steamID)")
    }

    // MARK: - QR flow

    private func runQRFlow(
        onAuthenticated: @escaping @MainActor (String, String, String) async -> Void
    ) async throws {
        log.info("[auth] beginning QR auth session")
        let session = try await beginQRSession()
        log.info("[auth] QR session started | client_id=\(session.clientID)")

        // Publish the challenge URL so the UI renders the QR. `pollForTokens`
        // adopts any rotated challenge URL Steam returns mid-session and keeps
        // `qrChallengeURL` current, so a scan of a rotated code still works.
        qrChallengeURL = session.challengeURL
        step = .polling

        let tokens = try await pollForTokens(
            clientID: session.clientID,
            requestID: session.requestID,
            interval: session.interval,
            isQR: true
        )
        log.info("[auth] QR tokens received for account=\(tokens.accountName)")

        // QR's BeginAuthSessionViaQR does not return a steamID (it's not known
        // until a device approves). Recover it from the refresh token's `sub`
        // claim — the JWT subject IS the 64-bit steamID.
        let steamID = Self.steamID(fromJWT: tokens.refreshToken) ?? session.steamID
        guard !steamID.isEmpty else {
            throw AuthError.unexpectedResponse("QR auth succeeded but steamID could not be derived from the token")
        }

        await onAuthenticated(steamID, tokens.accountName, tokens.refreshToken)
        log.info("[auth] QR authentication complete ✓ steamID=\(steamID)")
    }

    private struct QRSession {
        let clientID: String
        let requestID: String
        let challengeURL: String
        let interval: Double
        /// steamID is not known until the poll completes for QR logins.
        let steamID: String
    }

    private func beginQRSession() async throws -> QRSession {
        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/BeginAuthSessionViaQR/v1/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "device_friendly_name": "Meridian on Mac",
            // platform_type 1 = SteamClient → persistence:1 refresh token
            // (matches the password flow; required so the token is usable for
            // client logon, DepotDownloader, and local.vdf auto-login).
            "platform_type":        "1",
            "website_id":           "Client",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw AuthError.networkError("BeginAuthSessionViaQR failed: HTTP \(http?.statusCode ?? -1)")
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resp = json?["response"] as? [String: Any]
        guard
            let clientID     = resp?["client_id"]     as? String, !clientID.isEmpty,
            let requestID    = resp?["request_id"]    as? String, !requestID.isEmpty,
            let challengeURL = resp?["challenge_url"] as? String, !challengeURL.isEmpty
        else {
            throw AuthError.unexpectedResponse("BeginAuthSessionViaQR response missing required fields")
        }

        let interval = resp?["interval"] as? Double ?? 5.0
        return QRSession(
            clientID: clientID,
            requestID: requestID,
            challengeURL: challengeURL,
            interval: interval,
            steamID: (resp?["steamid"] as? String) ?? ""
        )
    }

    /// Extracts the 64-bit steamID from a Steam JWT's `sub` claim.
    ///
    /// Steam refresh/access tokens are JWTs whose subject (`sub`) is the
    /// account's steamID64. The QR flow doesn't otherwise surface the steamID,
    /// so we decode the (unverified — we only read a public claim) payload.
    nonisolated static func steamID(fromJWT jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4 for base64 decoding.
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String, !sub.isEmpty
        else { return nil }
        return sub
    }

    // MARK: - API: GetPasswordRSAPublicKey

    private struct RSAKeyResponse {
        let publicKeyMod: String
        let publicKeyExp: String
        let timestamp: String
    }

    private func getRSAPublicKey(accountName: String) async throws -> RSAKeyResponse {
        var components = URLComponents(string: "https://api.steampowered.com/IAuthenticationService/GetPasswordRSAPublicKey/v1/")!
        components.queryItems = [URLQueryItem(name: "account_name", value: accountName)]

        let (data, response) = try await URLSession.shared.data(from: components.url!)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            throw AuthError.networkError("RSA key fetch failed: HTTP \(http?.statusCode ?? -1)")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard
            let resp = json?["response"] as? [String: Any],
            let mod = resp["publickey_mod"] as? String, !mod.isEmpty,
            let exp = resp["publickey_exp"] as? String, !exp.isEmpty,
            let ts  = resp["timestamp"] as? String
        else {
            throw AuthError.unexpectedResponse("RSA key response missing required fields")
        }

        return RSAKeyResponse(publicKeyMod: mod, publicKeyExp: exp, timestamp: ts)
    }

    // MARK: - API: BeginAuthSessionViaCredentials

    private struct AuthSession {
        let clientID: String
        let requestID: String
        let steamID: String
        let interval: Double
        let allowedConfirmations: [GuardType]
    }

    private func beginAuthSession(
        accountName: String,
        encryptedPassword: String,
        encryptionTimestamp: String
    ) async throws -> AuthSession {
        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/BeginAuthSessionViaCredentials/v1/")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "account_name":          accountName,
            "encrypted_password":    encryptedPassword,
            "encryption_timestamp":  encryptionTimestamp,
            "remember_login":        "1",
            "platform_type":         "1",
            "persistence":           "1",
            "website_id":            "Client",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let resp = json?["response"] as? [String: Any]

        // 400/401 from this endpoint indicates bad credentials
        if statusCode == 400 || statusCode == 401 {
            throw AuthError.invalidCredentials
        }

        guard statusCode == 200 else {
            let msg = resp?["extended_error_message"] as? String ?? "HTTP \(statusCode)"
            throw AuthError.networkError("BeginAuthSession failed: \(msg)")
        }

        // Explicit eresult failure on a 200 response
        if let eresult = resp?["eresult"] as? Int, eresult != 1 {
            if eresult == 5 { throw AuthError.invalidCredentials }
            let detail = resp?["extended_error_message"] as? String ?? ""
            throw AuthError.networkError("Steam error \(eresult)\(detail.isEmpty ? "" : ": \(detail)")")
        }

        guard
            let clientID  = resp?["client_id"]  as? String, !clientID.isEmpty,
            let requestID = resp?["request_id"]  as? String, !requestID.isEmpty,
            let steamID   = resp?["steamid"]     as? String, !steamID.isEmpty
        else {
            throw AuthError.unexpectedResponse("BeginAuthSession response missing required fields")
        }

        let interval = resp?["interval"] as? Double ?? 5.0
        let confirmations: [GuardType] = (resp?["allowed_confirmations"] as? [[String: Any]] ?? [])
            .compactMap { ($0["confirmation_type"] as? Int).flatMap { GuardType(rawValue: $0) } }

        return AuthSession(
            clientID: clientID,
            requestID: requestID,
            steamID: steamID,
            interval: interval,
            allowedConfirmations: confirmations
        )
    }

    // MARK: - API: UpdateAuthSessionWithSteamGuardCode

    private func submitSteamGuardCode(
        clientID: String,
        steamID: String,
        code: String,
        codeType: GuardType
    ) async throws {
        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/UpdateAuthSessionWithSteamGuardCode/v1/")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncode([
            "client_id":  clientID,
            "steamid":    steamID,
            "code":       code,
            "code_type":  "\(codeType.rawValue)",
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse

        if http?.statusCode == 200 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let resp = json?["response"] as? [String: Any]
            if let eresult = resp?["eresult"] as? Int, eresult != 1 {
                // eresult 88 = InvalidLoginAuthCode
                if eresult == 88 || eresult == 65 { throw AuthError.invalidGuardCode }
                throw AuthError.networkError("Guard code rejected (eresult=\(eresult))")
            }
        } else {
            throw AuthError.networkError("Guard code submission failed: HTTP \(http?.statusCode ?? -1)")
        }
    }

    // MARK: - API: PollAuthSessionStatus

    private struct SessionTokens {
        let refreshToken: String
        let accessToken: String
        let accountName: String
    }

    private func pollForTokens(
        clientID: String,
        requestID: String,
        interval: Double,
        isQR: Bool = false
    ) async throws -> SessionTokens {
        let url = URL(string: "https://api.steampowered.com/IAuthenticationService/PollAuthSessionStatus/v1/")!
        let pollInterval = max(interval, 2.0)
        let maxAttempts = 90  // ~3 minutes at 2s interval

        // Steam can rotate the client_id mid-session. Each PollAuthSessionStatus
        // response may include a `new_client_id` that MUST replace the original for
        // subsequent polls — using a stale client_id causes Steam to silently reject
        // the request (no error, no tokens) causing the poll loop to appear stuck.
        var currentClientID = clientID

        for attempt in 0..<maxAttempts {
            guard !Task.isCancelled else { throw CancellationError() }

            if attempt > 0 {
                try await Task.sleep(for: .seconds(pollInterval))
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // 15-second per-request timeout so a hung network call can't stall the loop indefinitely.
            request.timeoutInterval = 15
            request.httpBody = formEncode([
                "client_id":  currentClientID,
                "request_id": requestID,
            ]).data(using: .utf8)

            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse

            guard http?.statusCode == 200 else {
                log.debug("[auth] poll attempt \(attempt): HTTP \(http?.statusCode ?? -1)")
                continue
            }

            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let resp = json?["response"] as? [String: Any] else {
                log.debug("[auth] poll attempt \(attempt): unexpected response shape — \(String(data: data, encoding: .utf8)?.prefix(200) ?? "<nil>")")
                continue
            }

            // Steam may rotate the client_id — always adopt the latest one.
            // NOTE: Steam sends new_client_id as a JSON number (UInt64), not a string.
            // We handle both forms defensively so a future format change doesn't break this.
            if let newClientIDNum = resp["new_client_id"] as? UInt64 {
                let newStr = String(newClientIDNum)
                log.debug("[auth] poll attempt \(attempt): client_id rotated (numeric) \(currentClientID) → \(newStr)")
                currentClientID = newStr
            } else if let newClientIDStr = resp["new_client_id"] as? String, !newClientIDStr.isEmpty {
                log.debug("[auth] poll attempt \(attempt): client_id rotated (string) \(currentClientID) → \(newClientIDStr)")
                currentClientID = newClientIDStr
            }

            if isQR {
                // Steam rotates the QR challenge every ~30 s. Re-render the new
                // one so a slow scan still works.
                if let newChallenge = resp["new_challenge_url"] as? String, !newChallenge.isEmpty {
                    qrChallengeURL = newChallenge
                }
                // Once the phone has scanned (but not yet approved), nudge the UI.
                if (resp["had_remote_interaction"] as? Bool) == true, !qrScanned {
                    qrScanned = true
                    log.info("[auth] QR scanned — awaiting approval on device")
                }
            }

            if let eresult = resp["eresult"] as? Int, eresult != 1 {
                log.debug("[auth] poll attempt \(attempt): eresult=\(eresult)")
                // eresult 29 = Expired
                if eresult == 29 { throw AuthError.sessionExpired }
                continue
            }

            guard
                let refreshToken = resp["refresh_token"] as? String, !refreshToken.isEmpty,
                let accessToken  = resp["access_token"]  as? String,
                let accountName  = resp["account_name"]  as? String, !accountName.isEmpty
            else {
                log.debug("[auth] poll attempt \(attempt): tokens not ready yet")
                continue
            }

            return SessionTokens(
                refreshToken: refreshToken,
                accessToken: accessToken,
                accountName: accountName
            )
        }

        throw AuthError.pollingTimeout
    }

    // MARK: - RSA encryption

    private func encryptPassword(
        _ password: String,
        modulusHex: String,
        exponentHex: String
    ) throws -> String {
        guard
            let modulusData  = Data(hexString: modulusHex),
            let exponentData = Data(hexString: exponentHex),
            !modulusData.isEmpty, !exponentData.isEmpty
        else {
            throw AuthError.rsaFailed("Invalid RSA key: could not decode hex strings")
        }

        let derKey = buildRSAPublicKeyDER(modulus: modulusData, exponent: exponentData)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String:        kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:       kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String:  modulusData.count * 8,
        ]
        var cfError: Unmanaged<CFError>?

        guard let secKey = SecKeyCreateWithData(derKey as CFData, attributes as CFDictionary, &cfError) else {
            let detail = cfError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw AuthError.rsaFailed("SecKeyCreateWithData failed: \(detail)")
        }

        guard let encrypted = SecKeyCreateEncryptedData(
            secKey,
            .rsaEncryptionPKCS1,
            password.data(using: .utf8)! as CFData,
            &cfError
        ) else {
            let detail = cfError?.takeRetainedValue().localizedDescription ?? "unknown"
            throw AuthError.rsaFailed("SecKeyCreateEncryptedData failed: \(detail)")
        }

        return (encrypted as Data).base64EncodedString()
    }

    /// Encodes an RSA public key as a PKCS#1 RSAPublicKey DER structure.
    ///
    /// Format: SEQUENCE { INTEGER(modulus), INTEGER(exponent) }
    /// SecKeyCreateWithData accepts this format for RSA public keys.
    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func asn1Integer(_ raw: Data) -> Data {
            var payload = raw
            // Strip leading zero bytes, keeping at least one
            while payload.count > 1 && payload.first == 0x00 { payload = payload.dropFirst() }
            // Prepend 0x00 if the high bit is set (to indicate a positive integer)
            if payload.first ?? 0 >= 0x80 { payload = Data([0x00]) + payload }
            return Data([0x02]) + asn1Len(payload.count) + payload
        }

        func asn1Len(_ n: Int) -> Data {
            if n < 0x80   { return Data([UInt8(n)]) }
            if n < 0x100  { return Data([0x81, UInt8(n)]) }
            return Data([0x82, UInt8(n >> 8), UInt8(n & 0xFF)])
        }

        let body = asn1Integer(modulus) + asn1Integer(exponent)
        return Data([0x30]) + asn1Len(body.count) + body
    }

    // MARK: - Helpers

    /// Encodes key-value pairs as `application/x-www-form-urlencoded`.
    /// Uses strict percent-encoding so base64 characters (+, /, =) are safe.
    private func formEncode(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .sorted { $0.key < $1.key }
            .map { k, v in
                let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
                let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v
                return "\(ek)=\(ev)"
            }
            .joined(separator: "&")
    }

    // MARK: - Errors

    enum AuthError: LocalizedError {
        case networkError(String)
        case unexpectedResponse(String)
        case rsaFailed(String)
        case invalidCredentials
        case invalidGuardCode
        case pollingTimeout
        case sessionExpired
        case prefixWriteFailed(String)

        var errorDescription: String? {
            switch self {
            case .networkError(let msg):        return msg
            case .unexpectedResponse(let msg):  return "Unexpected response: \(msg)"
            case .rsaFailed(let msg):           return "Encryption error: \(msg)"
            case .invalidCredentials:           return "Incorrect username or password."
            case .invalidGuardCode:             return "Invalid Steam Guard code. Please try again."
            case .pollingTimeout:               return "Sign-in timed out. Please try again."
            case .sessionExpired:               return "Session expired. Please try again."
            case .prefixWriteFailed(let msg):   return "Could not write session files: \(msg)"
            }
        }
    }
}

// MARK: - Data hex decoding

private extension Data {
    init?(hexString: String) {
        var hex = hexString
        if hex.count % 2 != 0 { hex = "0" + hex }
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
