import Foundation
import Observation

private let log = MeridianLog(category: "SteamExeSignIn")

/// Drives `steam.exe` directly to perform a fresh, native CM-protocol sign-in.
///
/// ## Why this exists (April 25 2026 — replaces JWT injection)
///
/// Earlier Meridian versions (April 23-25 2026) authenticated via Valve's
/// `IAuthenticationService` REST API and injected the resulting JWT into the
/// prefix as a DPAPI-encrypted `local.vdf`. Steam's `crypt32` decrypts the blob
/// successfully but Valve's CM rejects the JWT with `Invalid Password` because
/// the JWT lacks the `machine_id` HMAC binding that `steam.exe` produces from
/// Wine's synthetic WMI identity. CLI-verified end-to-end on the live bottle:
///
/// ```
/// [Connected]  Logging on [U:1:0]
/// BeginAuthSessionViaCredentials failed, 1/5 ()
/// ConnectionDisconnected('Disconnected By Remote Host') : 'Invalid Password'
/// Sending SteamServerConnectFailure_t Invalid Password Do not reconnect
/// ```
///
/// `steam.exe` then falls back to its own `BeginAuthSessionViaCredentials` CM
/// call — which works because Steam derives its own `machine_id` and Valve
/// already trusts that fingerprint. Our solution: skip the JWT round-trip and
/// drive `steam.exe`'s own CM sign-in directly with the user's credentials.
///
/// ## Flow
///
/// 1. Wipe stale `local.vdf` so Steam doesn't try (and fail) to auto-login on
///    its old rejected token before we can hand it credentials.
/// 2. `wineserver -k` → start
///    `steam.exe -silent -nofriendsui -login USER PASS` via
///    `WineSteamManager.startPersistent(extraArgs:)`. SteamUI consumes the
///    `-login` flag during start-up and drives the CM auth handshake
///    automatically — same code path as if the user typed credentials into
///    Steam's own login form, but with no UI rendering because `-silent`
///    suppresses the windows.
/// 3. Watch `connection_log.txt` for the outcome:
///    - `[Logged On, ` → ✅ done. Steam writes its own `local.vdf` with the
///      proper `machine_id` binding. Future launches use `-silent` silently.
///    - `Sending SteamServerConnectFailure_t Invalid Password` → ❌ bad creds
///      OR account locked / cooldown.
///    - `'Two-factor code mismatch'` / `Steam Guard required` → user account
///      has TOTP/email-code Steam Guard. Surfaced as `.twoFactorRequired` —
///      the user's account uses Mobile Confirmation = push, which Steam waits
///      for silently and doesn't surface this signal.
///    - Mobile Confirmation push: Steam's own protocol sends a push to the
///      Steam Mobile app. User taps Approve. Logged On follows. Zero UI on
///      our end.
///
/// ## Why this is the right architecture
///
/// - Steam owns its own auth state. We never touch its on-disk token. Any
///   future Steam protocol change can't break us — Steam handles its own
///   format, machine_id derivation, token refresh, etc.
/// - No `meridian-dpapi.exe`, no `local.vdf` injection, no machine_id mismatch.
/// - Subsequent launches: `steam.exe -silent` reads its own state and
///   auto-logs in silently. The same path Steam uses on Windows.
/// - All UI stays in Meridian. Steam runs headless. The window suppressor
///   hides any transient Steam window if one appears (already in place for
///   defence-in-depth).
@Observable
@MainActor
final class SteamExeSignIn {

    // MARK: - State

    enum Step: Equatable {
        case idle
        /// Wiping prior session + spawning `steam.exe -silent -login USER PASS`.
        case startingSteam
        /// Steam.exe has been launched with `-login`; waiting on CM handshake.
        case sendingCredentials
        /// Waiting for `[Logged On, ` or a failure signal in connection_log.
        /// If the account uses Mobile Confirmation, the push arrives during
        /// this phase and the user taps Approve on their phone.
        case awaitingResult
        case done
    }

