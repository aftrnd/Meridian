import AppKit
import Foundation
import Observation

private let log = MeridianLog(category: "SteamSession")

// MARK: - SteamSession

/// Single owner of the steam.exe lifecycle.
///
/// Before this class, four different objects each started steam.exe under
/// different conditions with different auth flags. This caused 2FA pushes during
/// silent bootstrap, duplicate restarts, and 2-minute timeouts. Now there is
/// exactly one path to start steam.exe, one path to stop it, and one path to
/// authenticate through the sign-in sheet.
///
/// ## Rules (enforced by the type system and guards)
/// - `start()` is ONLY for silent bootstrap (-silent, never -login).
///   Never throws. Sets state to .failed on auth timeout — ContentView shows sheet.
/// - `signIn()` is ONLY for user-initiated auth from the sign-in sheet (-login).
///   Throws on failure so the sheet can surface the error.
/// - `installGame()` and `launch()` refuse to run unless `isReady == true`.
///   No implicit Steam restart anywhere.
@Observable
@MainActor
final class SteamSession {

    // MARK: - State

    enum State: Equatable {
        /// steam.exe is not running.
        case idle
        /// Starting steam.exe -silent; watching for [Logged On,].
        case startingSilent
        /// steam.exe is running and authenticated.
        case running(pid: pid_t)
        /// SteamExeSignIn (-login) is in progress from the sign-in sheet.
        case signingIn
        /// Silent auth failed or steam.exe crashed. ContentView shows sign-in sheet.
        case failed(String)
    }

    private(set) var state: State = .idle

    var isReady: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Sign-in progress (read by AuthView)

    enum SignInProgress {
        case idle
        case startingSteam
        case sendingCredentials
        case awaitingResult
    }

    private(set) var signInProgress: SignInProgress = .idle
    private(set) var signInError: String?

    // MARK: - Private state

    private var persistentProcess: Process?
    private var connectionLogOffset: Int = 0
    private var activeSteamCMDProcess: Process?
    private let prefix = WinePrefix.defaultPrefix

    // MARK: - Dependency injection (set by MeridianApp)

    var steamWindow: SteamWindow?

    // MARK: - Public API: lifecycle

