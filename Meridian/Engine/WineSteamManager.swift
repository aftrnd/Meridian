import AppKit
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "WineSteamManager")

/// Manages the Steam client running inside Wine.
///
/// Responsible for:
///   - Bootstrapping Steam on first run (downloading the full client)
///   - Running a persistent Steam process for near-instant game launches
///   - Launching games via steam.exe -applaunch (IPC to running instance)
///   - Stopping Steam / killing Wine processes
@Observable
@MainActor
final class WineSteamManager {

    private(set) var isRunning: Bool = false

    /// The long-lived Steam process started at app launch.
    private var persistentProcess: Process?

    /// Called after the health monitor automatically restarts a dead Steam process.
    /// Set by `BootstrapManager` so `SteamWindowSuppressor` can re-engage.
    var onSteamRevived: (@MainActor () -> Void)?

    /// Background task that polls process liveness and restarts Steam if it dies.
    private var healthMonitorTask: Task<Void, Never>?

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

    /// Runs Steam non-silently to complete the first-run client download.
    ///
    /// Launches Steam.exe without `-silent` so it can show its update UI
    /// and download the full client (~150MB). Waits for `steamui.dll` to
    /// appear on disk, then shuts Steam down.
    /// Runs Steam to complete the first-run client download.
    ///
    /// Steam's update pipeline has two observable phases under Wine:
    ///   1. **Download** — Steam writes ~150 MB of `.zip` packages into its
    ///      `package/` subdirectory. The progress bar is determinate.
    ///   2. **Apply (stuck)** — Steam enters an indeterminate "applying update"
    ///      phase (blue bar cycling left-to-right). Under Wine this phase never
    ///      completes; Steam does not write `steamui.dll` until relaunched.
    ///
    /// We detect phase transition by watching the `package/` directory size.
    /// Once it stops growing for `quiescenceWindow` seconds the download is
    /// done. We then kill Steam and relaunch — the next run finds the cached
    /// packages, extracts them in seconds, and writes `steamui.dll`.
    func bootstrap(engine: WineEngine, prefix: WinePrefix) async throws {
        // Kill any stale processes from a prior attempt to avoid wineserver conflicts.
        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        let steamExe  = prefix.steamExePath.path(percentEncoded: false)
        let dllPath   = prefix.steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        let pkgDirURL = prefix.steamInstallDir.appending(path: "package")
        let maxLaunches = 4
        // Hard backstop — should never be reached when quiescence detection works.
        let launchTimeout: Duration = .seconds(600)
        // How long the package dir must be size-stable before we declare download done.
        let quiescenceWindow: Duration = .seconds(25)

        for launchNum in 1...maxLaunches {
            // dll may already be present if a prior launch wrote it just before exiting.
            if FileManager.default.fileExists(atPath: dllPath) {
                log.info("[bootstrap] steamui.dll already present at start of launch \(launchNum) — done")
                break
            }

            if launchNum > 1 {
                log.info("[bootstrap] re-launching Steam (attempt \(launchNum)/\(maxLaunches))")
                killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(3))
            }

            log.info("[bootstrap] launching Steam (attempt \(launchNum)/\(maxLaunches))")
            // -silent: run without showing any Steam windows — the update downloads
            // and applies entirely in the background, invisible to the user.
            let args = [steamExe, "-silent", "-allosarches", "+@AllowSkipGameUpdate", "1"]
            log.info("[bootstrap] wine64 \(args.joined(separator: " "))")

            let process = Process()
            process.executableURL = engine.wine64URL
            process.arguments = args
            process.environment = engine.environment(for: prefix)

            let errPipe = Pipe()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                log.error("[bootstrap] failed to launch Steam on attempt \(launchNum): \(error.localizedDescription)")
                if launchNum == maxLaunches { throw error }
                continue
            }

            isRunning = true
            log.info("[bootstrap] Steam started pid=\(process.processIdentifier) attempt=\(launchNum)/\(maxLaunches)")
            // Register the bootstrap PID so the suppressor hides any windows
            // Steam creates while downloading its initial client packages.
            windowSuppressor?.registerPID(process.processIdentifier)
            log.info("[bootstrap] waiting for steamui.dll — watching package/ dir for download completion")

            let started = ContinuousClock.now
            var pollCount = 0
            var dllFound  = false
            var steamExited = false

