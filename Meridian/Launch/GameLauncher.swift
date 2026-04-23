import AppKit
import Foundation
import Observation

private let log = MeridianLog(category: "GameLauncher")

/// Orchestrates game launches via Wine + Steam.
///
/// The heavy initialization (prefix, Steam install, bootstrap, session sync,
/// and persistent Steam startup) is handled by `BootstrapManager` at app
/// launch. By the time the user clicks Play, this pipeline only needs to:
///
///   1. Guard that the environment is ready
///   2. Send steam.exe -applaunch to the running Steam instance (via IPC)
///   3. Monitor Wine processes and report exit
@Observable
@MainActor
final class GameLauncher {

    // MARK: - State

    enum LaunchState: Equatable {
        case idle
        case preparingEngine
        case preparingPrefix
        case bootstrappingSteam
        case awaitingInstallConfirmation
        case launching
        case running(appID: Int)
        case stopping(appID: Int)
        case uninstalling
        case exited(appID: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []
    private(set) var currentActivity: String?
    /// Download progress as a fraction 0.0–1.0 while SteamCMD is downloading.
    /// Nil when not actively downloading. Drives the progress bar in GameDetailView.
    private(set) var downloadProgress: Double?
    /// When the full pipeline started — used by the UI to show elapsed time during prep/launch.
    private(set) var pipelineStartDate: Date?
    /// When we transitioned to .running.
    private(set) var runningSince: Date?
    /// The appID currently being launched or running. Nil when idle/exited/failed.
    /// Lets per-game detail views correctly gate active UI to only the game being played.
    private(set) var activeAppID: Int?
    /// True once the monitor loop has confirmed live Wine processes exist after launch.
    /// Stored (not computed) so SwiftUI @Observable tracks it directly.
    private(set) var processesConfirmed: Bool = false

    private let gameProcess = GameProcess()
    private let prefix = WinePrefix.defaultPrefix
    private var launchTask: Task<Void, Never>?

    /// Set by `MeridianApp` so the launch pipeline can pause/resume window suppression
    /// around install and game-process confirmation.
    var windowSuppressor: SteamWindowSuppressor?

    // MARK: - Public API

    func launch(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        // Must be async for stopGame; run in Task if called from sync context
        Task {
            await launchImpl(game: game, engine: engine, steamManager: steamManager, steamAuth: steamAuth, library: library)
        }
    }

    /// Downloads and installs a game without launching it.
    /// When complete the launcher returns to `.idle` and `Game.isInstalled` becomes true.
    func installOnly(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        Task {
            await installOnlyImpl(game: game, engine: engine, steamManager: steamManager, steamAuth: steamAuth, library: library)
        }
    }

    private func launchImpl(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        steamAuth: SteamAuthService?,
        library: SteamLibraryStore?
    ) async {
        switch launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam,
             .awaitingInstallConfirmation, .launching, .stopping, .uninstalling:
            log.warning("[launch] ignoring — already in state \(String(describing: self.launchState))")
            return
        case .running:
            log.info("[launch] currently in .running — stopping previous session before re-launch")
            await gameProcess.stopGame(engine: engine, prefix: prefix)
        case .idle, .exited, .failed:
            break
        }

        launchTask?.cancel()
        launchTask = Task { [weak self] in
            await self?.executeLaunchPipeline(
                game: game,
                engine: engine,
                steamManager: steamManager,
                steamAuth: steamAuth,
                library: library,
                launchAfterInstall: true
            )
        }
    }

    private func installOnlyImpl(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        steamAuth: SteamAuthService?,
        library: SteamLibraryStore?
    ) async {
        switch launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam,
             .awaitingInstallConfirmation, .launching, .stopping, .uninstalling:
            log.warning("[installOnly] ignoring — already in state \(String(describing: self.launchState))")
            return
        case .running:
            log.warning("[installOnly] ignoring — a game is currently running")
            return
        case .idle, .exited, .failed:
            break
        }

        launchTask?.cancel()
        launchTask = Task { [weak self] in
            await self?.executeLaunchPipeline(
                game: game,
                engine: engine,
                steamManager: steamManager,
                steamAuth: steamAuth,
                library: library,
                launchAfterInstall: false
            )
        }
    }