    /// Start steam.exe -silent. Never sends -login. Never throws.
    ///
    /// Called from BootstrapManager step 7 when a session exists on disk
    /// (ssfn token or loginusers.vdf). If Steam can auth silently from its
    /// own on-disk state (ssfn, local.vdf) it succeeds in ~5-10 s.
    /// If not, fails after 12 s → state = .failed → sign-in sheet recovers.
    func start(engine: WineEngine) async {
        guard case .idle = state else {
            log.info("[start] already in state \(String(describing: state)) — skip")
            return
        }

        state = .startingSilent
        steamWindow?.startSuppressing()

        do {
            try await launchSteamProcess(engine: engine, extraArgs: [])
            let pid = persistentProcess.flatMap { $0.isRunning ? $0.processIdentifier : nil } ?? 0
            let loggedOn = await waitForLoggedOn(
                engine: engine,
                timeout: .seconds(60),
                authTimeout: .seconds(12)
            )
            if loggedOn {
                state = .running(pid: pid_t(pid))
                log.info("[start] silent auth succeeded ✓ pid=\(pid)")
            } else {
                log.warning("[start] silent auth timed out — sign-in sheet will handle re-auth")
                state = .failed("Steam could not authenticate silently. Please sign in.")
            }
        } catch {
            log.warning("[start] steam.exe start failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Sign in with credentials. ONLY called from the sign-in sheet (SetupSheet).
    /// This is the ONLY place -login is ever sent. Throws on failure.
    func signIn(
        username: String,
        password: String,
        engine: WineEngine,
        onAuthenticated: @escaping @MainActor (String, String) async -> Void
    ) async throws {
        signInProgress = .startingSteam
        signInError = nil

        // Kill any prior steam.exe session before starting fresh.
        await shutdown(engine: engine)

        // Pre-write loginusers.vdf with RememberPassword=1 BEFORE launching.
        // Steam reads this flag at startup and sends should_remember_password=true
        // in CMsgClientLogon → Valve returns persistence=1 → ssfn token written.
        // steamID: stored value for re-auths; "0" placeholder on first sign-in
        // (Steam overwrites it with the real steamID after successful auth).
        let storedSteamID = AppSettings.shared.steamCredentialSteamID
        try? prefix.writeLoginUsers(
            steamID: storedSteamID.isEmpty ? "0" : storedSteamID,
            accountName: username,
            personaName: username
        )
        log.info("[signIn] pre-wrote loginusers.vdf RememberPassword=1 for ssfn creation")

        // Truncate log files so we never match markers from a prior attempt.
        truncateLogs()

        // Capture offset before launch so we only read THIS session's output.
        connectionLogOffset = connectionLogFileSize()

        state = .signingIn
        steamWindow?.startSuppressing()

        signInProgress = .sendingCredentials
        do {
            try await launchSteamProcess(engine: engine, extraArgs: ["-login", username, password])
        } catch {
            state = .failed(error.localizedDescription)
            signInProgress = .idle
            throw SessionError.steamLaunchFailed(error.localizedDescription)
        }

        signInProgress = .awaitingResult
        log.info("[signIn] steam.exe -login launched — watching for auth outcome")

        // Watch connection_log.txt for [Logged On,]. Mobile Confirmation accounts
        // trigger a phone push; user taps Approve; Logged On follows (~10-90 s).
        let outcome = try await waitForSignInOutcome(engine: engine, timeout: .seconds(210))

        signInProgress = .idle
        let pid = persistentProcess.flatMap { $0.isRunning ? $0.processIdentifier : nil } ?? 0
        state = .running(pid: pid_t(pid))
        log.info("[signIn] authenticated ✓ steamID=\(outcome.steamID) pid=\(pid)")

        // Persist steamID and accountName immediately so bootstrap can restore the
        // session on next cold start without re-prompting.
        AppSettings.shared.steamCredentialSteamID = outcome.steamID
        AppSettings.shared.steamCredentialAccountName = username

        // Tell the caller (AuthView) so it can advance the setup sheet.
        await onAuthenticated(outcome.steamID, outcome.accountName)
    }

    /// Gracefully shut down steam.exe and wait for all Wine processes to exit.
    func shutdown(engine: WineEngine) async {
        guard persistentProcess != nil || isReady else {
            state = .idle
            return
        }

        log.info("[shutdown] stopping steam.exe")
        steamWindow?.stopSuppressing()

        // Send steam.exe -shutdown via a second process instance. Steam's IPC
        // dispatches this as a graceful shutdown request to the running instance.
        if let wineURL = engine.wineExecutableURL {
            let shutdown = Process()
            shutdown.executableURL = wineURL
            shutdown.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
            shutdown.environment = engine.steamCMDEnvironment(for: prefix)
            shutdown.standardOutput = FileHandle.nullDevice
            shutdown.standardError = FileHandle.nullDevice
            try? shutdown.run()
            try? await Task.sleep(for: .seconds(2))
        }

        killAllWineProcesses(engine: engine)
        persistentProcess = nil
        state = .idle
    }

    /// Aggressive kill of all Wine processes in the prefix. Used before starting
    /// a fresh steam.exe and during termination cleanup.
    func killAllWineProcesses(engine: WineEngine) {
        log.info("[killAll] pkill steam.exe + wineserver -k")
        pkill(["-9", "-f", "steamwebhelper"])
        pkill(["-9", "-f", "steam.exe"])
        usleep(100_000)

        let ws = Process()
        ws.executableURL = engine.wineserverURL
        ws.arguments = ["-k"]
        ws.environment = engine.steamCMDEnvironment(for: prefix)
        ws.standardOutput = FileHandle.nullDevice
        ws.standardError = FileHandle.nullDevice
        try? ws.run()
        ws.waitUntilExit()
        log.info("[killAll] wineserver -k exit=\(ws.terminationStatus)")
    }

    // MARK: - Public API: game install

    /// Install a game using SteamCMD. Requires `isReady == true` (steam.exe running).
    /// Progress callbacks fire on @MainActor.
    func installGame(
        appID: Int,
        name: String,
        installDir: String,
        steamID64: String,
        engine: WineEngine,
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        guard isReady else {
            throw SessionError.steamNotReady
        }

        // Write pre-seeded ACF so Steam knows install location when it receives
        // the download request. Written before SteamCMD runs.
        try prefix.writePreseededAppManifest(
            appID: appID,
            name: name,
            installDir: installDir,
            steamID64: steamID64
        )

        let accountName = AppSettings.shared.steamCredentialAccountName
        guard !accountName.isEmpty else {
            throw SessionError.noCredentials
        }
        guard let password = loadSteamPassword() else {
            throw SessionError.noCredentials
        }

        await onStatus?("Connecting to Steam…")
        try await installViaSteamCMD(
            appID: appID,
            name: name,
            accountName: accountName,
            password: password,
            engine: engine,
            onStatus: onStatus
        )
    }

    /// Cancel a running SteamCMD download.
    func cancelInstall() {
        guard let proc = activeSteamCMDProcess, proc.isRunning else {
            activeSteamCMDProcess = nil
            return
        }
        log.info("[cancelInstall] terminating background SteamCMD pid=\(proc.processIdentifier)")
        proc.terminate()
        activeSteamCMDProcess = nil
    }

    // MARK: - Game launch environment

    /// Returns the environment dictionary for launching a game process.
    /// Merges per-game overrides from GameCompatibilityDB on top of WineEngine defaults.
    func gameEnvironment(for appID: Int, engine: WineEngine) -> [String: String] {
        var env = engine.environment(for: prefix)
        env["WINE_DISABLE_WINE_CRASH_DIALOG"] = "1"

        let compat = GameCompatibilityDB.shared
        for (key, value) in compat.extraEnv(for: appID) {
            env[key] = value
        }
        if let overrides = compat.dllOverrides(for: appID) {
            if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                env["WINEDLLOVERRIDES"] = existing + ";" + overrides
            } else {
                env["WINEDLLOVERRIDES"] = overrides
            }
        }
        if let profile = compat.profile(for: appID) {
            switch profile.dxmtMode {
            case .disabled:
                let disableOverride = "d3d11,dxgi=b"
                if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                    env["WINEDLLOVERRIDES"] = existing + ";" + disableOverride
                } else {
                    env["WINEDLLOVERRIDES"] = disableOverride
                }
            case .required, .auto:
                break
            }
            if profile.graphicsAPI == .dx12,
               let gptk = engine.gptkPath,
               let lib = engine.libraryPath {
                env["WINEDLLPATH"] = "\(gptk)/wine:\(lib)/wine"
                env["WINEDLLOVERRIDES"] = "d3d12=b;dxgi=b"
            }
        }
        return env
    }

    // MARK: - Private: launch steam.exe

    private func launchSteamProcess(engine: WineEngine, extraArgs: [String]) async throws {
        guard persistentProcess == nil || !(persistentProcess?.isRunning ?? false) else {
            log.info("[launchSteamProcess] already running — skipping")
            return
        }

        // Write registry keys for silent/minimized mode before starting.
        await configureSteamRegistry(engine: engine)
        try? await Task.sleep(for: .seconds(2))

        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()
        prefix.clearCrashMarker()

        connectionLogOffset = connectionLogFileSize()

        let steamExePath = prefix.steamExePath.path(percentEncoded: false)
        var args = [steamExePath, "-silent", "-nofriendsui"]
        args.append(contentsOf: extraArgs)

        let sanitized = sanitizeArgsForLog(args)
        log.info("[launchSteamProcess] wine64 \(sanitized.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        persistentProcess = process
        let pid = process.processIdentifier
        log.info("[launchSteamProcess] pid=\(pid)")

        // Register PID with window suppressor immediately for instant hide.
        steamWindow?.registerPID(pid_t(pid))

        // Store paths for TerminationCleanup so wineserver -k works at quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )

        // Drain stderr in background for diagnostics.
        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                let filtered = filterWineStderr(raw)
                let lines = filtered.components(separatedBy: .newlines).prefix(80)
                for line in lines where !line.isEmpty {
                    log.info("[steam.exe:stderr] \(line)")
                }
                if raw.count > 4000 {
                    log.info("[steam.exe:stderr] (truncated \(raw.count) chars)")
                }
            }
            if !process.isRunning {
                log.info("[steam.exe] exited code=\(process.terminationStatus)")
            }
        }
    }