            // Package-dir quiescence state
            var lastPackageSize: Int = -1
            var packageSizeStableAt: ContinuousClock.Instant? = nil

            pollLoop: while ContinuousClock.now - started < launchTimeout {
                pollCount += 1

                if FileManager.default.fileExists(atPath: dllPath) {
                    let elapsed = ContinuousClock.now - started
                    log.info("[bootstrap] steamui.dll found after \(pollCount) polls (\(elapsed)) — attempt \(launchNum)")
                    dllFound = true
                    break pollLoop
                }

                if !process.isRunning {
                    // Steam may have self-restarted (new steam.exe spawned by update).
                    let restarted = await Task.detached {
                        let t = Process()
                        t.executableURL = URL(filePath: "/usr/bin/pgrep")
                        t.arguments = ["-f", "steam.exe"]
                        t.standardOutput = FileHandle.nullDevice
                        t.standardError = FileHandle.nullDevice
                        try? t.run(); t.waitUntilExit()
                        return t.terminationStatus == 0
                    }.value

                    if restarted {
                        log.info("[bootstrap] Steam self-restarted — continuing poll")
                        try? await Task.sleep(for: .seconds(3))
                        continue
                    }

                    // No Steam process at all — give a 10s grace period before giving up.
                    let exitCode = process.terminationStatus
                    log.info("[bootstrap] Steam exited (exit=\(exitCode)) on attempt \(launchNum) — 10s grace period")
                    try? await Task.sleep(for: .seconds(10))

                    if FileManager.default.fileExists(atPath: dllPath) {
                        log.info("[bootstrap] steamui.dll appeared during grace period — attempt \(launchNum) OK")
                        dllFound = true
                        break pollLoop
                    }

                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    log.error("[bootstrap] Steam exited without steamui.dll on attempt \(launchNum) (exit=\(exitCode))")
                    if !stderr.isEmpty { log.error("[bootstrap] stderr: \(stderr.prefix(2000))") }

                    steamExited = true
                    break pollLoop
                }

                // --- Package directory quiescence detection ---
                // Steam writes update packages to package/ during the download phase.
                // Once those files stop growing, the download is complete and Steam
                // enters the "apply" phase — which hangs under Wine indefinitely.
                // Detecting size stability lets us restart without any fixed timeout.
                let currentPackageSize: Int = {
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: pkgDirURL,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: .skipsHiddenFiles
                    ) else { return 0 }
                    return children.reduce(0) {
                        $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }()

                if currentPackageSize != lastPackageSize {
                    if lastPackageSize > 0 {
                        log.debug("[bootstrap] package dir: \(lastPackageSize) → \(currentPackageSize) bytes")
                    }
                    lastPackageSize = currentPackageSize
                    packageSizeStableAt = nil
                } else if currentPackageSize > 0 {
                    if packageSizeStableAt == nil {
                        packageSizeStableAt = ContinuousClock.now
                        log.info("[bootstrap] package dir stable at \(currentPackageSize) bytes — quiescence timer started")
                    } else if let stableAt = packageSizeStableAt,
                              ContinuousClock.now - stableAt >= quiescenceWindow {
                        let elapsed = ContinuousClock.now - started
                        log.info("[bootstrap] package dir quiescent for \(quiescenceWindow) (\(elapsed) total) — download done, Steam stuck in apply phase — restarting")
                        break pollLoop
                    }
                }

                if pollCount % 5 == 0 {
                    let elapsed = ContinuousClock.now - started
                    let stableFor = packageSizeStableAt.map { ContinuousClock.now - $0 }
                    log.info("[bootstrap] poll=\(pollCount) elapsed=\(elapsed) pkg=\(currentPackageSize)b stable=\(String(describing: stableFor))")
                }

                try? await Task.sleep(for: .seconds(3))
            }

            if dllFound { break }