    /// Cancels an in-progress launch. Cleans up any spawned processes.
    func cancelLaunch(engine: WineEngine, steamManager: WineSteamManager) async {
        log.info("[cancelLaunch] cancelling current launch")
        launchTask?.cancel()
        launchTask = nil

        // Install was dispatched to `steam.exe` via IPC; `steam.exe` itself
        // notices when the user cancels from its own UI. We don't try to
        // pre-empt it here — just drop our polling loop and move on.
        steamManager.gameIsRunning = false
        await cleanupProcesses(engine: engine, steamManager: steamManager)

        if let pid = steamManager.persistentProcessIdentifier {
            windowSuppressor?.resumeSuppressing(pid: pid)
        }

        launchState = .idle
        runningSince = nil
        pipelineStartDate = nil
        activeAppID = nil
        currentActivity = nil
        downloadProgress = nil
        processesConfirmed = false
        appendLog("Launch cancelled by user")
    }

    /// Stops the currently running game.
    func stopGame(engine: WineEngine, steamManager: WineSteamManager) async {
        let appID: Int
        switch launchState {
        case .running(let id):
            appID = id
        case .launching:
            appID = activeAppID ?? 0
        default:
            log.warning("[stopGame] not in running/launching state — current=\(String(describing: self.launchState))")
            return
        }
        log.info("[stopGame] stopping appID=\(appID)")
        launchState = .stopping(appID: appID)
        currentActivity = "Stopping game..."
        steamManager.gameIsRunning = false
        await gameProcess.stopGame(engine: engine, prefix: prefix)
        runningSince = nil
        pipelineStartDate = nil
        processesConfirmed = false
        launchState = .exited(appID: appID)
        currentActivity = nil
        downloadProgress = nil
        if let pid = steamManager.persistentProcessIdentifier {
            windowSuppressor?.resumeSuppressing(pid: pid)
        }
        log.info("[stopGame] exited appID=\(appID)")
    }