    private func configureSteamRegistry(engine: WineEngine) async {
        let wine64URL = engine.wine64URL
        let env = engine.steamCMDEnvironment(for: prefix)
        await Task.detached(priority: .userInitiated) {
            func reg(_ args: [String]) {
                let p = Process()
                p.executableURL = wine64URL
                p.arguments = args
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
            }
            reg(["reg", "add",
                 "HKCU\\Software\\Valve\\Steam",
                 "/v", "StartMinimized", "/t", "REG_DWORD", "/d", "1", "/f"])
            reg(["reg", "add",
                 "HKCU\\Software\\Valve\\Steam",
                 "/v", "WebProcessCmdLine",
                 "/t", "REG_SZ", "/d", "--no-sandbox --disable-gpu", "/f"])
        }.value
    }

    // MARK: - Private: wait for auth outcome

    /// Wait for `[Logged On, ]` in connection_log.txt.
    /// Returns true on success, false on timeout (state remains unchanged — caller sets it).
    /// Fast-fails immediately on explicit rejection from Valve CM.
    private func waitForLoggedOn(engine: WineEngine, timeout: Duration, authTimeout: Duration) async -> Bool {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)

        let started = ContinuousClock.now
        var connectedAt: ContinuousClock.Instant?
        var poll = 0

