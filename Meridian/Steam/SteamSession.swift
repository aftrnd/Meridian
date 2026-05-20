import AppKit
import Foundation
import Observation

private let log = MeridianLog(category: "SteamSession")

// MARK: - SteamSession

/// Single owner of the steam.exe lifecycle.
///
/// `steam.exe` is ALWAYS launched with `-silent -nofriendsui`. Authentication is
/// handled by `SteamCredentialAuth` (Meridian-side OAuth via Valve's
/// `IAuthenticationService` REST API) which writes the resulting refresh_token
/// into the prefix's `local.vdf` via DPAPI (`WinePrefix.writeSteamSessionLocalVdf`).
/// `-login USER PASS` is NEVER sent — that path produces `persistence: 0` access-
/// only JWTs that Steam refuses to persist, breaking auto-login on every cold
/// start. CLI-verified May 19 2026.
///
/// ## Rules
/// - `start()` is the ONLY way to launch steam.exe — always `-silent`, never -login.
///   Never throws. On auth failure sets `state = .failed` and ContentView
///   surfaces the sign-in sheet (which in turn drives `SteamCredentialAuth`).
/// - `shutdown()` always tears down the full process tree (graceful -shutdown
///   IPC, then `wineserver -k`). Safe to call from anywhere, regardless of
///   tracked state — orphans outside our tracking are cleaned up too.
/// - `installGame()` and game launches refuse to run unless `isReady == true`.
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
        /// Silent auth failed or steam.exe crashed. ContentView shows sign-in sheet.
        case failed(String)
    }

    private(set) var state: State = .idle

    var isReady: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Private state

    private var persistentProcess: Process?
    private var connectionLogOffset: Int = 0
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
            try await launchSteamProcess(engine: engine)
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

    /// Gracefully shut down steam.exe and wait for all Wine processes to exit.
    ///
    /// Always runs the full shutdown sequence regardless of tracked state.
    /// Orphan Wine processes can exist outside our tracking (e.g. after a
    /// code=42 self-update clears persistentProcess), so guarding on
    /// `persistentProcess != nil || isReady` would skip cleanup of real
    /// running processes. CLI-observed May 19 2026.
    func shutdown(engine: WineEngine) async {
        log.info("[shutdown] stopping steam.exe (state=\(String(describing: state)))")
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

        // Always kill — orphan processes can exist outside our tracking.
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

    /// Initiate a game install via Steam IPC. Requires `isReady == true`
    /// (a persistent `steam.exe -silent` process must be running and authenticated).
    ///
    /// The install is driven by the SAME mechanism Steam Desktop uses internally:
    ///
    ///   1. Pre-seed `appmanifest_<appID>.acf` with `StateFlags=1026` ("scheduled
    ///      for download") so Steam knows the install location when it receives
    ///      the IPC command — no install-location picker dialog will ever appear.
    ///   2. Spawn `wine64 steam.exe steam://install/<appID>`. Wine's PE loader
    ///      sees that a Steam instance already owns the IPC named pipe and
    ///      forwards the URL to it instead of cold-starting a second Steam.
    ///      The forwarder process exits in ~1 second.
    ///   3. Steam dispatches the URL to its internal download manager, which
    ///      reads the pre-seeded ACF and starts downloading immediately. No
    ///      restart, no re-auth, no UI.
    ///
    /// Progress is observed by the caller (`Launcher.pollDownloadProgress`) by
    /// reading `BytesDownloaded` / `BytesToDownload` from the ACF manifest.
    ///
    /// SteamCMD is NOT used. Meridian's native bootstrap stages `steam.exe` but
    /// not `steamcmd.exe` (the `steam_cmd_win32` manifest was never wired in),
    /// so SteamCMD-based installs always failed with "steamcmd.exe not found".
    /// IPC works against the already-running, already-authenticated Steam — no
    /// dependency on additional binaries.
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

        // 1. Pre-seed the ACF manifest. StateFlags=1026 means "scheduled for
        //    download" — Steam picks this up on its next library scan or
        //    immediately when the steam://install IPC arrives.
        log.info("[installGame] writing pre-seeded appmanifest for appID=\(appID) name=\"\(name)\"")
        try prefix.writePreseededAppManifest(
            appID: appID,
            name: name,
            installDir: installDir,
            steamID64: steamID64
        )

        // 2. Send the IPC URL. The new wine64 process detects the running Steam
        //    and forwards via named pipe; it exits in ~1s. Steam then starts the
        //    download internally — no observable Steam UI thanks to the
        //    SteamWindow suppressor + pre-seeded ACF (no picker dialog needed).
        onStatus?("Asking Steam to start the download…")
        log.info("[installGame] sending steam://install/\(appID) IPC to running Steam")
        try sendSteamCommand(["steam://install/\(appID)"], engine: engine)
        onStatus?("Downloading \(name)…")
        log.info("[installGame] IPC dispatched — Launcher will poll ACF for progress")
    }

    /// Cancel an in-progress install.
    ///
    /// IPC installs run inside the persistent Steam process, not in a Meridian-
    /// owned subprocess, so there's no local process to kill. `Launcher` handles
    /// the UI side (sets state back to idle, stops polling). If we ever need to
    /// genuinely pause/cancel the running Steam download, the IPC URL is
    /// `steam://pauseDownloads` / `steam://uninstall/<id>` — not implemented yet
    /// because Launcher's cancel is "stop tracking", not "tell Steam to stop".
    func cancelInstall() {
        log.info("[cancelInstall] no-op — IPC installs run inside the persistent Steam process; Launcher handles UI cancellation")
    }

    // MARK: - Private: Steam IPC

    /// Send a command-line argument (or `steam://` URL) to the already-running
    /// Steam instance via the standard Windows-Steam IPC pattern: spawn a new
    /// `steam.exe` with the argument; the new process detects the running
    /// instance's IPC named pipe and forwards instead of cold-starting.
    ///
    /// CLI-verified that this works for `steam://install/<id>` (commit `6501b4f`)
    /// and `-applaunch <id>` (the DRM game launch path).
    private func sendSteamCommand(_ args: [String], engine: WineEngine) throws {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamExe] + args
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier
        log.info("[sendSteamCommand] sent \(args.joined(separator: " ")) via IPC pid=\(pid)")

        // Register the short-lived IPC forwarder with the window suppressor so
        // any transient Wine window it spawns is hidden immediately.
        steamWindow?.registerPID(pid_t(pid))

        // Wait asynchronously so we don't block the main actor, then log the
        // outcome. The forwarder exits in <1s when Steam is already running.
        Task.detached(priority: .utility) {
            process.waitUntilExit()
            let status = process.terminationStatus
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            if status != 0 || !stderr.isEmpty {
                log.warning("[sendSteamCommand] IPC forwarder exited status=\(status) args=\(args.joined(separator: " ")) stderr=\(stderr.prefix(500))")
            } else {
                log.info("[sendSteamCommand] IPC forwarder exited cleanly status=\(status) pid=\(pid)")
            }
        }
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

    private func launchSteamProcess(engine: WineEngine) async throws {
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
        // ALWAYS -silent. Auth comes from the DPAPI-injected local.vdf (written
        // by WinePrefix.writeSteamSessionLocalVdf at sign-in time + on every
        // BootstrapManager cold start from persisted credentials).
        let args = [steamExePath, "-silent", "-nofriendsui"]

        log.info("[launchSteamProcess] wine64 \(args.joined(separator: " "))")

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

    private func killWebhelper() {
        pkill(["-9", "-f", "steamwebhelper"])
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

}

// MARK: - Errors

enum SessionError: LocalizedError {
    case steamNotReady

    var errorDescription: String? {
        switch self {
        case .steamNotReady:
            return "Steam is not ready. Please sign in first."
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