    /// Why an authentication attempt failed. Surface-mapped to user-visible
    /// messages in `AuthError.errorDescription` so AuthView can display them
    /// without translating eresult codes.
    enum FailureReason: Equatable {
        case invalidCredentials       // 'Invalid Password' from CM
        case accountLocked            // cooldown / rate-limit / suspended
        case twoFactorRequired        // TOTP / email code path (not yet driven)
        case steamCrashed(Int32)      // process exited mid-flight
        case timeout                  // never observed any signal
        case other(String)
    }

    enum AuthError: LocalizedError, Equatable {
        case failed(FailureReason)

        var errorDescription: String? {
            switch self {
            case .failed(let reason):
                switch reason {
                case .invalidCredentials:
                    return "Steam rejected those credentials. Double-check your username and password."
                case .accountLocked:
                    return "Steam temporarily locked sign-in for this account, usually after several failed attempts. Wait 15-30 minutes and try again."
                case .twoFactorRequired:
                    return "Your account uses Steam Guard codes. Approve sign-in from the Steam Mobile app, or wait — typed-code support is coming."
                case .steamCrashed(let code):
                    return "Steam exited unexpectedly during sign-in (code \(code)). Try again, or reset Wine in Settings."
                case .timeout:
                    return "Sign-in timed out waiting for Steam. Check your connection and try again."
                case .other(let detail):
                    return detail
                }
            }
        }
    }

    private(set) var step: Step = .idle
    private(set) var errorMessage: String?

    @ObservationIgnored private var authTask: Task<Void, Never>?

    // MARK: - Public API

    /// Drives Steam.exe through a full credential sign-in.
    ///
    /// On success calls `onAuthenticated(steamID, accountName)` on the main actor
    /// and transitions to `.done`. On failure populates `errorMessage` and
    /// returns to `.idle`.
    ///
    /// `accountName` is normalised to lowercase to match how Steam itself stores
    /// it (Steam usernames are case-insensitive).
    func authenticate(
        username: String,
        password: String,
        engine: WineEngine,
        prefix: WinePrefix,
        steamManager: WineSteamManager,
        onAuthenticated: @escaping @MainActor (_ steamID: String, _ accountName: String) async -> Void
    ) {
        guard authTask == nil else { return }
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedUsername.isEmpty, !password.isEmpty else {
            errorMessage = "Username and password are required."
            return
        }

        errorMessage = nil
        step = .startingSteam

        authTask = Task { @MainActor [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await Self.runFlow(
                    username: trimmedUsername,
                    password: password,
                    engine: engine,
                    prefix: prefix,
                    steamManager: steamManager,
                    setStep: { newStep in self?.step = newStep }
                )
                self?.step = .done
                await onAuthenticated(result.steamID, result.accountName)
            } catch is CancellationError {
                log.info("[authenticate] cancelled")
                self?.step = .idle
            } catch let err as AuthError {
                self?.errorMessage = err.errorDescription
                self?.step = .idle
                log.error("[authenticate] failed: \(err.errorDescription ?? "<nil>")")
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.step = .idle
                log.error("[authenticate] unexpected error: \(error.localizedDescription)")
            }
            self?.authTask = nil
        }
    }

    func cancel() {
        authTask?.cancel()
        authTask = nil
        step = .idle
    }

    func reset() {
        cancel()
        errorMessage = nil
    }

    // MARK: - Flow

    private struct AuthResult {
        let steamID: String
        let accountName: String
    }

