import AppKit
import Foundation
import Observation

private let log = MeridianLog(category: "WineSteamManager")

/// Manages the Steam client running inside Wine.
///
/// Responsible for:
///   - Bootstrapping Steam on first run (downloading the full client)
///   - Launching games directly via wine64 (bypassing steam.exe -applaunch)
///   - Starting steam.exe on-demand for DRM games (startSteamForDRM)
///   - Stopping Steam / killing Wine processes
///
/// steam.exe is NOT started at app launch. It is started only
/// on-demand when a game ships steam_api64.dll and needs a live Steam IPC socket for DRM.
@Observable
@MainActor
final class WineSteamManager {

    /// Whether a persistent Steam process is currently running.
    /// True only when steam.exe has been started (DRM game launch or showSteamUI).
    var isRunning: Bool = false

    /// Whether the Wine Steam client has an authenticated user session.
    /// Persisted to UserDefaults so the setup sheet doesn't re-appear after
    /// view lifecycle events (game exit, navigation changes).
    var isSteamLoggedIn: Bool = UserDefaults.standard.bool(forKey: "isSteamLoggedIn") {
        didSet { UserDefaults.standard.set(isSteamLoggedIn, forKey: "isSteamLoggedIn") }
    }

    /// The Steam process started on-demand for DRM games or showSteamUI.
    private var persistentProcess: Process?

    /// When the persistent process was last launched.
    private var persistentLaunchDate: Date?

    /// Byte offset in `logs/connection_log.txt` at the moment `startPersistent` launched
    /// `steam.exe`. `waitUntilReady()` only parses content past this offset so markers
    /// from prior sessions cannot falsely satisfy the ready signal.
    private var persistentConnectionLogOffset: Int = 0

    /// Set by `GameLauncher` while a game is actively running.
    var gameIsRunning: Bool = false

    /// Set by `MeridianApp` so every Wine process launched here can be registered
    /// with the suppressor for immediate window hiding.
    var windowSuppressor: SteamWindowSuppressor?

    // MARK: - Bootstrap

    /// Whether Steam needs its first-run bootstrap.
    ///
    /// `SteamSetup.exe /S` installs only the bootstrapper (~2MB). The full
    /// Steam client (including `steamui.dll`) is downloaded when Steam.exe
    /// runs for the first time.
    func needsBootstrap(prefix: WinePrefix) -> Bool {
        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll")
        let exists = FileManager.default.fileExists(atPath: dllPath.path(percentEncoded: false))
        log.info("[needsBootstrap] steamui.dll exists=\(exists) at \(dllPath.path(percentEncoded: false))")
        return !exists
    }

    /// Runs Steam's own bootstrapper and waits for it to complete the client install.
    ///
    /// CX Wine 11.4 + the Mar 12 2026 `steam.exe` stub can do HTTPS correctly via
    /// WinHTTP against `client-update.steamstatic.com` (CLI-verified April 22 2026:
    /// ~27 MB/s download, full 232 MB client install in ~15s). There is no need for
    /// Meridian to parse Valve's VDF manifest or download `.vz` packages itself — the
    /// bootstrapper does that work reliably and is the canonical source of truth for
    /// the current client version. This also frees Meridian from tracking 32-bit vs
    /// 64-bit manifest drift (Valve now ships `steam_client_win64.installed`).
    ///
    /// Flow:
    ///   1. Ensure bundled stub is current (`BootstrapManager` calls
    ///      `refreshSteamStubFromEngineIfStale()` before this runs).
    ///   2. Ensure `steam.cfg` contains `SteamNoSandbox=1` only. `BootStrapperInhibitAll`
    ///      MUST be absent — with it set, the Mar 12 stub silently exits after
    ///      "Suppressing Steam update" without handing off to steamclient64.dll.
    ///   3. Clear any stale `.crash` marker — otherwise the stub enters a degraded
    ///      crash-recovery path.
    ///   4. Launch `wine64 steam.exe -silent`. The suppressor hides any transient
    ///      UI the stub renders during update so Meridian's splash remains foreground.
    ///   5. Poll `logs/bootstrap_log.txt` for progress lines of the form
    ///      `Downloading update (X of Y KB)...` and forward them via `progress`.
    ///   6. Complete when `steamui.dll` appears in the install dir.
    ///
    /// Fail-fast signals (per `fail-fast.mdc`):
    ///   - Process exit without `steamui.dll` → bootstrap failed.
    ///   - `bootstrap_log.txt` not growing AND no download-complete marker for 90s
    ///     after the most recent update → stuck, abort.
    func bootstrap(engine: WineEngine, prefix: WinePrefix,
                   progress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: dllPath) {
            log.info("[bootstrap] steamui.dll already present — skipping")
            return
        }