            if !steamExited {
                log.info("[bootstrap] killing all Wine processes before retry \(launchNum + 1)")
                killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(3))
            }

            if launchNum == maxLaunches {
                isRunning = false
                throw SteamError.bootstrapFailed(
                    exitCode: -1,
                    detail: "Steam did not complete first-run update after \(maxLaunches) attempts"
                )
            }

            log.info("[bootstrap] attempt \(launchNum) ended without dll — will retry")
        }

        guard FileManager.default.fileExists(atPath: dllPath) else {
            isRunning = false
            throw SteamError.bootstrapFailed(exitCode: -1, detail: "steamui.dll missing after bootstrap loop")
        }

        log.info("[bootstrap] bootstrap succeeded — shutting down Steam")
        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        isRunning = false
        log.info("[bootstrap] Steam bootstrap complete ✓")
    }

    // MARK: - Steam IPC Commands

    /// Sends a fire-and-forget command to the already-running Steam instance via IPC.
    ///
    /// When Steam is alive, launching a second `steam.exe` with any arguments causes
    /// it to detect the running instance via Steam's socket, forward the command, and
    /// exit immediately — no second Steam window appears. This is the same mechanism
    /// used by `-applaunch`. stdout/stderr are discarded because the forwarder process
    /// has nothing useful to say.
    private func sendSteamCommand(_ args: [String], engine: WineEngine, prefix: WinePrefix) throws {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamExe] + args
        process.environment = engine.environment(for: prefix)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        log.info("[sendSteamCommand] sent \(args.joined(separator: " ")) via IPC pid=\(process.processIdentifier)")
        // Register the short-lived IPC forwarder process. The suppressor will clean
        // up its observer automatically once the process exits.
        windowSuppressor?.registerPID(process.processIdentifier)
    }

    /// Queues a silent install of `appID` in the already-running Steam client.
    /// Steam downloads and installs the game to its default library without showing any dialog.
    func installGame(appID: Int, engine: WineEngine, prefix: WinePrefix) throws {
        log.info("[installGame] queuing install appID=\(appID)")
        try sendSteamCommand(["+app_install", "\(appID)"], engine: engine, prefix: prefix)
    }

    /// Brings the running Steam window to the foreground.
    /// Sends `-activate` via IPC, which tells the running Steam instance to
    /// surface its main window without launching a second Steam process.
    func showSteamUI(engine: WineEngine, prefix: WinePrefix) throws {
        log.info("[showSteamUI] activating Steam window")
        try sendSteamCommand(["-activate"], engine: engine, prefix: prefix)
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
                let lines = stderr.components(separatedBy: .newlines).prefix(100)
                for line in lines where !line.isEmpty {
                    log.info("[launchGame:stderr] \(line)")
                }
                if stderr.count > 5000 {
                    log.info("[launchGame:stderr] (truncated — \(stderr.count) chars total)")
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

    // MARK: - Persistent Steam

    /// Launches Steam in silent mode and keeps it running.
    ///
    /// Before starting, writes `StartMinimized=1` to the Wine registry so Steam
    /// prefers a minimized state — this is a defense-in-depth measure alongside
    /// the `SteamWindowSuppressor`.
    ///
    /// The process stays alive for the app's lifetime so that subsequent
    /// `steam.exe -applaunch` invocations use IPC to the running instance
    /// instead of cold-starting a new one. Also starts the health monitor.
    func startPersistent(engine: WineEngine, prefix: WinePrefix) async throws {
        guard persistentProcess == nil || !(persistentProcess?.isRunning ?? false) else {
            log.info("[startPersistent] Steam already running — skipping")
            return
        }

        // Write registry key before launching Steam. Runs on a background thread
        // to avoid blocking the main actor with waitUntilExit().
        await configureSteamRegistryForSilentMode(engine: engine, prefix: prefix)

        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        // -nofriendsui suppresses the Friends List popup that Steam can surface
        // when processing IPC commands.
        let args = [steamExe, "-silent", "-nofriendsui"]
        log.info("[startPersistent] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        persistentProcess = process
        isRunning = true
        log.info("[startPersistent] pid=\(process.processIdentifier)")

        // Register the PID directly with the suppressor so it can install an
        // AXObserver and hide windows immediately — before auto-discovery fires.
        let pid = process.processIdentifier
        windowSuppressor?.registerPID(pid)

        // Store paths for TerminationCleanup so wineserver -k can be called at quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false)
        )

        // Start the health monitor so automatic restarts keep Steam alive silently.
        startHealthMonitor(engine: engine, prefix: prefix)
    }

    /// Writes `StartMinimized=1` to the Wine registry for the Steam key.
    ///
    /// This tells Steam to prefer a minimized/tray-only state at startup,
    /// reducing how eagerly it surfaces its main window. Runs the `reg add`
    /// command on a background thread so the main actor is not blocked.
    private func configureSteamRegistryForSilentMode(engine: WineEngine, prefix: WinePrefix) async {
        // Capture main-actor-isolated values before switching to background thread.
        let wine64URL = engine.wine64URL
        let env = engine.environment(for: prefix)
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = wine64URL
            process.arguments = [
                "reg", "add", "HKCU\\Software\\Valve\\Steam",
                "/v", "StartMinimized", "/t", "REG_DWORD", "/d", "1", "/f"
            ]
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            log.info("[configureSteam] StartMinimized=1 written (exit=\(process.terminationStatus))")
        }.value
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

    // MARK: - Health Monitor

    /// Polls the persistent Steam process every 30 seconds and silently restarts it
    /// if it has died (e.g. user quit from the Dock, OOM kill, crash).
    ///
    /// After restart, `onSteamRevived` is called so `SteamWindowSuppressor` can
    /// re-engage window suppression for the new process PID.
    private func startHealthMonitor(engine: WineEngine, prefix: WinePrefix) {
        healthMonitorTask?.cancel()
        healthMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                // 10s interval keeps the dead-Steam window small. At 30s a user action
                // (install IPC, play) could cold-start Steam without -silent, surfacing
                // its full UI before the monitor has a chance to revive it silently.
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { break }

                if !isSteamProcessAlive {
                    log.warning("[healthMonitor] persistent Steam process died — restarting silently")
                    do {
                        try await self.startPersistent(engine: engine, prefix: prefix)
                        log.info("[healthMonitor] Steam restarted (pid=\(self.persistentProcessIdentifier.map(String.init) ?? "nil"))")
                        onSteamRevived?()
                    } catch {
                        log.error("[healthMonitor] restart failed: \(error.localizedDescription)")
                    }
                }
            }
            log.info("[healthMonitor] stopped")
        }
        log.info("[healthMonitor] started")
    }

    /// Polls until Steam is confirmed ready using multiple signals.
    ///
    /// Checks three indicators each poll cycle:
    ///   1. **wineserver** is running (Wine IPC layer operational)
    ///   2. **steam.exe** processes exist (Steam client is alive)
    ///   3. **steam.pid** file exists in the Steam install dir (Steam IPC ready)
    ///
    /// Additionally waits for Steam's `package/` directory to quiesce (stop
    /// growing). The persistent Steam process self-updates on first launch after
    /// bootstrap, writing ~150 MB of packages before applying them. Without this
    /// check, the library opens while the Steam updater dialog is still on screen.
    ///
    /// On subsequent launches where no update is needed, the package dir is
    /// already stable and this check adds no delay.
    ///
    /// - Parameter statusUpdate: Optional closure called on the main actor when
    ///   the status message should change (e.g. to "Steam is updating…").
    func waitUntilReady(
        prefix: WinePrefix,
        timeout: Duration = .seconds(180),
        statusUpdate: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let started = ContinuousClock.now
        var attempt = 0
        var consecutiveReady = 0
        let steamPidPath = prefix.steamInstallDir.appending(path: "steam.pid").path(percentEncoded: false)
        let pkgDirURL = prefix.steamInstallDir.appending(path: "package")

        // Package-dir quiescence state
        // Give Steam a 10-second head start so we don't falsely declare "stable"
        // before it has even begun downloading a self-update.
        let quiescenceHeadStart: Duration = .seconds(10)
        let quiescenceWindow: Duration = .seconds(20)
        var lastPackageSize: Int = -1
        var packageSizeStableAt: ContinuousClock.Instant? = nil
        var packageIsQuiescent = false
        var reportedUpdating = false

        log.info("[waitUntilReady] multi-signal + pkg-quiescence check (timeout=\(timeout))")
        log.info("[waitUntilReady] steam.pid path=\(steamPidPath)")

        while ContinuousClock.now - started < timeout {
            guard !Task.isCancelled else { return }
            attempt += 1

            let signals = await Task.detached { () -> (wineserver: Bool, steamProc: Bool, steamPid: Bool) in
                let wineserver: Bool = {
                    let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
                    t.arguments = ["-q", "wineserver"]
                    t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
                    try? t.run(); t.waitUntilExit()
                    return t.terminationStatus == 0
                }()

                let steamProc: Bool = {
                    let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
                    t.arguments = ["-f", "steam.exe"]
                    t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
                    try? t.run(); t.waitUntilExit()
                    return t.terminationStatus == 0
                }()

                let steamPid = FileManager.default.fileExists(atPath: steamPidPath)

                return (wineserver, steamProc, steamPid)
            }.value

            // --- Package directory quiescence ---
            // Only begin tracking after the head-start period so we don't declare
            // "stable" before a self-update has started downloading.
            let elapsed = ContinuousClock.now - started
            if elapsed >= quiescenceHeadStart {
                let currentPackageSize: Int = {
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: pkgDirURL,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: .skipsHiddenFiles
                    ) else { return 0 }
                    return children.reduce(0) {
                        $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }()

                if currentPackageSize != lastPackageSize {
                    if lastPackageSize > 0 && currentPackageSize > lastPackageSize {
                        // Package dir is actively growing — Steam is downloading an update.
                        if !reportedUpdating {
                            reportedUpdating = true
                            log.info("[waitUntilReady] Steam is downloading an update (pkg=\(currentPackageSize)b)")
                            if let cb = statusUpdate {
                                await cb("Steam is updating…")
                            }
                        }
                    }
                    lastPackageSize = currentPackageSize
                    packageSizeStableAt = nil
                    packageIsQuiescent = false
                } else {
                    // Size unchanged this poll.
                    if packageSizeStableAt == nil {
                        packageSizeStableAt = ContinuousClock.now
                    }
                    if let stableAt = packageSizeStableAt,
                       ContinuousClock.now - stableAt >= quiescenceWindow {
                        if !packageIsQuiescent {
                            log.info("[waitUntilReady] package dir quiescent at \(currentPackageSize)b — no active update")
                        }
                        packageIsQuiescent = true
                    }
                }
            }

            let allReady = signals.wineserver && signals.steamProc
            let strongReady = allReady && signals.steamPid

            if allReady {
                consecutiveReady += 1
            } else {
                consecutiveReady = 0
            }

            if attempt % 5 == 0 || consecutiveReady > 0 {
                log.info("[waitUntilReady] attempt=\(attempt) | wineserver=\(signals.wineserver) steam.exe=\(signals.steamProc) steam.pid=\(signals.steamPid) | consecutive=\(consecutiveReady) | pkgStable=\(packageIsQuiescent)")
            }

            let requiredConsecutive = strongReady ? 3 : 4
            let processesReady = consecutiveReady >= requiredConsecutive

            // Declare ready only when processes are stable AND no active update.
            // For the quiescence gate: once head-start has elapsed, require
            // packageIsQuiescent. Before head-start, don't gate on it yet.
            let quiescenceGatePassed = elapsed < quiescenceHeadStart || packageIsQuiescent

            if processesReady && quiescenceGatePassed {
                let totalElapsed = ContinuousClock.now - started
                log.info("[waitUntilReady] Steam confirmed ready after \(attempt) polls (\(totalElapsed)) — wineserver=\(signals.wineserver) steam.exe=\(signals.steamProc) steam.pid=\(signals.steamPid)")
                isRunning = true
                return
            }

            try? await Task.sleep(for: .seconds(2))
        }

        log.error("[waitUntilReady] TIMEOUT — Steam not ready after \(timeout)")
        throw SteamError.bootstrapFailed(exitCode: -1, detail: "Timed out waiting for Steam to initialize")
    }

    /// Gracefully shuts down the persistent Steam process.
    func stopPersistent(engine: WineEngine, prefix: WinePrefix) async {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil

        guard persistentProcess?.isRunning ?? false else {
            log.info("[stopPersistent] no persistent process running")
            persistentProcess = nil
            return
        }

        log.info("[stopPersistent] sending -shutdown")
        await stop(engine: engine, prefix: prefix)
        persistentProcess = nil
    }


    // MARK: - Process Control

    /// Stops the Steam client gracefully, then falls back to SIGTERM.
    func stop(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[stop] sending -shutdown to Steam")
        let shutdownProcess = Process()
        shutdownProcess.executableURL = engine.wine64URL
        shutdownProcess.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
        shutdownProcess.environment = engine.environment(for: prefix)

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
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        log.info("[killAll] sending wineserver -k")
        let process = Process()
        process.executableURL = engine.wineserverURL
        process.arguments = ["-k"]
        process.environment = engine.environment(for: prefix)

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

        var errorDescription: String? {
            switch self {
            case .bootstrapFailed(let code, let detail):
                return "Steam bootstrap failed (exit \(code)): \(detail)"
            }
        }
    }
}