    /// Pure flow — broken out as `static` so the `Task` body doesn't capture
    /// the `@MainActor` self repeatedly across await points.
    private static func runFlow(
        username: String,
        password: String,
        engine: WineEngine,
        prefix: WinePrefix,
        steamManager: WineSteamManager,
        setStep: @MainActor (Step) -> Void
    ) async throws -> AuthResult {
        // 1. Tear down any prior session so steam.exe starts fresh. We must do
        //    this BEFORE launching the new process so it doesn't read a stale
        //    local.vdf and waste an attempt on Valve's cooldown counter.
        log.info("[runFlow] teardown — wiping local.vdf and killing all Wine procs")
        steamManager.killAll(engine: engine, prefix: prefix)
        steamManager.clearPersistentProcess()
        try? await Task.sleep(for: .milliseconds(500))
        Self.wipeLocalVdf(prefix: prefix)
        prefix.clearCrashMarker()
        // Truncate the two log files we parse so we never match a marker from a
        // prior (rejected) attempt — fail-fast.mdc requires distinguishing
        // THIS run's outcome from history.
        Self.truncateLogs(prefix: prefix)

        // 2. Capture log offsets BEFORE launch, since fileSize-after-launch
        //    races with Steam buffering.
        let connLogPath = prefix.steamInstallDir.appending(path: "logs/connection_log.txt").path(percentEncoded: false)
        let uiLogPath   = prefix.steamInstallDir.appending(path: "logs/steamui_login.txt").path(percentEncoded: false)
        let startConnSize = Self.fileSize(at: connLogPath)
        let startUISize   = Self.fileSize(at: uiLogPath)

        // 3. Launch `steam.exe -silent -nofriendsui -login USER PASS`. SteamUI
        //    consumes the `-login` flag at start-up and drives the CM auth
        //    handshake automatically — Steam's own machine_id is used (the one
        //    Valve already trusts), so the JWT issued by CM is bound correctly
        //    and Steam writes it to `local.vdf` itself.
        await MainActor.run { setStep(.sendingCredentials) }
        try await steamManager.startPersistent(
            engine: engine,
            prefix: prefix,
            extraArgs: ["-login", username, password]
        )
        log.info("[runFlow] steam.exe -login dispatched — watching for outcome")

        // 4. Watch connection_log.txt for the auth outcome. Mobile-Confirmation
        //    accounts trigger a phone push; user taps Approve; Steam reaches
        //    Logged On asynchronously. We allow up to 210s for that round-trip
        //    (Valve's push timeout is ~90s + buffer for Steam to reconnect).
        await MainActor.run { setStep(.awaitingResult) }
        let outcome = try await Self.waitForAuthOutcome(
            connLogPath: connLogPath,
            uiLogPath: uiLogPath,
            connStartOffset: startConnSize,
            uiStartOffset: startUISize,
            timeout: .seconds(210),
            steamManager: steamManager
        )

        switch outcome {
        case .loggedOn(let steamID):
            log.info("[runFlow] ✅ logged on — steamID=\(steamID)")
            try await Self.ensureLocalVdfOnDisk(
                prefix: prefix,
                engine: engine,
                steamManager: steamManager
            )
            return AuthResult(steamID: steamID, accountName: username)
        case .invalidPassword:
            throw AuthError.failed(.invalidCredentials)
        case .accountLocked:
            throw AuthError.failed(.accountLocked)
        case .needsTwoFactor:
            throw AuthError.failed(.twoFactorRequired)
        case .processExited(let code):
            throw AuthError.failed(.steamCrashed(code))
        case .timeout:
            throw AuthError.failed(.timeout)
        }
    }

    // MARK: - Session file persistence (local.vdf)

    /// Steam's DPAPI-wrapped `local.vdf` is often **not** on disk the instant
    /// `connection_log.txt` prints `[Logged On, ` — the client can defer the
    /// flush until a later tick or until shutdown. `AuthView` immediately calls
    /// `backupSteamSession()`; without waiting, that races and `installGame`'s
    /// `stopPersistent` + silent restart finds no token → `waitUntilReady`
    /// times out (Connected but never Logged On).
    ///
    /// Minimum size is a loose guard against an empty or half-written file.
    static let minimumLocalVdfByteCount = 64

