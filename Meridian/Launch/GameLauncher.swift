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

    /// Cancels an in-progress launch or download.
    ///
    /// Behaviour depends on the current state:
    ///
    /// **Download in progress** (`.awaitingInstallConfirmation`, `.bootstrappingSteam`
    /// while in the install path, `.preparingEngine`, `.preparingPrefix`): stop our
    /// polling loop but leave Steam running. Steam may continue downloading in the
    /// background; when the user clicks Install again the no-restart probe will detect
    /// it immediately and the bar reappears without a 40-second restart+re-auth cycle.
    ///
    /// **Game running/launching** (`.running`, `.launching`): kill all Wine processes
    /// so the game and its DLLs are fully torn down before the next operation.
    func cancelLaunch(engine: WineEngine, steamManager: WineSteamManager) async {
        let gameWasRunning: Bool
        switch launchState {
        case .running, .launching:
            gameWasRunning = true
        default:
            gameWasRunning = false
        }

        log.info("[cancelLaunch] cancelling — gameWasRunning=\(gameWasRunning) state=\(String(describing: launchState))")
        launchTask?.cancel()
        launchTask = nil
        steamManager.gameIsRunning = false

        if gameWasRunning {
            // Game processes are alive — kill everything so the next operation
            // starts from a clean Wine session.
            await cleanupProcesses(engine: engine, steamManager: steamManager)
        }
        // Download cancel: leave Steam running. The user will get instant progress
        // resumption on the next Install click instead of a 30+ second restart.

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
        appendLog(gameWasRunning ? "Game stopped" : "Download cancelled")
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

        // If the game isn't fully installed yet, either seed a fresh install or resume
        // an existing partial ACF. ACF presence alone is not playable: Steam writes it
        // as soon as a download is queued.
        let wasAlreadyInstalled = prefix.isGameFullyInstalled(appID: game.id)
        if !wasAlreadyInstalled {
            try? prefix.ensureSteamCFG()
            try? prefix.ensureDefaultLibrary()
            windowSuppressor?.suppressNow(reason: "download click appID=\(game.id)")
            steamManager.startHeadlessWebhelperKillBurst(reason: "download click appID=\(game.id)", duration: .seconds(20))

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

            let steamID64 = steamAuth?.steamID ?? ""
            guard !steamID64.isEmpty else {
                fail("Not signed into Steam — please sign in and try again.")
                return
            }

            if !prefix.isGameInstalled(appID: game.id) {
                log.info("[launch] pre-seeding appmanifest and sending install IPC for appID=\(game.id)")
                do {
                    try await steamManager.installGame(
                        appID: game.id,
                        name: game.name,
                        installDir: game.name,
                        steamID64: steamID64,
                        engine: engine,
                        prefix: prefix,
                        statusUpdate: { [weak self] msg in
                            self?.currentActivity = msg
                            self?.appendLog(msg)
                        }
                    )
                } catch is CancellationError {
                    log.info("[launch] install cancelled by user — not an error")
                    return
                } catch {
                    fail("Could not start install: \(error.localizedDescription)", error: error)
                    return
                }

                // Wait up to 15s for Steam to acknowledge the IPC and write
                // BytesToDownload into the ACF. If nothing starts, the IPC
                // command may have triggered a suppressed dialog — tell the
                // user rather than spinning indefinitely.
                let ipcDeadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < ipcDeadline {
                    guard !Task.isCancelled else { return }
                    let d = prefix.gameDownloadDetails(appID: game.id)
                    if (d?.bytesToDownload ?? 0) > 0 || prefix.isGameFullyInstalled(appID: game.id) {
                        log.info("[launch] IPC triggered download for appID=\(game.id)")
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
                if (prefix.gameDownloadDetails(appID: game.id)?.bytesToDownload ?? 0) == 0
                    && !prefix.isGameFullyInstalled(appID: game.id) {
                    log.warning("[launch] IPC did not start download within 15s for appID=\(game.id)")
                    fail("Steam didn't start the download. Try clicking Install again.")
                    return
                }
            } else {
                appendLog("Resuming download for \(game.name)")
                currentActivity = "Resuming download for \(game.name)…"
                log.info("[launch] appID=\(game.id) has partial ACF — resuming existing Steam download")
            }

            // The pre-seeded ACF is already on disk before steam.exe restarted.
            // By the time `installGame` returns (Steam is logged on), Steam has
            // already scanned the ACF and queued the download. No "ACF appears"
            // wait needed — we go straight to progress polling.

            // Poll real disk usage under `steamapps/downloading/<appID>/` for
            // live progress. The ACF's `BytesDownloaded` is buffered in Steam's
            // memory and only flushed to disk at phase boundaries — useless as
            // a live signal (see `WinePrefix.bytesOnDiskForDownload` doc). The
            // directory's on-disk size, by contrast, grows at the CDN's rate as
            // Steam writes chunks.
            //
            // Bar mapping:
            //   0 – 90 %  download (diskBytes / bytesToDownload from ACF)
            //   90 – 99 % install (bytesOnDiskForInstall / bytesToStage)
            //   100 %     StateFlags == 4
            let installDir = prefix.gameInstallDir(appID: game.id) ?? game.name
            var lastLoggedPercent = -1
            var lastPhase: WinePrefix.InstallPhase?
            var maxSeenDownloadBytes: Int64 = 0
            var maxSeenInstallBytes: Int64 = 0
            while !prefix.isGameFullyInstalled(appID: game.id) {
                guard !Task.isCancelled else {
                    downloadProgress = nil
                    currentActivity = nil
                    log.info("[launch] download cancelled by user")
                    return
                }

                // Target sizes come from the ACF (set once, at download start,
                // so always reliable even though incremental BytesDownloaded
                // isn't). Live progress comes from disk.
                let d = prefix.gameDownloadDetails(appID: game.id)
                let bytesToDownload = d?.bytesToDownload ?? 0
                let bytesToStage    = d?.bytesToStage ?? 0

                let diskDl = prefix.bytesOnDiskForDownload(appID: game.id)
                let diskInstall = prefix.bytesOnDiskForInstall(appID: game.id, installDir: installDir)

                // Clamp to monotonic non-decreasing. Steam briefly moves files
                // from downloading/ into common/ during commit — without
                // clamping, our bar would dip during that handoff.
                if diskDl > maxSeenDownloadBytes { maxSeenDownloadBytes = diskDl }
                if diskInstall > maxSeenInstallBytes { maxSeenInstallBytes = diskInstall }

                let phase: WinePrefix.InstallPhase
                if d?.phase == .installed {
                    phase = .installed
                } else if bytesToDownload > 0 && maxSeenDownloadBytes < bytesToDownload {
                    phase = .downloading
                } else if bytesToStage > 0 && maxSeenInstallBytes < bytesToStage {
                    phase = .installing
                } else {
                    phase = .preparing
                }

                let dlFrac = bytesToDownload > 0
                    ? min(Double(maxSeenDownloadBytes) / Double(bytesToDownload), 1.0)
                    : 0
                let installFrac = bytesToStage > 0
                    ? min(Double(maxSeenInstallBytes) / Double(bytesToStage), 1.0)
                    : 0

                let fraction: Double
                switch phase {
                case .preparing:    fraction = 0.0
                case .downloading:  fraction = dlFrac * 0.9
                case .installing:   fraction = 0.9 + installFrac * 0.09
                case .installed:    fraction = 1.0
                }
                downloadProgress = fraction
                let pct = Int(fraction * 100)
                let verb = phase.userDescription

                currentActivity = Self.installActivityMessage(
                    gameName: game.name,
                    phase: phase,
                    downloadedBytes: maxSeenDownloadBytes,
                    downloadTotalBytes: bytesToDownload,
                    installedBytes: maxSeenInstallBytes,
                    installTotalBytes: bytesToStage,
                    percent: pct
                )

                if lastPhase != phase {
                    appendLog("\(verb) \(game.name)")
                    log.info("[launch] appID=\(game.id) phase=\(phase.rawValue) diskDl=\(maxSeenDownloadBytes)/\(bytesToDownload) diskInstall=\(maxSeenInstallBytes)/\(bytesToStage)")
                    lastPhase = phase
                    lastLoggedPercent = -1
                }
                if pct / 5 > lastLoggedPercent / 5 {
                    appendLog("\(verb) \(game.name) — \(pct)%")
                    lastLoggedPercent = pct
                }

                // 500 ms polling: smoother bar on fast connections without
                // burning CPU. Directory enumeration is cheap for a single
                // subtree (<1 ms for a 300-file install).
                try? await Task.sleep(for: .milliseconds(500))
            }

            // Silence Steam's download-complete chime by killing
            // steamwebhelper at the exact moment `StateFlags` flips to 4.
            // The chime rides Steam's audio-queue path, which CEF / webhelper
            // owns — the DYLD_INSERT accessory dylib kills the toast window
            // but the sound is a separate code path the dylib doesn't hook.
            // Killing steamwebhelper severs the audio path before the chime
            // can fire; the main `steam.exe` (needed for DRM game launches)
            // is untouched and automatically respawns webhelper a few
            // seconds later for the next operation.
            WineSteamManager.killWebhelper(reason: "download complete chime")
            appendLog("Download complete")
            library?.setInstalled(true, for: game.id)
            DownloadHistory.shared.recordCompletion(appID: game.id, name: game.name)
            downloadProgress = 1.0
        }

        // Install-only mode: stop here without proceeding to launch.
        if !launchAfterInstall {
            // Only notify if we actually downloaded something. If the game was
            // already fully installed when we entered (e.g. the UI showed the
            // Install button due to a transient StateFlags mismatch), skip the
            // notification — there's nothing to announce. Either way, ensure
            // the library reflects the installed state so the button flips to Play.
            library?.setInstalled(true, for: game.id)
            if !wasAlreadyInstalled {
                appendLog("Installation complete")
                MeridianNotifications.sendInstallComplete(gameName: game.name)
            }
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
        let profile = GameCompatibilityDB.shared.profile(for: game.id)
        let needsSteamForDRM = prefix.gameRequiresSteamAPI(appID: game.id)
            && !(profile?.skipSteamDRM ?? false)
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

        let launchedPID: Int32
        let directProcess: Process?
        do {
            if profile?.launchViaSteam == true {
                appendLog("Launching through Steam…")
                launchedPID = try await steamManager.launchGame(
                    appID: game.id,
                    engine: engine,
                    prefix: prefix
                )
                directProcess = nil
                log.info("[launch] dispatched via Steam pid=\(launchedPID)")
            } else {
                let result = try await steamManager.launchGameDirectly(
                    appID: game.id,
                    engine: engine,
                    prefix: prefix
                )
                launchedPID = result.pid
                directProcess = result.process
                log.info("[launch] dispatched pid=\(launchedPID)")
            }
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

        if let directProcess, !directProcess.isRunning {
            let exitCode = directProcess.terminationStatus
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

    static func installActivityMessage(
        gameName: String,
        phase: WinePrefix.InstallPhase,
        downloadedBytes: Int64,
        downloadTotalBytes: Int64,
        installedBytes: Int64,
        installTotalBytes: Int64,
        percent: Int
    ) -> String {
        let verb = phase.userDescription
        switch phase {
        case .downloading:
            return "\(verb) \(gameName) — \(Self.formatBytes(downloadedBytes)) / \(Self.formatBytes(downloadTotalBytes)) (\(percent)%)"
        case .installing:
            guard installedBytes > 0 else {
                if downloadedBytes > 0 && downloadTotalBytes > 0 {
                    return "\(verb) \(gameName) — download complete, preparing files (\(percent)%)"
                }
                return "\(verb) \(gameName) — preparing files (\(percent)%)"
            }
            return "\(verb) \(gameName) — \(Self.formatBytes(installedBytes)) / \(Self.formatBytes(installTotalBytes)) (\(percent)%)"
        case .installed:
            return "\(verb) \(gameName)"
        case .preparing:
            return "\(verb) \(gameName)…"
        }
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