    /// Uninstalls a game by sending a silent IPC command to Steam, then waiting
    /// for Steam to remove the ACF manifest from disk.
    func uninstall(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        library: SteamLibraryStore?
    ) {
        Task { [weak self] in
            guard let self else { return }

            // Allow uninstall from any quiescent state (idle, exited, or failed).
            // Only block when an active operation is already in flight.
            switch launchState {
            case .idle, .exited, .failed:
                break
            default:
                log.warning("[uninstall] ignoring — launcher busy (state=\(String(describing: self.launchState)))")
                return
            }
            activeAppID = game.id
            transition(to: .uninstalling, activity: "Uninstalling \(game.name)…")

            // Ensure suppression is active before we delete the ACF. Steam monitors
            // its steamapps folder and will surface its library window the moment it
            // detects the ACF disappear. Calling resumeSuppressing/suppressNow here
            // hides any existing Steam windows immediately before that happens.
            if let pid = steamManager.persistentProcessIdentifier {
                windowSuppressor?.resumeSuppressing(pid: pid)
            } else {
                windowSuppressor?.suppressNow()
            }

            do {
                try await steamManager.uninstallGame(appID: game.id, prefix: prefix)
            } catch {
                fail("Failed to uninstall game: \(error.localizedDescription)", error: error)
                activeAppID = nil
                return
            }

            // Poll for ACF removal as a safety net. With direct file deletion the
            // loop exits immediately on the first check since the ACF is already gone.
            let deadline = ContinuousClock.now + .seconds(30)
            while prefix.isGameInstalled(appID: game.id) {
                guard ContinuousClock.now < deadline else {
                    fail("Uninstall timed out. Open Steam to check the status.")
                    activeAppID = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }

            // Brief pause so the "Uninstalling…" label is visible long enough to feel
            // intentional — without it the state flips in under 200ms which is jarring.
            try? await Task.sleep(for: .milliseconds(1500))

            library?.setInstalled(false, for: game.id)
            launchState = .idle
            activeAppID = nil
            log.info("[uninstall] complete appID=\(game.id)")
        }
    }

    /// Kills all Wine processes. Call on app termination or prefix reset.
    func cleanupProcesses(engine: WineEngine, steamManager: WineSteamManager) async {
        log.info("[cleanup] killing all Wine processes")
        steamManager.killAll(engine: engine, prefix: prefix)
        launchState = .idle
        activeAppID = nil
        pipelineStartDate = nil
        runningSince = nil
        currentActivity = nil
        downloadProgress = nil
        processesConfirmed = false
    }

    // MARK: - Launch Pipeline

    private func executeLaunchPipeline(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        steamAuth: SteamAuthService?,
        library: SteamLibraryStore?,
        launchAfterInstall: Bool
    ) async {
        logs.removeAll()
        currentActivity = nil
        downloadProgress = nil
        activeAppID = game.id
        pipelineStartDate = .now
        processesConfirmed = false

        log.info("╔══════════════════════════════════════════════════")
        log.info("║ LAUNCH: appID=\(game.id) '\(game.name)'")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(self.prefix.exists)")
        log.info("║ steam installed=\(self.prefix.isSteamInstalled)")
        log.info("║ steam persistent alive=\(steamManager.isSteamProcessAlive)")
        log.info("║ prefix path=\(self.prefix.path.path(percentEncoded: false))")
        log.info("║ wine64=\(engine.wine64URL.path(percentEncoded: false))")
        log.info("╚══════════════════════════════════════════════════")

        guard engine.isReady else {
            fail("Wine runtime is not installed. Go to Settings to download it.")
            return
        }
        guard prefix.exists, prefix.isSteamInstalled else {
            fail("Wine environment not ready — restart the app to reinitialize.")
            return
        }

        appendLog("Environment ready")

        guard !Task.isCancelled else { return }

        // Apply game-specific compatibility fixes before install or launch.
        let compat = GameCompatibilityDB.shared
        if compat.profile(for: game.id) != nil {
            appendLog("Applying compatibility profile: \(compat.fixSummary(for: game.id))")
            log.info("[launch] game profile appID=\(game.id): \(compat.fixSummary(for: game.id))")
        }

        // If the game isn't installed yet, ask the running `steam.exe` to install it
        // via IPC and poll the ACF manifest for progress. Steam runs its own native
        // downloader — same path, same CDN, same verification as Steam Desktop.
        // `SteamWindowSuppressor` hides any confirmation dialogs Steam renders.
        if !prefix.isGameInstalled(appID: game.id) {
            try? prefix.ensureSteamCFG()
            try? prefix.ensureDefaultLibrary()

            // Make sure Steam is actually running. Normally `BootstrapManager` started
            // it, but if the sign-in sheet ran later (first launch after install), or
            // Steam crashed, we restart it here.
            if !steamManager.isSteamProcessAlive {
                log.info("[launch] persistent Steam not alive — starting")
                transition(to: .bootstrappingSteam, activity: "Starting Steam…")
                do {
                    try await steamManager.startPersistent(engine: engine, prefix: prefix)
                    try await steamManager.waitUntilReady(prefix: prefix, timeout: .seconds(120))
                    if let pid = steamManager.persistentProcessIdentifier {
                        windowSuppressor?.resumeSuppressing(pid: pid)
                    }
                } catch {
                    fail("Steam is not ready: \(error.localizedDescription)", error: error)
                    return
                }
            }

            transition(to: .awaitingInstallConfirmation,
                       activity: "Preparing download for \(game.name)…")
            appendLog("Preparing download for \(game.name)")
            log.info("[launch] pre-seeding appmanifest for appID=\(game.id) and restarting Steam")

            let steamID64 = steamAuth?.steamID ?? ""
            guard !steamID64.isEmpty else {
                fail("Not signed into Steam — please sign in and try again.")
                return
            }

            do {
                try await steamManager.installGame(
                    appID: game.id,
                    name: game.name,
                    installDir: game.name,
                    steamID64: steamID64,
                    engine: engine,
                    prefix: prefix
                )
            } catch {
                fail("Could not start install: \(error.localizedDescription)", error: error)
                return
            }

            // The pre-seeded ACF is already on disk before steam.exe restarted.
            // By the time `installGame` returns (Steam is logged on), Steam has
            // already scanned the ACF and queued the download. No "ACF appears"
            // wait needed — we go straight to progress polling.

            // ACF exists — we're downloading. Poll for progress until done.
            //
            // Progress is broken into four phases mirroring Steam's own
            // StateFlags: download → staging → validating → committing →
            // installed. We remap each phase's raw counters into a single
            // 0-100% progress bar split 0-85 / 85-92 / 92-97 / 97-100 so the
            // bar moves through every phase. Pure-download percentage jumping
            // 0 → 100 made small games (say 200 MB on a 200 Mbps connection)
            // appear to "just finish" because the download completed between
            // two 2-second polls. Staging + commit add several more seconds
            // of observable progress even on fast connections.
            var lastLoggedPercent = -1
            var lastPhase: WinePrefix.InstallPhase?
            while !prefix.isGameFullyInstalled(appID: game.id) {
                guard !Task.isCancelled else {
                    downloadProgress = nil
                    currentActivity = nil
                    log.info("[launch] download cancelled by user")
                    return
                }

                if let d = prefix.gameDownloadDetails(appID: game.id) {
                    let dlFrac: Double = d.bytesToDownload > 0
                        ? Double(d.bytesDownloaded) / Double(d.bytesToDownload)
                        : 0
                    let stageFrac: Double = d.bytesToStage > 0
                        ? Double(d.bytesStaged) / Double(d.bytesToStage)
                        : 0

                    // Per-phase bar weights: most wall-clock time is download.
                    let fraction: Double
                    switch d.phase {
                    case .pending:      fraction = 0.00
                    case .downloading:  fraction = dlFrac * 0.85
                    case .staging:      fraction = 0.85 + stageFrac * 0.07
                    case .validating:   fraction = 0.92 + stageFrac * 0.05
                    case .committing:   fraction = 0.97
                    case .installed:    fraction = 1.00
                    case .unknown:      fraction = max(dlFrac, stageFrac)
                    }
                    downloadProgress = fraction
                    let pct = Int(fraction * 100)

                    // User-facing activity string reflects the actual phase.
                    let verb = d.phase.userDescription
                    let bytesText: String = {
                        switch d.phase {
                        case .downloading where d.bytesToDownload > 0:
                            return " — \(Self.formatBytes(d.bytesDownloaded)) / \(Self.formatBytes(d.bytesToDownload)) (\(pct)%)"
                        case .staging, .validating where d.bytesToStage > 0:
                            return " — \(Self.formatBytes(d.bytesStaged)) / \(Self.formatBytes(d.bytesToStage)) (\(pct)%)"
                        case .committing, .installed:
                            return " (\(pct)%)"
                        default:
                            return pct > 0 ? " (\(pct)%)" : "…"
                        }
                    }()
                    currentActivity = "\(verb) \(game.name)\(bytesText)"

                    // Log at phase transitions + every 5% within a phase.
                    if lastPhase != d.phase {
                        appendLog("\(verb) \(game.name)")
                        log.info("[launch] appID=\(game.id) phase=\(d.phase.rawValue) stateFlags=\(d.stateFlags)")
                        lastPhase = d.phase
                        lastLoggedPercent = -1
                    }
                    if pct / 5 > lastLoggedPercent / 5 {
                        appendLog("\(verb) \(game.name) — \(pct)%")
                        lastLoggedPercent = pct
                    }
                } else {
                    currentActivity = "Preparing \(game.name)…"
                }

                try? await Task.sleep(for: .seconds(2))
            }

            appendLog("Download complete")
            library?.setInstalled(true, for: game.id)
            downloadProgress = 1.0
        }

        // Install-only mode: stop here without proceeding to launch.
        if !launchAfterInstall {
            appendLog("Installation complete")
            MeridianNotifications.sendInstallComplete(gameName: game.name)
            launchState = .idle
            activeAppID = nil
            pipelineStartDate = nil
            currentActivity = nil
            return
        }

        guard !Task.isCancelled else { return }

        // Give instant feedback before the multi-second prep steps (Steam DRM start).
        // Without this the button stays on "Play" for 5+ seconds.
        transition(to: .launching, activity: "Preparing \(game.name)…")

        // Tell the health monitor to defer restarts while the game is active.
        steamManager.gameIsRunning = true

        // Steam DRM: some games ship `steam_api64.dll` which calls SteamAPI_Init()
        // at startup and requires a live Steam IPC socket. Persistent `steam.exe`
        // is already running (started by BootstrapManager or the sign-in sheet),
        // so the IPC socket exists. We just write `steam_appid.txt` so the DLL
        // can look up its own appID without a round trip through the client.
        let needsSteamForDRM = prefix.gameRequiresSteamAPI(appID: game.id)
            && !(GameCompatibilityDB.shared.profile(for: game.id)?.skipSteamDRM ?? false)
        if needsSteamForDRM {
            log.info("[launch] Steam DRM detected — writing steam_appid.txt and verifying Steam is ready")
            prefix.writeSteamAppID(game.id)

            // If Steam somehow isn't running (edge case — user quit it manually or
            // it crashed since bootstrap), restart it now. Otherwise the game will
            // fail SteamAPI_Init and exit within seconds.
            if !steamManager.isSteamProcessAlive {
                log.warning("[launch] Steam DRM required but persistent Steam not alive — restarting")
                appendLog("Starting Steam…")
                do {
                    try await steamManager.startPersistent(engine: engine, prefix: prefix)
                    try await steamManager.waitUntilReady(prefix: prefix, timeout: .seconds(60))
                    if let pid = steamManager.persistentProcessIdentifier {
                        windowSuppressor?.resumeSuppressing(pid: pid)
                    }
                } catch {
                    log.warning("[launch] Steam restart failed: \(error.localizedDescription) — launching game anyway, it may fail DRM init")
                }
            }

            appendLog("Starting game…")
        }

        // Pause window suppression BEFORE launching the game exe.
        // The suppressor's polling timer auto-discovers any new wineloader process and
        // hides its windows while suppressionActive=true. By pausing here, the game's
        // first window appears naturally without being hidden and then "restored" later.
        // The DRM Steam process (if any) is already running and hidden; pausing now
        // only affects the about-to-launch game window.
        windowSuppressor?.stopSuppressingNewWindows()

        // Launch the game directly via Wine, bypassing steam.exe -applaunch.
        transition(to: .launching, activity: "Launching \(game.name)…")
        appendLog("Launching \(game.name)…")

        let launchResult: WineSteamManager.GameLaunchResult
        do {
            launchResult = try await steamManager.launchGameDirectly(
                appID: game.id,
                engine: engine,
                prefix: prefix
            )
            log.info("[launch] dispatched pid=\(launchResult.pid)")
        } catch {
            fail("Launch failed: \(error.localizedDescription)", error: error)
            return
        }

        // Fast-fail: if Wine exits within the first 3 seconds it almost certainly
        // crashed at DLL load time (exit 53 = STATUS_DLL_NOT_FOUND, common for
        // d3d12.dll on engines without a compatible D3D12 implementation). Detecting
        // this immediately saves the user from a 120-second monitor timeout.
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled else { return }

        if !launchResult.process.isRunning {
            let exitCode = launchResult.process.terminationStatus
            log.error("[launch] game process exited immediately (code=\(exitCode)) — aborting before monitor")
            let msg: String
            switch exitCode {
            case 53:
                msg = "Game failed to start: a required system DLL was not found (exit 53). " +
                      "This is a known engine limitation for D3D12 games. " +
                      "A future engine update will add D3D12 support."
            default:
                msg = "Game exited immediately (exit code \(exitCode)). Check Settings → Diagnostics for details."
            }
            fail(msg)
            return
        }

        // The AXObserver suppressor is already active; it will minimize any Steam
        // "launching game" splash immediately. No explicit hide call is needed.

        library?.setInstalled(true, for: game.id)

        let gamePattern = prefix.gameInstallDir(appID: game.id)
        log.info("[launch] resolved game pattern: \(gamePattern ?? "nil")")
        appendLog("Waiting for \(game.name) to start…")
        log.info("[launch] state=LAUNCHING appID=\(game.id) | monitoring pid=\(launchResult.pid)")

        gameProcess.startMonitoring(
            appID: game.id,
            launchedPID: launchResult.pid,
            engine: engine,
            prefix: prefix,
            gamePattern: gamePattern,
            onLog: { [weak self] line in self?.appendLog(line) }
        )

        // Wait for the monitor to advance through its phases.
        // Stay in .launching until game processes are confirmed (phase == .running).
        while gameProcess.isRunning {
            if Task.isCancelled {
                log.info("[launch] task cancelled during monitoring — stopping game")
                await gameProcess.stopGame(engine: engine, prefix: prefix)
                break
            }

            // Transition to .running the moment processes are confirmed
            if !processesConfirmed && gameProcess.confirmedRunning {
                processesConfirmed = true
                launchState = .running(appID: game.id)
                runningSince = .now
                currentActivity = nil
                AppSettings.shared.recordLaunch(appID: game.id)
                log.info("[launch] state=RUNNING appID=\(game.id) — game processes confirmed")
                // Send our windows to the back so the game window appears in front.
                // Suppression was already paused before launch so the game window
                // was never hidden and does not need to be restored.
                for window in NSApplication.shared.windows {
                    window.orderBack(nil)
                }
            }

            try? await Task.sleep(for: .seconds(1))
        }

        guard !Task.isCancelled else {
            log.info("[launch] task cancelled — not setting exited state")
            return
        }

        // Game has exited — allow health monitor restarts again and re-engage
        // suppression so Steam cannot surface its window on game exit.
        steamManager.gameIsRunning = false
        if let pid = steamManager.persistentProcessIdentifier {
            windowSuppressor?.resumeSuppressing(pid: pid)
        }

        // `steam.exe` is a persistent process — we do NOT kill it on game exit.
        // It handles future installs, launches, DRM handshakes, and Steam Cloud
        // sync. The app-termination path (`AppDelegate.applicationShouldTerminate`
        // → `TerminationCleanup.killAllWineProcesses`) cleans it up on quit.

        // Determine final state based on how the monitor exited
        switch gameProcess.monitorPhase {
        case .exited:
            appendLog("Game session ended")
            launchState = .exited(appID: game.id)
            log.info("[launch] state=EXITED appID=\(game.id)")

        case .timedOut:
            fail("Game did not start within the expected time. Steam may still be updating or validating files — try again.")
            log.warning("[launch] state=FAILED (timeout) appID=\(game.id)")

        case .failed(let detail):
            fail(detail)
            log.error("[launch] state=FAILED appID=\(game.id) | \(detail)")

        default:
            appendLog("Game session ended")
            launchState = .exited(appID: game.id)
            log.info("[launch] state=EXITED appID=\(game.id) (monitor phase=\(String(describing: self.gameProcess.monitorPhase)))")
        }

        runningSince = nil
        pipelineStartDate = nil
        currentActivity = nil
        downloadProgress = nil
        processesConfirmed = false
    }

    // MARK: - Download progress helpers

    /// Parses a SteamCMD stdout line for download progress.
    /// Returns a fraction 0.0–1.0, or nil if the line doesn't contain progress info.
    /// Recognizes: "Update state (0x61) downloading, progress: 43.50 (3362453174 / 7729379123)"
    /// Also returns 1.0 for "Success! App '<id>' fully installed."
    static func parseSteamCMDProgress(line: String) -> Double? {
        if line.contains("downloading, progress:"),
           let match = line.range(of: #"(\d+) / (\d+)"#, options: .regularExpression),
           case let parts = String(line[match]).components(separatedBy: " / "),
           parts.count == 2,
           let downloaded = Double(parts[0]),
           let total = Double(parts[1]),
           total > 0,
           downloaded / total > 0 {
            return downloaded / total
        } else if line.contains("Success! App") {
            return 1.0
        }
        return nil
    }

    /// Formats a byte count as a human-readable string (e.g. "1.5 GB", "750 MB").
    static func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    // MARK: - Private helpers

    private func transition(to state: LaunchState, activity: String) {
        launchState = state
        currentActivity = activity
        log.info("[launch] state=\(String(describing: state)) | \(activity)")
    }

    private func fail(_ message: String, error: Error? = nil) {
        launchState = .failed(message)
        runningSince = nil
        pipelineStartDate = nil
        currentActivity = nil
        downloadProgress = nil
        appendLog("FAILED: \(message)")
        if let error {
            log.error("[launch] FAILED: \(message) | \(String(describing: error))")
        } else {
            log.error("[launch] FAILED: \(message)")
        }
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        log.info("[log] \(line)")
    }
}
