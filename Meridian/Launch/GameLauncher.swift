import AppKit
import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "GameLauncher")

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
        case launching
        case running(appID: Int)
        case stopping(appID: Int)
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
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching, .stopping:
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

        await cleanupProcesses(engine: engine, steamManager: steamManager)

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
        await gameProcess.stopGame(engine: engine, prefix: prefix)
        runningSince = nil
        pipelineStartDate = nil
        processesConfirmed = false
        launchState = .exited(appID: appID)
        currentActivity = nil
        log.info("[stopGame] exited appID=\(appID)")
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
        appendLog("Environment ready — Steam is running")

        guard !Task.isCancelled else { return }

        // Send steam.exe -applaunch — stays in .launching until processes confirmed
        transition(to: .launching, activity: "Launching \(game.name)…")
        appendLog("Launching steam.exe -applaunch \(game.id)")

        let launchedPID: Int32
        do {
            launchedPID = try await steamManager.launchGame(
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