        // Wipe any prior session's Wine processes so wineserver state is clean.
        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(1))

        // Pre-flight: steam.cfg must contain SteamNoSandbox=1 only.
        try prefix.ensureSteamCFG()
        // Defence in depth: strip any legacy BootStrapperInhibit that might have
        // been written by old Meridian versions.
        prefix.stripBootStrapperInhibit()
        // Clear the `.crash` marker; otherwise the stub enters recovery mode.
        prefix.clearCrashMarker()

        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let bootstrapLogPath = prefix.steamInstallDir
            .appending(path: "logs/bootstrap_log.txt")
            .path(percentEncoded: false)

        // Record the bootstrap_log byte offset at launch so we only parse *this session's*
        // progress markers. The file accumulates history across runs.
        let logStartOffset = (try? FileManager.default.attributesOfItem(atPath: bootstrapLogPath)[.size] as? Int) ?? 0

        log.info("[bootstrap] launching wine64 \(steamExe) -silent (self-bootstrap)")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamExe, "-silent"]
        process.environment = engine.steamCMDEnvironment(for: prefix)

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            log.error("[bootstrap] failed to launch steam.exe: \(error.localizedDescription)")
            throw SteamError.bootstrapFailed(
                exitCode: -1,
                detail: "Failed to launch steam.exe: \(error.localizedDescription)"
            )
        }

        isRunning = true
        let pid = process.processIdentifier
        log.info("[bootstrap] steam.exe pid=\(pid) — watching \(bootstrapLogPath)")
        windowSuppressor?.registerPID(pid)

        // Stream stderr to the log in the background (don't block the bootstrap loop).
        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return }
            let filtered = filterWineStderr(raw)
            for line in filtered.components(separatedBy: .newlines).prefix(80) where !line.isEmpty {
                log.debug("[bootstrap:stderr] \(line)")
            }
        }

        // Progress/stuck-detect loop. Observable signals from bootstrap_log.txt.
        let maxDuration: Duration = .seconds(900)   // 15-minute hard cap
        let stuckWindow: Duration = .seconds(90)    // no log growth after first line ⇒ stuck
        let started = ContinuousClock.now
        var lastLogSize = logStartOffset
        var lastGrowthAt = ContinuousClock.now
        var sawAnyProgress = false

        while ContinuousClock.now - started < maxDuration {
            // Primary success signal: steamui.dll exists.
            if FileManager.default.fileExists(atPath: dllPath) {
                let elapsed = ContinuousClock.now - started
                log.info("[bootstrap] steamui.dll present — Steam self-bootstrap complete ✓ (\(elapsed))")
                // Bootstrap's steam.exe restarts itself mid-install (CLI-verified:
                // "Update complete, launching Steam..." in bootstrap_log). That
                // relaunched process is untracked by us. Kill everything so
                // `startPersistent()` starts from a clean slate.
                killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(2))
                isRunning = false
                return
            }

            let currentSize = (try? FileManager.default.attributesOfItem(atPath: bootstrapLogPath)[.size] as? Int) ?? 0
            if currentSize > lastLogSize {
                lastGrowthAt = ContinuousClock.now
                sawAnyProgress = true
                // Parse only the new tail since we last checked — bounded work even
                // when bootstrap_log accumulates over many sessions.
                if let fh = try? FileHandle(forReadingFrom: URL(filePath: bootstrapLogPath)) {
                    try? fh.seek(toOffset: UInt64(lastLogSize))
                    let data = (try? fh.readToEnd()) ?? Data()
                    try? fh.close()
                    if let text = String(data: data, encoding: .utf8) {
                        Self.parseBootstrapProgress(text, progress: progress)
                    }
                }
                lastLogSize = currentSize
            }

            if !process.isRunning && !FileManager.default.fileExists(atPath: dllPath) {
                let exitCode = process.terminationStatus
                log.error("[bootstrap] steam.exe exited without steamui.dll (exit=\(exitCode))")
                if let tail = try? String(contentsOfFile: bootstrapLogPath, encoding: .utf8) {
                    log.error("[bootstrap] bootstrap_log.txt tail:\n\(tail.suffix(1500))")
                }
                isRunning = false
                throw SteamError.bootstrapFailed(
                    exitCode: exitCode,
                    detail: "steam.exe exited during self-bootstrap without downloading steamui.dll"
                )
            }

            if sawAnyProgress, ContinuousClock.now - lastGrowthAt > stuckWindow {
                log.error("[bootstrap] stuck-detect: bootstrap_log unchanged for \(stuckWindow) — killing steam.exe")
                process.terminate()
                try? await Task.sleep(for: .seconds(1))
                if process.isRunning { kill(pid, SIGKILL) }
                isRunning = false
                throw SteamError.bootstrapFailed(
                    exitCode: -1,
                    detail: "Steam self-bootstrap stuck: no progress for \(stuckWindow)"
                )
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        process.terminate()
        isRunning = false
        throw SteamError.bootstrapFailed(exitCode: -1, detail: "Steam self-bootstrap exceeded \(maxDuration)")
    }

    /// Parses `bootstrap_log.txt` tail fragments for `Downloading update (X of Y KB)...`
    /// lines and forwards the latest as bytes via the progress callback.
    private static func parseBootstrapProgress(
        _ text: String,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) {
        guard let progress else { return }
        let lines = text.components(separatedBy: .newlines).reversed()
        for line in lines {
            guard line.contains("Downloading update (") else { continue }
            // Extract first two integer groups from the line.
            let nums = line
                .components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)
                .compactMap(Int64.init)
                .filter { $0 > 0 }
            if nums.count >= 2 {
                progress(nums[0] * 1024, nums[1] * 1024)
                return
            }
        }
    }

    // MARK: - Steam IPC Commands

    /// Sends a command to the already-running Steam instance via IPC and waits for the
    /// forwarder process to exit, capturing its stderr and exit code.
    ///
    /// When Steam is alive, launching a second `steam.exe` with any arguments causes
    /// it to detect the running instance via Steam's socket, forward the command, and
    /// exit immediately — no second Steam window appears. This is the same mechanism
    /// used by `-applaunch`.
    ///
    /// We capture stderr and wait for exit so that failures (e.g. "Steam is not running",
    /// connection refused) are visible in logs rather than silently discarded.
    private func sendSteamCommand(_ args: [String], engine: WineEngine, prefix: WinePrefix) throws {
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

        // Register the short-lived IPC forwarder process with the suppressor so any
        // transient window it spawns is hidden immediately.
        windowSuppressor?.registerPID(pid)

        // Wait asynchronously so we don't block the main actor, then log the outcome.
        // The forwarder exits in < 1 second when Steam is running; log any errors.
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

    /// Brings the Steam window to the foreground.
    ///
    /// When a persistent Steam process is already running, sends `-activate` via IPC
    /// to surface its main window. If Steam is not running, starts it in visible mode.
    /// The suppressor is paused first so Steam's windows are not hidden.
    func showSteamUI(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[showSteamUI] showing Steam UI")
        // Pause suppression before doing anything — the polling timer runs every 0.5s and
        // will re-hide Steam windows if suppressionActive is still true.
        windowSuppressor?.allowSteamUITemporarily()

        if isSteamProcessAlive {
            // Persistent Steam is running — use IPC to surface its window.
            log.info("[showSteamUI] persistent Steam alive — sending -activate IPC")
            try? sendSteamCommand(["-activate"], engine: engine, prefix: prefix)
            return
        }

        // No running Steam — start it visibly so the user can see and interact with the UI.
        // Use -noreactlogin to suppress the React login dialog; the ConnectCache
        // session from onboarding auto-logs in without any user interaction.
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-noreactlogin"]
        log.info("[showSteamUI] no persistent Steam — starting: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        Task.detached {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let filtered = filterWineStderr(str)
                if !filtered.isEmpty {
                    log.debug("[showSteamUI] stderr: \(filtered.prefix(500))")
                }
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            log.info("[showSteamUI] Steam started pid=\(pid)")
            // Register with suppressor as a Steam process so its sub-windows are
            // tracked, but suppression is already paused so they won't be hidden.
            windowSuppressor?.registerPID(pid)
        } catch {
            log.error("[showSteamUI] failed to start Steam: \(error.localizedDescription)")
        }
    }

    /// Uninstalls a game by deleting its files directly on disk (no Steam IPC).
    ///
    /// Using Steam's `+app_uninstall` IPC command causes the running Steam instance
    /// to surface its main window, which is not desirable. Deleting the ACF manifest
    /// and game directory directly is silent, instant, and sufficient — Steam treats
    /// a missing ACF as "not installed" and does not auto-reinstall in silent mode.
    ///
    /// File I/O is dispatched on a background thread so the main actor is not blocked
    /// during large directory deletions.
    func uninstallGame(appID: Int, prefix: WinePrefix) async throws {
        log.info("[uninstallGame] deleting game files for appID=\(appID)")

        guard let acfURL = prefix.acfURL(for: appID) else {
            log.info("[uninstallGame] ACF not found in any library — game already uninstalled")
            return
        }

        let libraryRoot = acfURL.deletingLastPathComponent().deletingLastPathComponent()
        let installDirName = prefix.gameInstallDir(appID: appID)

        // Offload potentially large deletes to a background thread.
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Delete game directory first (large, slow).
            if let dirName = installDirName {
                let gameDir = libraryRoot.appending(path: "steamapps/common/\(dirName)")
                let gameDirPath = gameDir.path(percentEncoded: false)
                if fm.fileExists(atPath: gameDirPath) {
                    log.info("[uninstallGame] removing game dir: \(gameDirPath)")
                    try fm.removeItem(at: gameDir)
                    log.info("[uninstallGame] game dir removed ✓")
                }
            }

            // Delete the ACF manifest — this is what isGameInstalled checks.
            let acfPath = acfURL.path(percentEncoded: false)
            log.info("[uninstallGame] removing ACF: \(acfPath)")
            try fm.removeItem(at: acfURL)
            log.info("[uninstallGame] ACF removed ✓")
        }.value

        log.info("[uninstallGame] complete appID=\(appID)")
    }

    // MARK: - Game Launch

    /// Launches a game executable directly via Wine, bypassing steam.exe entirely.
    ///
    /// Used when: SteamCMD downloaded the game files and the game doesn't require
    /// Result of launching a game directly via Wine.
    struct GameLaunchResult {
        let pid: Int32
        let process: Process
    }

    /// Launches a game's main executable directly via Wine, bypassing
    /// Steam DRM validation. Most indie/Unity games work this way.
    @discardableResult
    func launchGameDirectly(
        appID: Int,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws -> GameLaunchResult {
        guard let installDir = prefix.gameInstallDir(appID: appID) else {
            throw SteamError.installFailed("Cannot find install directory for appID \(appID)")
        }

        let gamePath = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDir)")
        let gamePathStr = gamePath.path(percentEncoded: false)

        // Find the main game executable — look for .exe files, prefer the one matching the game name
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: gamePathStr) else {
            throw SteamError.installFailed("Cannot list game directory: \(gamePathStr)")
        }

        let exeFiles = contents.filter { $0.hasSuffix(".exe") }
            .filter { !$0.lowercased().contains("crash") && !$0.lowercased().contains("redist") && !$0.lowercased().contains("unins") }

        guard let mainExe = exeFiles.first(where: { !$0.lowercased().contains("unity") }) ?? exeFiles.first else {
            throw SteamError.installFailed("No game executable found in \(gamePathStr)")
        }

        let exeFullPath = gamePath.appending(path: mainExe).path(percentEncoded: false)
        log.info("[launchGameDirectly] appID=\(appID) exe=\(exeFullPath)")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.currentDirectoryURL = gamePath

        var env = engine.environment(for: prefix)

        // Suppress Wine's crash debugger (winedbg) for all game launches.
        // Without this, any game crash triggers winedbg.exe to auto-attach and show
        // a "program has encountered an error" dialog that users cannot dismiss cleanly.
        // Setting WINE_DISABLE_WINE_CRASH_DIALOG silently terminates crashed processes.
        env["WINE_DISABLE_WINE_CRASH_DIALOG"] = "1"

        let compat = GameCompatibilityDB.shared
        let gameExtraEnv = compat.extraEnv(for: appID)
        for (key, value) in gameExtraEnv {
            env[key] = value
        }
        if let gameOverrides = compat.dllOverrides(for: appID) {
            if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                env["WINEDLLOVERRIDES"] = existing + ";" + gameOverrides
            } else {
                env["WINEDLLOVERRIDES"] = gameOverrides
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
                log.info("[launchGameDirectly] dxmtMode=disabled — forcing Wine builtin d3d11")
            case .required:
                if engine.dxmtPath == nil {
                    log.warning("[launchGameDirectly] dxmtMode=required but DXMT not available")
                }
            case .auto:
                break
            }
            log.info("[launchGameDirectly] graphicsAPI=\(profile.graphicsAPI.rawValue) engine=\(profile.gameEngine.rawValue) status=\(profile.status.rawValue)")
        }

        // D3D12 games: switch WINEDLLPATH from lib/dxmt:lib/wine (DX11 default) to
        // gptk/wine:lib/wine so GPTK's dxgi is found before any DXMT DLL.
        // Without this override, even =b loads DXMT's dxgi from lib/dxmt first,
        // which returns E_NOINTERFACE for IDXGIAdapter4 → NULL deref crash.
        if let profile = compat.profile(for: appID),
           profile.graphicsAPI == .dx12,
           let gptk = engine.gptkPath,
           let lib = engine.libraryPath {
            env["WINEDLLPATH"] = "\(gptk)/wine:\(lib)/wine"
            env["WINEDLLOVERRIDES"] = "d3d12=b;dxgi=b"
            log.info("[launchGameDirectly] D3D12 — WINEDLLPATH routed through gptk/wine (GPTK dxgi/d3d12 before DXMT)")
        }

        process.environment = env
        log.info("[launchGameDirectly] WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        if !gameExtraEnv.isEmpty {
            log.info("[launchGameDirectly] game extraEnv: \(gameExtraEnv)")
        }

        // Build process arguments: exe + any per-game launch args from the compatibility DB
        let gameLaunchArgs = compat.profile(for: appID)?.launchArgs ?? []
        process.arguments = [exeFullPath] + gameLaunchArgs
        if !gameLaunchArgs.isEmpty {
            log.info("[launchGameDirectly] launchArgs: \(gameLaunchArgs.joined(separator: " "))")
        }

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            log.info("[launchGameDirectly] launched pid=\(process.processIdentifier)")
        } catch {
            log.error("[launchGameDirectly] failed: \(error.localizedDescription)")
            throw error
        }

        let pid = process.processIdentifier
        // Do NOT register the game PID with the window suppressor.
        // The suppressor is for hiding Steam/Wine helper windows — registering the
        // game exe here immediately hides the game window before suppression is
        // paused, making it invisible and impossible to bring back via the Dock.

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(40)
                for line in lines where !line.isEmpty {
                    log.info("[launchGameDirectly:stderr] \(line)")
                }
            }
            if !process.isRunning {
                log.info("[launchGameDirectly] exited code=\(process.terminationStatus)")
            }
        }

        return GameLaunchResult(pid: pid, process: process)
    }

    /// Launches a game via `wine64 steam.exe -applaunch APPID`.
    ///
    /// Steam handles its own initialization, login, and game launch in a
    /// single process tree. The parent steam.exe stays alive as the Steam
    /// client — we do NOT wait for it to exit. Game exit is detected by
    /// GameProcess monitoring Wine processes.
    ///
    /// Steam is launched WITHOUT `-silent` so it can show its login window
    /// if the user hasn't authenticated yet. After first login, Steam
    /// remembers credentials and future launches auto-login.
    @discardableResult
    func launchGame(
        appID: Int,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws -> Int32 {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        // -nosteamcloudconfirmation: skips the "Steam Cloud sync conflict" dialog that
        // Steam shows on first launch of games with cloud saves. The dialog requires
        // user interaction; if suppressed without this flag the game never starts.
        // Cloud sync still runs — only the modal confirmation is bypassed.
        let args = [steamExe, "-silent", "-nosteamcloudconfirmation", "-applaunch", "\(appID)"]
        log.info("[launchGame] appID=\(appID) | wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args

        let env = engine.environment(for: prefix)
        process.environment = env
        log.info("[launchGame] WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        log.info("[launchGame] WINEDLLPATH=\(env["WINEDLLPATH"] ?? "unset")")
        log.info("[launchGame] WINEPREFIX=\(env["WINEPREFIX"] ?? "unset")")
        log.info("[launchGame] WINELOADER=\(env["WINELOADER"] ?? "unset")")
        log.debug("[launchGame] DYLD_FALLBACK_LIBRARY_PATH=\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "unset")")
        log.debug("[launchGame] MTL_HUD_ENABLED=\(env["MTL_HUD_ENABLED"] ?? "unset")")

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            log.info("[launchGame] launched pid=\(process.processIdentifier)")
        } catch {
            log.error("[launchGame] failed to launch: \(error.localizedDescription)")
            throw error
        }

        let pid = process.processIdentifier
        // Register the game launcher PID so any Steam "launching" splash window
        // is hidden immediately.
        windowSuppressor?.registerPID(pid)

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(100)
                for line in lines where !line.isEmpty {
                    log.info("[launchGame:stderr] \(line)")
                }
                if stderr.count > 5000 {
                    log.info("[launchGame:stderr] (truncated — \(stderr.count) chars raw, \(filtered.count) chars filtered)")
                }
            } else {
                log.debug("[launchGame:stderr] (empty — process pid=\(pid) produced no stderr)")
            }
            if !process.isRunning {
                log.info("[launchGame] process pid=\(pid) exited with code=\(process.terminationStatus)")
            }
        }

        isRunning = true
        log.info("[launchGame] Steam+game process tree started — monitoring handoff to GameProcess")
        return pid
    }

    // MARK: - Install via pre-seeded appmanifest + Steam restart

    /// Triggers a silent game install by pre-seeding the `appmanifest_<appID>.acf`
    /// in the prefix and bouncing the persistent `steam.exe` so it picks up the
    /// manifest on its next startup scan.
    ///
    /// ## Why not IPC?
    ///
    /// Meridian previously sent `+app_update APPID` via a second `steam.exe`
    /// invocation (IPC forwarder). Steam's GUI client interprets that command
    /// by opening its native "Install — Choose Location" dialog, which requires
    /// a user click to confirm. `SteamWindowSuppressor` hides the dialog, so
    /// the download never actually starts. CLI-verified April 23 2026.
    ///
    /// ## What works instead
    ///
    /// Steam's content manager scans `steamapps/appmanifest_*.acf` exactly once
    /// per login (never again during a running session). Any ACF found with
    /// `StateFlags = 1026` (UpdateRequired | Validating) triggers an automatic
    /// silent download — the same code path Steam uses when it detects a
    /// "broken install" that needs repair. No install dialog, no location
    /// picker, no user interaction required.
    ///
    /// CLI-verified April 23 2026: writing the pre-seeded manifest and
    /// restarting steam.exe downloaded Super Battle Golf (1.8 GB) in 25 s with
    /// zero UI. See `WinePrefix.writePreseededAppManifest` for the ACF format.
    ///
    /// ## Cost
    ///
    /// A `stopPersistent` + `startPersistent` cycle takes ~10-15 s (Steam login
    /// via DPAPI `local.vdf`). This is a one-time cost per install-click and
    /// is user-invisible (covered by "Preparing download…" in the UI). After
    /// the manifest is written, Steam runs the download itself and subsequent
    /// launches pick up where it left off without another restart.
    func installGame(
        appID: Int,
        name: String,
        installDir: String,
        steamID64: String,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws {
        log.info("[installGame] writing pre-seeded appmanifest for appID=\(appID)")
        try prefix.writePreseededAppManifest(
            appID: appID,
            name: name,
            installDir: installDir,
            steamID64: steamID64
        )

        log.info("[installGame] restarting persistent Steam so it picks up the new manifest")
        await stopPersistent(engine: engine, prefix: prefix)
        try await startPersistent(engine: engine, prefix: prefix)
        try await waitUntilReady(prefix: prefix, timeout: .seconds(180))
        if let pid = persistentProcessIdentifier {
            windowSuppressor?.resumeSuppressing(pid: pid)
        }
        log.info("[installGame] persistent steam.exe ready — download starts momentarily (ACF detected at startup)")
    }

    // MARK: - Persistent Steam

    /// Launches Steam in silent mode and keeps it running.
    ///
    /// Before starting, writes `StartMinimized=1` to the Wine registry so Steam
    /// prefers a minimized state — this is a defense-in-depth measure alongside
    /// the `SteamWindowSuppressor`.
    ///
    /// The process stays alive for the app's lifetime so that subsequent
    /// `steam.exe -applaunch` invocations use IPC to the running instance
    /// instead of cold-starting a new one.
    ///
    /// Used on-demand for DRM games (`startSteamForDRM`) and `showSteamUI`.
    func startPersistent(engine: WineEngine, prefix: WinePrefix) async throws {
        guard persistentProcess == nil || !(persistentProcess?.isRunning ?? false) else {
            log.info("[startPersistent] Steam already running — skipping")
            return
        }

        // Write registry key before launching Steam. Runs on a background thread
        // to avoid blocking the main actor with waitUntilExit().
        await configureSteamRegistryForSilentMode(engine: engine, prefix: prefix)

        // Let the wineserver from reg-add drain so the next wine64 launch
        // doesn't collide with a shutting-down server.
        try? await Task.sleep(for: .seconds(2))

        // Pre-flight so every launch is deterministic (per fail-fast.mdc):
        //   - steam.cfg must contain SteamNoSandbox=1 only; any stale
        //     BootStrapperInhibitAll left by old Meridian versions blocks the
        //     Mar 12 stub's steamclient handoff.
        //   - `.crash` marker left by a previous unclean shutdown puts the stub
        //     into a degraded crash-recovery path that prevents auto-login.
        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()
        prefix.clearCrashMarker()

        // Capture connection_log.txt size at launch so waitUntilReady() only
        // considers new content and doesn't false-positive on prior sessions.
        persistentConnectionLogOffset = Self.connectionLogSize(prefix: prefix)

        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-silent", "-nofriendsui"]
        log.info("[startPersistent] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.steamCMDEnvironment(for: prefix)

        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        persistentProcess = process
        persistentLaunchDate = Date()
        isRunning = true
        let pid = process.processIdentifier
        log.info("[startPersistent] pid=\(pid)")

        // Drain stderr in the background so crash reasons are visible in logs.
        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(80)
                for line in lines where !line.isEmpty {
                    log.info("[startPersistent:stderr] \(line)")
                }
                if stderr.count > 4000 {
                    log.info("[startPersistent:stderr] (truncated — \(stderr.count) chars raw, \(filtered.count) chars filtered)")
                }
            }
            if !process.isRunning {
                log.info("[startPersistent] process pid=\(pid) exited with code=\(process.terminationStatus)")
            }
        }

        // Register the PID directly with the suppressor so it can install an
        // AXObserver and hide windows immediately — before auto-discovery fires.
        windowSuppressor?.registerPID(pid)

        // Store paths for TerminationCleanup so wineserver -k can be called at quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )
    }

    /// Writes registry keys required for the silent persistent Steam process.
    ///
    /// Sets:
    ///   - `StartMinimized=1`  — Steam prefers tray-only state; defence-in-depth
    ///     alongside `SteamWindowSuppressor`.
    ///   - `WebProcessCmdLine=--no-sandbox --disable-gpu`  — Steam reads this registry
    ///     value and appends it to the webhelper's Chromium command line. Disabling the
    ///     GPU process prevents CEF from spawning a separate GPU child process, which
    ///     requires graphics primitives that may not be available under Wine.
    ///     `--no-sandbox` is required because Wine cannot emulate Chrome's sandbox.
    private func configureSteamRegistryForSilentMode(engine: WineEngine, prefix: WinePrefix) async {
        let wine64URL = engine.wine64URL
        let env = engine.steamCMDEnvironment(for: prefix)
        await Task.detached(priority: .userInitiated) {
            func run(_ args: [String]) {
                let p = Process()
                p.executableURL = wine64URL
                p.arguments = args
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                log.info("[configureSteam] reg exit=\(p.terminationStatus) args=\(args.suffix(from: 1).joined(separator: " "))")
            }

            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "StartMinimized", "/t", "REG_DWORD", "/d", "1", "/f"])

            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "WebProcessCmdLine", "/t", "REG_SZ",
                 "/d", "--no-sandbox --disable-gpu", "/f"])

            // Silence the "download complete" system notification + chime that
            // Steam plays when a game finishes downloading. These keys match
            // Steam's toggles in `Settings → Interface → Notifications` and
            // `Settings → Interface → Sounds` — writing them here pre-empts the
            // user having to dig through hidden Steam settings. Meridian owns
            // all user-facing notifications; Steam's parallel UI layer would be
            // confusing ("Download Complete" + Steam logo + "ba-doop" chime
            // popping over a Meridian app the user didn't know was Steam).
            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "DesktopNotifications", "/t", "REG_DWORD", "/d", "0", "/f"])
            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "NotifyAvailableGames", "/t", "REG_DWORD", "/d", "0", "/f"])
            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "SoundPlayEvents", "/t", "REG_DWORD", "/d", "0", "/f"])
            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "PlayDownloadCompleteSound", "/t", "REG_DWORD", "/d", "0", "/f"])
        }.value

        // Mute notifications + sounds in the user's localconfig.vdf too.
        // Steam reads this file (not the registry) for its HTML5 UI preferences;
        // the registry keys above cover the native-Win32 paths, and localconfig
        // covers the CEF/webhelper paths. Belt + suspenders.
        _ = try? await prefix.writeUserNotificationPreferences(steamID64: AppSettings.shared.steamCredentialSteamID)
    }

    /// Whether the persistent Steam process is still alive.
    var isSteamProcessAlive: Bool {
        persistentProcess?.isRunning ?? false
    }

    /// The macOS process identifier of the persistent Steam wine64 process.
    /// `nil` if no persistent process has been started or if it has exited.
    var persistentProcessIdentifier: pid_t? {
        guard persistentProcess?.isRunning == true else { return nil }
        return persistentProcess?.processIdentifier
    }

    // MARK: - Persistent Process Helpers

    /// Clears the persistent process reference after an intentional kill.
    /// Without this, `startPersistent` sees the dead process still referenced
    /// and skips the launch.
    func clearPersistentProcess() {
        persistentProcess = nil
        isRunning = false
        log.debug("[startPersistent] process reference cleared")
    }

    /// Waits until the persistent `steam.exe` process has reached the authenticated
    /// ready state, using observable signals from Steam's own logs (per `fail-fast.mdc`).
    ///
    /// Two observable signals gate success:
    ///   1. **`Connectivity test: result=Connected`** in `logs/connection_log.txt` —
    ///      Steam's own "network layer is up" declaration. Necessary but not sufficient.
    ///   2. **`[Logged On, `** marker in `logs/connection_log.txt` — Steam's own
    ///      "authenticated session established" declaration. This is what the webhelper,
    ///      install IPC, and game-launch paths all need. Without it, clicking Install
    ///      does nothing and Steam's webhelper shows `Unexpected error (0x3008)` after
    ///      ~30-45s of internal retries.
    ///
    /// Fail-fast signals (all distinctly logged per `fail-fast.mdc` rule #5):
    ///   - Persistent `steam.exe` exits → `SteamError.steamExitedEarly(exit)`
    ///   - `webhelper_js.txt` contains `SteamUI: WARNING: connect attempt failed`
    ///     (≥2 attempts) → fast-fail as `SteamError.authenticationFailed` without waiting
    ///     for the auth timeout. This catches stale-JWT rejection in ~10-15 s instead
    ///     of 60 s.
    ///   - Connected observed but `[Logged On, ` never observed within `authTimeout`
    ///     (default 60 s after Connected) → `SteamError.authenticationFailed`
    ///   - `connection_log.txt` stalls after first growth → `SteamError.steamStuck`
    ///
    /// Secondary progress signal: `Downloading update (X of Y KB)` in
    /// `logs/bootstrap_log.txt` triggers `statusUpdate("Steam is updating…")` so the
    /// splash reflects reality during a first-run self-update.
    ///
    /// - Parameters:
    ///   - timeout: Hard upper bound on the whole wait. Default 180 s.
    ///   - authTimeout: How long after the Connected signal we wait for `[Logged On, `
    ///     before declaring auth failed. Default 60 s (covers normal Steam handshake
    ///     + a small self-update; longer would hide genuine auth rejection).
    ///   - statusUpdate: Optional closure called on the main actor when the splash
    ///     status message should change (e.g. to "Steam is updating…").
    func waitUntilReady(
        prefix: WinePrefix,
        timeout: Duration = .seconds(180),
        authTimeout: Duration = .seconds(60),
        statusUpdate: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)
        let bootstrapLogPath = prefix.steamInstallDir
            .appending(path: "logs/bootstrap_log.txt")
            .path(percentEncoded: false)
        let webhelperJSPath = prefix.steamInstallDir
            .appending(path: "logs/webhelper_js.txt")
            .path(percentEncoded: false)

        let startOffset = persistentConnectionLogOffset
        // Snapshot webhelper_js.txt at launch so we only count THIS session's retries.
        let webhelperStartOffset = Self.fileSize(at: webhelperJSPath)
        // Snapshot bootstrap_log.txt at launch too. Steam's `bootstrap_log.txt` is
        // cumulative — it retains every "Downloading update (...)" line from every
        // prior launch. Without this snapshot, the "Steam is updating…" signal
        // fires spuriously on EVERY subsequent `waitUntilReady` call (e.g. during
        // `installGame`'s Steam restart) because the old line is still in the file.
        // CLI-verified April 23 2026.
        let bootstrapStartOffset = Self.fileSize(at: bootstrapLogPath)
        log.info("[waitUntilReady] watching \(connLogPath) from offset=\(startOffset) (timeout=\(timeout) authTimeout=\(authTimeout))")

        let started = ContinuousClock.now
        let stuckWindow: Duration = .seconds(60)
        var lastConnLogSize = startOffset
        var lastConnGrowthAt = ContinuousClock.now
        var reportedUpdating = false
        var bootstrapLogLastSize = bootstrapStartOffset
        var poll = 0

        var connectedObservedAt: ContinuousClock.Instant?
        var connectedReported = false

        while ContinuousClock.now - started < timeout {
            // Throw CancellationError on task cancellation rather than returning
            // silently — a silent `return` in a `throws` function looks like
            // SUCCESS to the caller, which caused a subtle false-positive "signed
            // in" bug on April 22, 2026 when SwiftUI torn-and-recreated the
            // calling view during a view update. `try Task.checkCancellation()`
            // throws if cancelled, so the caller can distinguish cancel from
            // success.
            try Task.checkCancellation()
            poll += 1

            // Fast exit: tracked process died before we got our signals.
            if let p = persistentProcess, !p.isRunning {
                let exit = p.terminationStatus
                log.error("[waitUntilReady] signal: persistent steam.exe exited (code=\(exit)) — failing fast")
                throw SteamError.steamExitedEarly(exitCode: exit)
            }

            let currentSize = Self.fileSize(at: connLogPath)

            // Read the new tail of connection_log once per poll; reuse for both
            // Connected and Logged On detection.
            var newConnContent = ""
            if currentSize > startOffset,
               let fh = try? FileHandle(forReadingFrom: URL(filePath: connLogPath)) {
                try? fh.seek(toOffset: UInt64(startOffset))
                let data = (try? fh.readToEnd()) ?? Data()
                try? fh.close()
                newConnContent = String(data: data, encoding: .utf8) ?? ""
            }

            // Primary "authenticated" signal.
            if newConnContent.contains("[Logged On, ") {
                let elapsed = ContinuousClock.now - started
                log.info("[waitUntilReady] signal: [Logged On observed after \(poll) polls (\(elapsed)) — Steam fully ready ✓")
                isRunning = true
                return
            }

            // Intermediate "connected" signal — starts the auth-window clock.
            if connectedObservedAt == nil, newConnContent.contains("Connectivity test: result=Connected") {
                connectedObservedAt = ContinuousClock.now
                if !connectedReported {
                    connectedReported = true
                    let elapsed = ContinuousClock.now - started
                    log.info("[waitUntilReady] signal: Connected observed after \(poll) polls (\(elapsed)) — waiting up to \(authTimeout) for Logged On")
                }
            }

            // Fast-fail on webhelper rejecting auth. The webhelper_js.txt log
            // reliably contains `SteamUI: WARNING: connect attempt failed` within
            // ~10-15 s when Steam's stored tokens are invalid. Failing fast avoids
            // the 60 s auth-timeout wait.
            let webhelperSize = Self.fileSize(at: webhelperJSPath)
            if webhelperSize > webhelperStartOffset,
               let fh = try? FileHandle(forReadingFrom: URL(filePath: webhelperJSPath)) {
                try? fh.seek(toOffset: UInt64(webhelperStartOffset))
                let data = (try? fh.readToEnd()) ?? Data()
                try? fh.close()
                if let text = String(data: data, encoding: .utf8) {
                    let attemptFailures = text.components(separatedBy: "SteamUI: WARNING: connect attempt failed").count - 1
                    if attemptFailures >= 2 {
                        log.error("[waitUntilReady] signal: webhelper connect failed ×\(attemptFailures) — auth rejected, failing fast")
                        throw SteamError.authenticationFailed
                    }
                }
            }

            // Auth-window exceeded after Connected — definitive auth failure.
            if let connectedAt = connectedObservedAt,
               ContinuousClock.now - connectedAt > authTimeout {
                log.error("[waitUntilReady] signal: Connected \(authTimeout) ago but Logged On never observed — auth failed")
                throw SteamError.authenticationFailed
            }

            // Secondary progress signal: Steam is downloading an update.
            // Read only bytes APPENDED since this waitUntilReady call started —
            // bootstrap_log.txt is cumulative across sessions, so scanning the
            // whole file would re-fire "Steam is updating…" on every launch that
            // previously saw an update (even when Steam is NOT updating this run).
            if !reportedUpdating {
                let bootstrapSize = Self.fileSize(at: bootstrapLogPath)
                if bootstrapSize > bootstrapLogLastSize {
                    if let fh = try? FileHandle(forReadingFrom: URL(filePath: bootstrapLogPath)) {
                        try? fh.seek(toOffset: UInt64(bootstrapLogLastSize))
                        let data = (try? fh.readToEnd()) ?? Data()
                        try? fh.close()
                        bootstrapLogLastSize = bootstrapSize
                        if let tail = String(data: data, encoding: .utf8),
                           tail.contains("Downloading update (") {
                            reportedUpdating = true
                            log.info("[waitUntilReady] signal: Steam is downloading an update")
                            statusUpdate?("Steam is updating…")
                        }
                    }
                }
            }

            // Stuck-detect (safety net) — only armed after connection_log has grown
            // at least once so we don't false-fire while Steam is still cold-starting.
            if currentSize != lastConnLogSize {
                lastConnLogSize = currentSize
                lastConnGrowthAt = ContinuousClock.now
            } else if lastConnLogSize > startOffset,
                      ContinuousClock.now - lastConnGrowthAt > stuckWindow {
                log.error("[waitUntilReady] stuck-detect: connection_log unchanged for \(stuckWindow) — Steam not progressing")
                throw SteamError.steamStuck
            }

            if poll % 10 == 0 {
                let elapsed = ContinuousClock.now - started
                let sinceConnected = connectedObservedAt.map { "\(ContinuousClock.now - $0)" } ?? "n/a"
                log.info("[waitUntilReady] poll=\(poll) elapsed=\(elapsed) connLogBytes=\(currentSize - startOffset) sinceConnected=\(sinceConnected) updating=\(reportedUpdating)")
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        log.error("[waitUntilReady] TIMEOUT — \(timeout) exceeded (connected=\(connectedObservedAt != nil))")
        throw connectedObservedAt == nil ? SteamError.steamNotReady : SteamError.authenticationFailed
    }

    /// Byte size of `logs/connection_log.txt`, or 0 if the file does not exist yet.
    private static func connectionLogSize(prefix: WinePrefix) -> Int {
        let p = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)
        return fileSize(at: p)
    }

    private static func fileSize(at path: String) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    }

    /// Gracefully shuts down the persistent Steam process and **waits until the
    /// process has actually exited** before returning.
    ///
    /// Previously this method sent `-shutdown` and slept a fixed 3 s, which is
    /// shorter than Steam's real shutdown time (Steam takes ~5–10 s to flush
    /// caches, tear down CM connections, and write tokens). A second steam.exe
    /// launched during that gap detects the still-running old instance via
    /// Wine's registry / IPC state, forwards its args as a "second instance",
    /// and exits with code 0 in under a second — surfacing to the caller as
    /// `SteamError.steamExitedEarly(exitCode: 0)`.
    ///
    /// CLI-verified against the live connection_log.txt on April 23 2026:
    /// original Steam received `LogOff()` 5 s after the `-shutdown` signal and
    /// wrote `Log session ended` 7 s after that — a full 12 s after our
    /// `-shutdown` command returned, which was when the new steam.exe had
    /// already given up and exited.
    ///
    /// Fix: track the actual `persistentProcess` handle and poll `isRunning`
    /// until false, with a 15 s hard cap and an SIGTERM fallback if Steam
    /// refuses to exit cleanly. 15 s is 2× the observed P99 shutdown time and
    /// is still comfortably under the install UI's overall timeout budget.
    func stopPersistent(engine: WineEngine, prefix: WinePrefix) async {
        guard let process = persistentProcess, process.isRunning else {
            log.info("[stopPersistent] no persistent process running")
            persistentProcess = nil
            return
        }

        log.info("[stopPersistent] sending -shutdown")
        await stop(engine: engine, prefix: prefix)

        // Block until the tracked process actually exits — NOT just 3 seconds
        // after the shutdown command. See the doc comment above for the race
        // this prevents.
        let deadline = ContinuousClock.now + .seconds(15)
        var waitedMs = 0
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            waitedMs += 250
        }

        if process.isRunning {
            log.warning("[stopPersistent] Steam still alive after 15s — force-terminating")
            process.terminate()
            // Give SIGTERM a second to land, then give up — the caller will
            // handle the fallout (typically via `killAll` at a higher layer).
            try? await Task.sleep(for: .seconds(1))
        } else {
            log.info("[stopPersistent] Steam fully exited after \(waitedMs)ms")
        }

        persistentProcess = nil
    }


    // MARK: - Process Control

    /// Stops the Steam client gracefully, then falls back to SIGTERM.
    func stop(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[stop] sending -shutdown to Steam")
        let shutdownProcess = Process()
        shutdownProcess.executableURL = engine.wine64URL
        shutdownProcess.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
        shutdownProcess.environment = engine.steamCMDEnvironment(for: prefix)

        let errPipe = Pipe()
        shutdownProcess.standardOutput = FileHandle.nullDevice
        shutdownProcess.standardError = errPipe

        do {
            // Use terminationHandler + continuation so the async task suspends
            // rather than blocking a cooperative thread pool thread.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                shutdownProcess.terminationHandler = { _ in cont.resume() }
                do {
                    try shutdownProcess.run()
                } catch {
                    shutdownProcess.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[stop] shutdown exit=\(shutdownProcess.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[stop] shutdown stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[stop] failed to run -shutdown: \(error.localizedDescription)")
        }

        try? await Task.sleep(for: .seconds(3))
        isRunning = false
        log.info("[stop] Steam stopped")
    }

    /// Kills the Wine server for the prefix, terminating all Wine processes.
    func killAll(engine: WineEngine, prefix: WinePrefix) {
        log.info("[killAll] sending wineserver -k")
        let process = Process()
        process.executableURL = engine.wineserverURL
        process.arguments = ["-k"]
        process.environment = engine.steamCMDEnvironment(for: prefix)

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[killAll] wineserver -k exit=\(process.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[killAll] stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[killAll] failed to run wineserver -k: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: - Errors

    enum SteamError: LocalizedError {
        case bootstrapFailed(exitCode: Int32, detail: String)
        case steamNotReady
        case steamExitedEarly(exitCode: Int32)
        case steamStuck
        case authenticationFailed
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .bootstrapFailed(let code, let detail):
                return "Steam bootstrap failed (exit \(code)): \(detail)"
            case .steamNotReady:
                return "Steam could not start. Try resetting the Wine environment in Settings, or restart Meridian."
            case .steamExitedEarly(let code):
                return "Steam exited before connecting (exit \(code)). Try restarting Meridian; if it persists, reset the Wine environment in Settings."
            case .steamStuck:
                return "Steam is stuck during startup. Try restarting Meridian; if it persists, reset the Wine environment in Settings."
            case .authenticationFailed:
                return "Steam could not sign in with the saved session. Please sign in again."
            case .installFailed(let detail):
                return "Install failed: \(detail)"
            }
        }
    }
}

// MARK: - Stderr filtering

/// Strips MoltenVK's verbose Vulkan extension dump from Wine stderr output.
///
/// Every Wine launch on macOS emits ~6200 chars of `[mvk-info]` + Vulkan extension
/// listings before any real output. The old 2000-char truncation silently discarded
/// every Wine error message that appeared after the MoltenVK dump. This filter
/// removes the noise so diagnostically useful lines are always captured.
private func filterWineStderr(_ raw: String) -> String {
    raw
        .components(separatedBy: .newlines)
        .filter { line in
            !line.hasPrefix("\tVK_")                           // Vulkan extension list
            && !line.hasPrefix("[mvk-info]")                   // MoltenVK info block
            && !line.contains("Vulkan extensions are supported") // count header line
            && !line.hasPrefix("\t[mvk-")                      // nested mvk blocks
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