    static func hasPlausibleLocalVdf(steamLocalDir: URL) -> Bool {
        localVdfByteCount(steamLocalDir: steamLocalDir) >= minimumLocalVdfByteCount
    }

    private static func localVdfByteCount(steamLocalDir: URL) -> Int {
        let path = steamLocalDir.appending(path: "local.vdf").path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// After a successful CM logon, blocks until `local.vdf` is readable and
    /// sized like a real DPAPI blob. If it never appears while Steam is still
    /// running, performs a graceful shutdown (flush) and polls again, then
    /// cold-starts `steam.exe -silent` and reuses `waitUntilReady` so the
    /// same session path `installGame` relies on is proven before sign-in
    /// completes.
    private static func ensureLocalVdfOnDisk(
        prefix: WinePrefix,
        engine: WineEngine,
        steamManager: WineSteamManager
    ) async throws {
        let steamLocal = prefix.localAppDataSteamDir
        let waitWhileRunning = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < waitWhileRunning {
            if hasPlausibleLocalVdf(steamLocalDir: steamLocal) {
                log.info("[ensureLocalVdf] present while running (\(localVdfByteCount(steamLocalDir: steamLocal)) bytes)")
                return
            }
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(400))
        }

        log.warning("[ensureLocalVdf] missing after 60s while running — stopping Steam to flush")
        await steamManager.stopPersistent(engine: engine, prefix: prefix)

        let afterStop = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < afterStop {
            if hasPlausibleLocalVdf(steamLocalDir: steamLocal) {
                log.info("[ensureLocalVdf] present after shutdown (\(localVdfByteCount(steamLocalDir: steamLocal)) bytes)")
                break
            }
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(400))
        }

        guard hasPlausibleLocalVdf(steamLocalDir: steamLocal) else {
            throw AuthError.failed(.other("Steam did not save its session file (local.vdf). Try again, or reset the Wine environment in Settings."))
        }