        while ContinuousClock.now - started < timeout {
            try? Task.checkCancellation()
            poll += 1

            // If tracked process exited non-42, fail immediately.
            if let p = persistentProcess, !p.isRunning {
                let code = p.terminationStatus
                if code == 42 {
                    // Steam self-update restart — keep waiting.
                    log.info("[waitForLoggedOn] code=42 self-update restart, continuing…")
                    persistentProcess = nil
                } else {
                    log.error("[waitForLoggedOn] steam.exe exited code=\(code)")
                    return false
                }
            }

            let content = readLogTail(path: connLogPath, from: connectionLogOffset)

            if content.contains("[Logged On, ") {
                log.info("[waitForLoggedOn] ✓ Logged On after \(poll) polls")
                killWebhelper()
                return true
            }

            // Fast-fail: Valve explicitly rejected the token.
            if content.contains("LogonFailureReceived")
                || content.contains("Sending SteamServerConnectFailure_t Invalid Password") {
                log.error("[waitForLoggedOn] Valve rejected token — auth failed")
                killWebhelper()
                return false
            }

            if connectedAt == nil, content.contains("Connectivity test: result=Connected") {
                connectedAt = ContinuousClock.now
                log.info("[waitForLoggedOn] Connected — waiting up to \(authTimeout) for Logged On")
            }

            if let ca = connectedAt, ContinuousClock.now - ca > authTimeout {
                log.warning("[waitForLoggedOn] auth timeout after Connected")
                killWebhelper()
                return false
            }

            // Webhelper connect failures = auth rejected.
            let webhelperPath = prefix.steamInstallDir
                .appending(path: "logs/webhelper_js.txt")
                .path(percentEncoded: false)
            let webContent = readLogTail(path: webhelperPath, from: 0)
            let failures = webContent.components(separatedBy: "connect attempt failed").count - 1
            if failures >= 2 {
                log.error("[waitForLoggedOn] webhelper connect failed ×\(failures) — rejecting")
                killWebhelper()
                return false
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        log.warning("[waitForLoggedOn] overall timeout after \(timeout)")
        return false
    }

    private struct SignInOutcome {
        let steamID: String
        let accountName: String
    }

    /// Watch for `[Logged On,]` during user-initiated sign-in.
    /// Throws on explicit rejection or timeout, so the sheet can surface the error.
    private func waitForSignInOutcome(engine: WineEngine, timeout: Duration) async throws -> SignInOutcome {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)

        let started = ContinuousClock.now
        var connectedAt: ContinuousClock.Instant?

        while ContinuousClock.now - started < timeout {
            try Task.checkCancellation()

            if let p = persistentProcess, !p.isRunning {
                let code = p.terminationStatus
                if code == 42 {
                    persistentProcess = nil
                } else {
                    throw SessionError.steamExitedUnexpectedly(code)
                }
            }

            let content = readLogTail(path: connLogPath, from: connectionLogOffset)

            if content.contains("[Logged On, ") {
                killWebhelper()
                if let steamID = extractSteamID(from: content) {
                    log.info("[waitForSignInOutcome] ✓ steamID=\(steamID)")
                    let accountName = AppSettings.shared.steamCredentialAccountName
                    return SignInOutcome(steamID: steamID, accountName: accountName)
                }
                throw SessionError.couldNotExtractSteamID
            }

            if content.contains("LogonFailureReceived")
                || content.contains("Sending SteamServerConnectFailure_t Invalid Password") {
                killWebhelper()
                throw SessionError.authenticationFailed
            }

            // Mobile 2FA was demanded (typed code, not push) — fail fast so user can retry.
            if content.contains("need two-factor code") || content.contains("Two-factor code required") {
                killWebhelper()
                throw SessionError.twoFactorRequired
            }

            if connectedAt == nil, content.contains("Connectivity test: result=Connected") {
                connectedAt = ContinuousClock.now
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        killWebhelper()
        throw SessionError.timeout
    }

    private func extractSteamID(from log: String) -> String? {
        guard let logonRange = log.range(of: "[Logged On, ") else { return nil }
        let after = log[logonRange.upperBound...]
        guard let startIdx = after.range(of: "[U:1:") else { return nil }
        let tail = after[startIdx.upperBound...]
        var accountID: UInt64 = 0
        for ch in tail {
            if let d = ch.hexDigitValue, ch.isNumber {
                accountID = accountID * 10 + UInt64(d)
            } else { break }
        }
        guard accountID > 0 else { return nil }
        return String(accountID + 76561197960265728)
    }

    // MARK: - Private: SteamCMD install

    private func installViaSteamCMD(
        appID: Int,
        name: String,
        accountName: String,
        password: String,
        engine: WineEngine,
        onStatus: (@MainActor (String) -> Void)?
    ) async throws {
        let steamcmdPath = prefix.steamInstallDir
            .appending(path: "steamcmd.exe")
            .path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: steamcmdPath) else {
            log.warning("[steamcmd] steamcmd.exe not found — cannot install via SteamCMD")
            throw SessionError.steamCMDNotFound
        }

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/script")
        // PTY wrapper: SteamCMD only line-buffers when stdout is a TTY.
        // Pattern 3 from engine-research-findings: stdout buffering fixed by /usr/bin/script.
        process.arguments = [
            "-q", "/dev/null",
            engine.wine64URL.path(percentEncoded: false),
            steamcmdPath,
            "-overrideminos",
            "+login", accountName, password,
            "+app_update", "\(appID)", "validate",
            "+quit"
        ]
        process.environment = engine.steamCMDEnvironment(for: prefix)

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError  = outputPipe

        try process.run()
        activeSteamCMDProcess = process
        let pid = process.processIdentifier
        log.info("[steamcmd] launched pid=\(pid) appID=\(appID)")

        let loginTimeout: Duration = .seconds(60)
        let started = ContinuousClock.now
        var loginConfirmed = false
        var lineBuffer = ""
        let handle = outputPipe.fileHandleForReading

        readLoop: while process.isRunning || !lineBuffer.isEmpty {
            if !loginConfirmed, ContinuousClock.now - started > loginTimeout {
                log.warning("[steamcmd] login timeout — terminating")
                process.terminate()
                activeSteamCMDProcess = nil
                throw SessionError.steamCMDLoginFailed
            }

            let fd = handle.fileDescriptor
            let savedFlags = fcntl(fd, F_GETFL)
            if savedFlags >= 0 {
                _ = fcntl(fd, F_SETFL, savedFlags | O_NONBLOCK)
                let chunk = handle.availableData
                _ = fcntl(fd, F_SETFL, savedFlags)
                if !chunk.isEmpty, let str = String(data: chunk, encoding: .utf8) {
                    lineBuffer += str
                }
            }

            while let sep = lineBuffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                let rawLine = String(lineBuffer[lineBuffer.startIndex..<sep])
                lineBuffer = String(lineBuffer[lineBuffer.index(after: sep)...])
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }

                let clean = line.replacingOccurrences(
                    of: #"\x1B\[[0-9;]*[A-Za-z]"#,
                    with: "", options: .regularExpression
                )
                guard !clean.isEmpty else { continue }
                log.info("[steamcmd] \(clean)")

                let isAuthError = clean.contains("Invalid Password")
                    || clean.contains("Two-factor auth failed")
                    || clean.contains("Rate Limit Exceeded")
                    || clean.contains("code required")
                let isConnError = clean.contains("No connection")
                    || clean.contains("Failed to load Steam")
                if isAuthError || isConnError {
                    log.warning("[steamcmd] fail-fast: \(clean)")
                    process.terminate()
                    activeSteamCMDProcess = nil
                    throw SessionError.steamCMDLoginFailed
                }

                if !loginConfirmed, clean.contains("Logged in OK") {
                    loginConfirmed = true
                    log.info("[steamcmd] logged in ✓ appID=\(appID)")
                    await onStatus?("Downloading \(name)…")
                }

                if loginConfirmed,
                   clean.contains("Update state (0x"), clean.contains("downloading") {
                    log.info("[steamcmd] download started — handing off to ACF polling")
                    return
                }

                if clean.contains("Success! App") {
                    log.info("[steamcmd] download complete appID=\(appID)")
                    activeSteamCMDProcess = nil
                    return
                }
            }

            if !process.isRunning { break readLoop }
            try? await Task.sleep(for: .milliseconds(200))
        }

