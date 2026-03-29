import AppKit
import Foundation
import Observation
import os.log

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
        case awaitingInstallConfirmation // Steam dialog visible; waiting for user to confirm
        case installing   // ACF confirmed on disk; waiting for full download (StateFlags == 4)
        case launching
        case running(appID: Int)
        case stopping(appID: Int)
        case uninstalling // waiting for Steam to delete the ACF manifest
        case exited(appID: Int)
        case failed(String)
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var logs: [String] = []
    private(set) var currentActivity: String?
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
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore? = nil
    ) {
        // Must be async for stopGame; run in Task if called from sync context
        Task {
            await launchImpl(game: game, engine: engine, steamManager: steamManager, sessionBridge: sessionBridge, library: library)
        }
    }

    private func launchImpl(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore?
    ) async {
        switch launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam,
             .awaitingInstallConfirmation, .installing, .launching, .stopping, .uninstalling:
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
                sessionBridge: sessionBridge,
                library: library
            )
        }
    }

    /// Cancels an in-progress launch. Cleans up any spawned processes.
    func cancelLaunch(engine: WineEngine, steamManager: WineSteamManager) async {
        log.info("[cancelLaunch] cancelling current launch")
        launchTask?.cancel()
        launchTask = nil

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
        processesConfirmed = false
    }

    // MARK: - Launch Pipeline

    private func executeLaunchPipeline(
        game: Game,
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        library: SteamLibraryStore?
    ) async {
        logs.removeAll()
        currentActivity = nil
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

        // If the persistent Steam process has died since bootstrap (crash, OOM, etc.)
        // restart it silently before proceeding — but ONLY when not using the CX engine.
        // With CX engine, we don't use persistent Steam at all (SteamCMD for downloads,
        // direct Wine launch for games).
        if engine.cxPreviewLibPath == nil && !steamManager.isSteamProcessAlive {
            log.warning("[launch] persistent Steam not alive — restarting before launch")
            transition(to: .bootstrappingSteam, activity: "Reconnecting to Steam…")
            do {
                try await steamManager.startPersistent(engine: engine, prefix: prefix)
                try await steamManager.waitUntilReady(prefix: prefix)
                steamManager.enableHealthMonitor(engine: engine, prefix: prefix)
            } catch {
                fail("Failed to restart Steam: \(error.localizedDescription)", error: error)
                return
            }
            if let pid = steamManager.persistentProcessIdentifier {
                windowSuppressor?.resumeSuppressing(pid: pid)
            }
        }

        appendLog("Environment ready — Steam is running")

        guard !Task.isCancelled else { return }

        // Apply game-specific compatibility fixes before install or launch.
        let compat = GameCompatibilityDB.shared
        let gameProfile = compat.profile(for: game.id)
        if let profile = gameProfile {
            appendLog("Applying compatibility profile: \(compat.fixSummary(for: game.id))")
            log.info("[launch] game profile appID=\(game.id): \(compat.fixSummary(for: game.id))")

            // Install DXMT DLLs into system32 if required (CX engine + D3D11 game).
            // CX's wineloader loads DLLs from its own lib path before WINEDLLPATH,
            // so DXMT must be physically in system32 to take priority.
            if profile.requiresDXMTInSystem32 && engine.cxPreviewLibPath != nil {
                do {
                    try prefix.installDXMTInSystem32(engine: engine)
                    appendLog("DXMT DLLs installed to system32 (Metal renderer ready)")
                } catch {
                    log.warning("[launch] DXMT system32 install failed: \(error.localizedDescription)")
                }
            }
        }

        // If the game isn't installed yet, download it via SteamCMD.
        // SteamCMD is the only reliable headless installer under Wine 8.0.1 because
        // steam.exe cannot authenticate (webhelper crash-loops, ConnectCache ignored).
        // SteamCMD uses cached credentials after the first manual login.
        if !prefix.isGameInstalled(appID: game.id) {
            try? prefix.ensureSteamCFG()
            try? prefix.ensureDefaultLibrary()

            transition(to: .awaitingInstallConfirmation,
                       activity: "Preparing download for \(game.name)…")
            appendLog("Starting SteamCMD download for appID=\(game.id)")
            log.info("[launch] beginning SteamCMD install appID=\(game.id)")

            // Get the Steam account username for SteamCMD login.
            // SteamCMD uses cached credentials — no password needed after first login.
            let username = AppSettings.shared.steamCredentialAccountName
            guard !username.isEmpty else {
                fail("Steam account username not found. Please sign in again through Settings.")
                return
            }

            do {
                try await steamManager.installWithSteamCMD(
                    appID: game.id,
                    username: username,
                    engine: engine,
                    prefix: prefix,
                    onProgress: { [weak self] line in
                        self?.appendLog(line)
                        // Parse percentage from SteamCMD output for currentActivity
                        if let pctRange = line.range(of: #"\d+\.\d+(?= \()"#, options: .regularExpression) {
                            let pct = String(line[pctRange])
                            self?.currentActivity = "Downloading \(game.name)… \(pct)%"
                        }
                    }
                )
            } catch {
                fail("Download failed: \(error.localizedDescription)", error: error)
                return
            }

            // Verify the ACF was created with StateFlags == 4 (fully installed).
            guard prefix.isGameFullyInstalled(appID: game.id) else {
                fail("Download appeared to complete but game files are incomplete. Try again.")
                return
            }

            appendLog("Download complete — game installed ✓")
            library?.setInstalled(true, for: game.id)
        }

        guard !Task.isCancelled else { return }

        // Tell the health monitor to defer restarts while the game is active.
        steamManager.gameIsRunning = true

        // Launch the game directly via Wine, bypassing steam.exe.
        // steam.exe -applaunch shows a Steam login window because Steam's client
        // needs its own authenticated session. Since we use SteamCMD for downloads
        // and the CX engine for running, there's no need for steam.exe at all.
        transition(to: .launching, activity: "Launching \(game.name)…")
        appendLog("Launching \(game.name) directly via Wine")

        let launchedPID: Int32
        do {
            launchedPID = try await steamManager.launchGameDirectly(
                appID: game.id,
                engine: engine,
                prefix: prefix
            )
            appendLog("Launch dispatched (pid=\(launchedPID))")
            log.info("[launch] wine process pid=\(launchedPID)")
        } catch {
            fail("Launch failed: \(error.localizedDescription)", error: error)
            return
        }

        // The AXObserver suppressor is already active; it will minimize any Steam
        // "launching game" splash immediately. No explicit hide call is needed.

        library?.setInstalled(true, for: game.id)

        let gamePattern = prefix.gameInstallDir(appID: game.id)
        log.info("[launch] resolved game pattern: \(gamePattern ?? "nil")")
        appendLog("Waiting for game processes to appear…")
        log.info("[launch] state=LAUNCHING appID=\(game.id) | monitoring pid=\(launchedPID)")

        gameProcess.startMonitoring(
            appID: game.id,
            launchedPID: launchedPID,
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
                // Pause new-window suppression so the game's window can appear.
                // Steam's existing minimized windows stay minimized.
                windowSuppressor?.stopSuppressingNewWindows()
                // Send our windows to the back so the game window appears in front
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
        processesConfirmed = false
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