        log.info("[ensureLocalVdf] restarting silent steam to verify auto-login")
        try await steamManager.startPersistent(engine: engine, prefix: prefix, extraArgs: [])
        do {
            try await steamManager.waitUntilReady(prefix: prefix, timeout: .seconds(180))
        } catch WineSteamManager.SteamError.authenticationFailed {
            throw AuthError.failed(.other("Signed in, but Steam could not reload its saved session. Try again or reset the Wine environment in Settings."))
        } catch {
            throw AuthError.failed(.other(error.localizedDescription))
        }
    }

    // MARK: - Helpers — log wiping

    /// Best-effort delete of `local.vdf` so steam.exe doesn't try (and fail)
    /// to auto-login on a stale token. If the file doesn't exist this is a
    /// no-op.
    private static func wipeLocalVdf(prefix: WinePrefix) {
        let url = prefix.localAppDataSteamDir.appending(path: "local.vdf")
        let path = url.path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(at: url)
            log.info("[wipeLocalVdf] removed \(path)")
        }
    }

    /// Truncates Steam's two relevant log files so our outcome parser only
    /// sees THIS run's events. Without this, a `[Logged On, ` line from a
    /// prior session causes a false-positive success.
    ///
    /// We can't remove these — Steam holds them open. Truncating to zero
    /// bytes is safe; Steam appends to whatever is at EOF.
    private static func truncateLogs(prefix: WinePrefix) {
        let logsDir = prefix.steamInstallDir.appending(path: "logs")
        let targets = ["connection_log.txt", "steamui_login.txt"]
        for name in targets {
            let path = logsDir.appending(path: name).path(percentEncoded: false)
            if FileManager.default.fileExists(atPath: path) {
                if let fh = try? FileHandle(forWritingTo: URL(filePath: path)) {
                    try? fh.truncate(atOffset: 0)
                    try? fh.close()
                    log.debug("[truncateLogs] truncated \(name)")
                }
            }
        }
    }

    // MARK: - Helpers — outcome polling

    private enum AuthOutcome {
        case loggedOn(steamID: String)
        case invalidPassword
        case accountLocked
        case needsTwoFactor
        case processExited(Int32)
        case timeout
    }

    private static func waitForAuthOutcome(
        connLogPath: String,
        uiLogPath: String,
        connStartOffset: Int,
        uiStartOffset: Int,
        timeout: Duration,
        steamManager: WineSteamManager
    ) async throws -> AuthOutcome {
        let deadline = ContinuousClock.now + timeout
        var poll = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            poll += 1

            if !steamManager.isSteamProcessAlive {
                return .processExited(-1)
            }

            // Read both log tails once per poll for outcome detection.
            let connTail = Self.readTail(path: connLogPath, fromOffset: connStartOffset)
            let uiTail   = Self.readTail(path: uiLogPath,   fromOffset: uiStartOffset)
            let combined = connTail + "\n" + uiTail

            // Success — primary signal is `[Logged On, ` in connection_log
            // followed by a non-zero `[U:1:NNN]` account ID.
            if let steamID = Self.extractSteamID(from: connTail) {
                return .loggedOn(steamID: steamID)
            }

            // Failure — bad credentials. Steam writes both:
            //   `Sending SteamServerConnectFailure_t Invalid Password Do not reconnect`
            // and:
            //   `SetLoginState: WaitingForCredentials - Invalid Password`
            // Either is sufficient.
            if combined.contains("Sending SteamServerConnectFailure_t Invalid Password")
                || combined.contains("WaitingForCredentials - Invalid Password") {
                return .invalidPassword
            }

            // Failure — account locked / rate-limited.
            if combined.contains("AccountLocked") || combined.contains("Account locked")
                || combined.contains("RateLimitExceeded") {
                return .accountLocked
            }

            // 2FA required — TOTP / email code (Mobile Confirmation push does
            // NOT show this; Steam silently waits for the tap).
            if combined.contains("Two-factor code mismatch")
                || combined.contains("AccountLogonDeniedNeedTwoFactorCode")
                || combined.contains("WaitingForTwoFactor") {
                return .needsTwoFactor
            }

            if poll % 10 == 0 {
                log.info("[waitForAuthOutcome] poll=\(poll) connTail=\(connTail.count)b uiTail=\(uiTail.count)b")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return .timeout
    }

    // MARK: - Helpers — file IO

    private static func fileSize(at path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// Reads the bytes of `path` past `fromOffset`. Returns "" if the file
    /// does not exist or has shrunk (truncation case).
    private static func readTail(path: String, fromOffset: Int) -> String {
        let current = fileSize(at: path)
        guard current > fromOffset else { return "" }
        guard let fh = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return "" }
        defer { try? fh.close() }
        try? fh.seek(toOffset: UInt64(fromOffset))
        let data = (try? fh.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Extracts the SteamID from a `[Logged On, N, M] [U:1:NNNNN] ...` line in
    /// connection_log. Returns nil if no logon line is present yet.
    ///
    /// Steam logs the SteamID in the canonical `U:1:<accountID>` form. We
    /// convert it to the SteamID64 form (the public-universe base
    /// `76561197960265728` plus the accountID) so callers can pass it
    /// straight to `loginusers.vdf` / API calls without further conversion.
    static func extractSteamID(from log: String) -> String? {
        guard let logonRange = log.range(of: "[Logged On, ") else { return nil }
        let after = log[logonRange.upperBound...]
        guard let startIdx = after.range(of: "[U:1:") else { return nil }
        let tail = after[startIdx.upperBound...]
        var accountID: UInt64 = 0
        for ch in tail {
            if let d = ch.hexDigitValue, ch.isNumber {
                accountID = accountID * 10 + UInt64(d)
            } else {
                break
            }
        }
        guard accountID > 0 else { return nil }
        let steamID64 = accountID + 76561197960265728
        return String(steamID64)
    }
}