        activeSteamCMDProcess = nil
        let exitCode = process.terminationStatus
        if !loginConfirmed || exitCode != 0 {
            throw SessionError.steamCMDLoginFailed
        }
    }

    // MARK: - Private: helpers

    private func connectionLogFileSize() -> Int {
        let path = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    private func readLogTail(path: String, from offset: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return "" }
        try? fh.seek(toOffset: UInt64(offset))
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func truncateLogs() {
        let dir = prefix.steamInstallDir.appending(path: "logs")
        for name in ["connection_log.txt", "steamui_login.txt"] {
            let path = dir.appending(path: name).path(percentEncoded: false)
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func killWebhelper() {
        pkill(["-9", "-f", "steamwebhelper"])
    }

    private func loadSteamPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: "com.meridian.app",
            kSecAttrAccount as String: "meridian.steam.password",
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func pkill(_ args: [String]) -> Int32 {
        let t = Process()
        t.executableURL = URL(filePath: "/usr/bin/pkill")
        t.arguments = args
        t.standardOutput = FileHandle.nullDevice
        t.standardError  = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        return t.terminationStatus
    }

    private func sanitizeArgsForLog(_ args: [String]) -> [String] {
        var result = args
        for i in 0..<result.count {
            if (result[i] == "-login" || result[i] == "-password") && i + 2 < result.count {
                result[i + 2] = "<redacted>"
            }
        }
        return result
    }
}

// MARK: - Errors

enum SessionError: LocalizedError {
    case alreadyActive
    case steamNotReady
    case steamLaunchFailed(String)
    case steamExitedUnexpectedly(Int32)
    case authenticationFailed
    case twoFactorRequired
    case timeout
    case couldNotExtractSteamID
    case noCredentials
    case steamCMDNotFound
    case steamCMDLoginFailed

    var errorDescription: String? {
        switch self {
        case .alreadyActive:
            return "Steam session is already active."
        case .steamNotReady:
            return "Steam is not ready. Please sign in first."
        case .steamLaunchFailed(let detail):
            return "Steam failed to start: \(detail)"
        case .steamExitedUnexpectedly(let code):
            return "Steam exited unexpectedly (code \(code))."
        case .authenticationFailed:
            return "Steam authentication failed. Check your username and password."
        case .twoFactorRequired:
            return "Steam requires a two-factor code. Please try again with the code from your Steam Mobile app."
        case .timeout:
            return "Steam sign-in timed out. Check your internet connection and try again."
        case .couldNotExtractSteamID:
            return "Signed in but could not read Steam account ID."
        case .noCredentials:
            return "No saved Steam credentials. Please sign in."
        case .steamCMDNotFound:
            return "SteamCMD not found. Reinstall Meridian or reset the Wine environment."
        case .steamCMDLoginFailed:
            return "SteamCMD login failed. Your password may have changed."
        }
    }
}

// MARK: - Wine stderr filter

/// Filter verbose/noisy Wine debug lines from stderr output.
private func filterWineStderr(_ raw: String) -> String {
    let noisy = [
        "fixme:", "err:cxcompatdb", "CX_ROOT",
        "Task policy set failed",
        "err:ole:start_rpcss",
        "fixme:shcore:SetCurrentProcessExplicitAppUserModelID",
    ]
    return raw.components(separatedBy: .newlines)
        .filter { line in !noisy.contains(where: { line.contains($0) }) }
        .joined(separator: "\n")
}
