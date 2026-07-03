import Foundation
import AppKit
import Observation

private let log = MeridianLog(category: "Launcher")

// MARK: - Launcher

/// Orchestrates game installs and launches. Does NOT own steam.exe.
///
/// - Installs run headlessly via the DepotDownloader fork (`installHeadless`)
///   using the persisted OAuth refresh_token — no steam.exe involvement.
/// - ALL launches (DRM and DRM-free) go through wine64 direct execution
///   (`launchDirect`) — no steam.exe, no Steam IPC.
/// - DRM games (those shipping `steam_api64.dll`) get a Steamworks API shim
///   first (Phase 4, HANDOFF-2026-06-19): `prefix.installSteamEmulator`
///   replaces the game's Valve steam_api(64).dll with the open-source gbe_fork
///   emulator, so `SteamAPI_Init()` succeeds locally using the user's steamID +
///   the appID — no steam.exe, no auth, no "Who's playing" window. The
///   steam.exe `-applaunch` path (`SteamSession.launchGameViaSteam`) is kept
///   only as a documented fallback for SteamStub exe-encrypted titles.
@Observable
@MainActor
final class Launcher {

    // MARK: - State

    enum LaunchState: Equatable {
        case idle
        case installing(appID: Int)
        case downloading(appID: Int)
        case launching(appID: Int)
        case running(appID: Int)
        case stopping(appID: Int)
        case uninstalling
        case failed(String)

        static func == (lhs: LaunchState, rhs: LaunchState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.uninstalling, .uninstalling):       return true
            case (.installing(let a), .installing(let b)):             return a == b
            case (.downloading(let a), .downloading(let b)):           return a == b
            case (.launching(let a), .launching(let b)):               return a == b
            case (.running(let a), .running(let b)):                   return a == b
            case (.stopping(let a), .stopping(let b)):                 return a == b
            case (.failed(let a), .failed(let b)):                     return a == b
            default:                                                    return false
            }
        }
    }

    // MARK: - Steam prompts (user consent before any Steam window can appear)

    /// A user-consent prompt raised by the launch pipeline. The UI
    /// (GameDetailView) renders it as an alert; the user's choice re-enters
    /// the pipeline via `confirmSteamPrompt` / `dismissSteamPrompt`.
    enum SteamPrompt: Equatable {
        /// The game's exe is SteamStub-encrypted (`.bind` PE section) — the
        /// gbe_fork shim cannot decrypt it, so Offline mode cannot run it.
        /// Offer switching the game to Online (real Steam client).
        case steamRequired(Game)
        /// Online mode needs a ONE-TIME interactive Steam sign-in (no
        /// Steam-written session exists on this prefix yet). Explain that a
        /// Steam window will open once before actually opening it.
        case signInRequired(Game)

        var game: Game {
            switch self {
            case .steamRequired(let g), .signInRequired(let g): return g
            }
        }
    }

    private(set) var steamPrompt: SteamPrompt?

    /// One-shot approval for the interactive sign-in, set when the user
    /// confirms a prompt. Consumed (reset) by the next `launchOnline` run so
    /// a later cold launch re-prompts instead of silently opening Steam.
    private var approvedInteractiveSignInAppID: Int?

    /// User confirmed the pending prompt: switch SteamStub games to Online
    /// mode, mark the interactive sign-in as approved, and re-enter the
    /// launch pipeline.
    func confirmSteamPrompt(
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        guard let prompt = steamPrompt else { return }
        steamPrompt = nil
        let game = prompt.game
        if case .steamRequired = prompt {
            AppSettings.shared.setLaunchMode(.online, appID: game.id)
            appendLog("Switched \(game.name) to Online mode (SteamStub DRM requires the Steam client)")
        }
        approvedInteractiveSignInAppID = game.id
        launch(game: game, engine: engine, session: session, steamAuth: steamAuth, library: library)
    }

    func dismissSteamPrompt() {
        steamPrompt = nil
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var currentActivity: String?
    private(set) var downloadProgress: Double?
    private(set) var downloadBytesDone: Int64 = 0
    private(set) var downloadBytesTotal: Int64 = 0
    private(set) var downloadRateBps: Double = 0
    private(set) var logs: [String] = []
    private(set) var activeAppID: Int?
    private(set) var processesConfirmed: Bool = false
    private(set) var runningSince: Date?

    private let gameProcess = GameProcess()
    private let prefix = WinePrefix.defaultPrefix
    private var launchTask: Task<Void, Never>?

    /// Per-game stderr file handle, opened in `launchDirect` and closed
    /// in the pipeline's exit path. Held across the running phase so the
    /// kernel can keep writing every byte the game emits straight to disk
    /// without Meridian-side draining (avoids the
    /// `availableData` blocking issue described in
    /// `engine-research-findings.mdc` Pattern 1).
    private var activeGameLogHandle: FileHandle?

    /// The game's `steamapps/common/<dir>` directory for the active session,
    /// and the instant its process started. Used by `closeActiveGameLog` to
    /// collect the game's own engine log (Unity `Player.log` / Unreal
    /// `Saved/Logs`) for THIS session into `<appID>-engine.log`.
    private var activeGameInstallDir: URL?
    private var activeLaunchStartedAt: Date?

    var steamWindow: SteamWindow?

    // MARK: - Public API

    func launch(
        game: Game,
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            await self?.executePipeline(
                game: game, engine: engine, session: session,
                steamAuth: steamAuth, library: library, launchAfterInstall: true
            )
        }
    }

    func installOnly(
        game: Game,
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            await self?.executePipeline(
                game: game, engine: engine, session: session,
                steamAuth: steamAuth, library: library, launchAfterInstall: false
            )
        }
    }

    func cancelLaunch() {
        launchTask?.cancel()
        activeSession?.cancelInstall()
        closeActiveGameLog(reason: "user cancelled launch", exitCode: nil)
        launchState = .idle
        currentActivity = nil
        downloadProgress = nil
        downloadBytesDone = 0
        downloadBytesTotal = 0
        downloadRateBps = 0
        activeAppID = nil
    }

    // Stored reference to session for cancelInstall forwarding.
    private weak var activeSession: SteamSession?

    func stopGame(engine: WineEngine) {
        guard case .running(let appID) = launchState else { return }
        launchState = .stopping(appID: appID)
        currentActivity = "Stopping game…"
        Task { [weak self] in
            guard let self else { return }
            await gameProcess.stopGame(engine: engine, prefix: prefix)
            closeActiveGameLog(reason: "user requested stop", exitCode: nil)
            launchState = .idle
            currentActivity = nil
        }
    }

    func uninstall(game: Game, engine: WineEngine) {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            guard let self else { return }
            launchState = .uninstalling
            currentActivity = "Uninstalling \(game.name)…"
            do {
                try await uninstallGame(game: game, engine: engine)
                AppSettings.shared.markNotInstalled(appID: game.id)
            } catch {
                launchState = .failed(error.localizedDescription)
            }
            launchState = .idle
            currentActivity = nil
        }
    }

    // MARK: - Private: pipeline

    private func executePipeline(
        game: Game,
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService?,
        library: SteamLibraryStore?,
        launchAfterInstall: Bool
    ) async {
        activeSession = session

        // Guard: prevent concurrent launches (except stopping a running game first).
        switch launchState {
        case .installing, .downloading, .launching, .uninstalling:
            log.warning("[pipeline] ignoring — busy state \(String(describing: launchState))")
            return
        case .running:
            await gameProcess.stopGame(engine: engine, prefix: prefix)
        case .idle, .stopping, .failed:
            break
        }

        activeAppID = game.id
        downloadProgress = nil
        runningSince = nil
        processesConfirmed = false

        let steamID = steamAuth?.steamID ?? AppSettings.shared.steamCredentialSteamID

        // Install if needed — headless via the DepotDownloader fork (no steam.exe).
        if !prefix.isGameFullyInstalled(appID: game.id) {
            do {
                try await installHeadless(game: game, engine: engine, steamID: steamID)
            } catch is CancellationError {
                log.info("[pipeline] install cancelled")
                launchState = .idle
                currentActivity = nil
                downloadProgress = nil
                return
            } catch let dd as DepotDownloaderInstall.DDError where dd == .refreshTokenInvalid {
                // Exit 3 — Valve rejected the refresh token as genuinely dead
                // (not the anti-abuse AccessDenied case, which never reaches an
                // install because the token still "works" for the library).
                // Route the user back to re-auth. SteamAuthService observes this
                // and surfaces the sign-in sheet (API key + password preserved).
                log.warning("[pipeline] refresh token invalid on install — prompting re-auth")
                NotificationCenter.default.post(name: .meridianSteamSessionExpired, object: nil)
                fail("Your Steam session has expired. Please sign in again to install \(game.name).", error: dd)
                return
            } catch {
                fail("Could not install \(game.name): \(error.localizedDescription)", error: error)
                return
            }

            AppSettings.shared.markInstalled(appID: game.id)
            if let lib = library {
                await lib.refresh(steamID: steamID, apiKey: steamAuth?.apiKey ?? "")
            }
        }

        guard launchAfterInstall else {
            launchState = .idle
            currentActivity = nil
            return
        }

        // Online mode: bring the real Steam client online (authenticated from
        // the QR/OAuth session) and launch via `-applaunch`. This is the path
        // that enables cloud saves, in-game multiplayer, EULAs, and genuine
        // Steam DRM — the game talks to Valve, not a local emulator. Opt-in
        // per game (AppSettings.launchMode); default is Offline (gbe_fork).
        if AppSettings.shared.launchMode(appID: game.id) == .online {
            await launchOnline(game: game, engine: engine, session: session)
            return
        }

        // DRM games (those shipping `steam_api64.dll`) call SteamAPI_Init(),
        // which normally needs a running, logged-in steam.exe. Phase 4
        // (HANDOFF-2026-06-19) replaces that with a Steamworks API shim:
        // `installSteamEmulator` swaps the game's Valve steam_api(64).dll for
        // the open-source gbe_fork emulator, so SteamAPI_Init() succeeds
        // locally using the user's steamID + the appID — NO steam.exe, no
        // auth, no "Who's playing" window. Ownership is already proven (the
        // game was downloaded by DepotDownloader with the user's OAuth token).
        // DRM-free games skip this entirely.
        let needsDRM = prefix.gameRequiresSteamAPI(appID: game.id)

        // SteamStub exe encryption cannot be satisfied by the shim — the exe
        // itself is encrypted and only a running, signed-in Steam client can
        // decrypt it. Don't attempt a shim launch that would fail opaquely;
        // ask the user to switch this game to Online mode instead.
        if needsDRM, prefix.gameHasSteamStubDRM(appID: game.id) {
            log.info("[pipeline] appID=\(game.id) is SteamStub-encrypted — prompting for Online mode")
            appendLog("\(game.name) uses SteamStub DRM — the Steam client is required to run it")
            steamPrompt = .steamRequired(game)
            launchState = .idle
            currentActivity = nil
            return
        }

        if needsDRM {
            launchState = .launching(appID: game.id)
            currentActivity = "Preparing \(game.name)…"
            appendLog("Installing Steamworks compatibility shim for \(game.name)")
            do {
                try await prefix.installSteamEmulator(
                    appID: game.id,
                    steamID: steamID,
                    accountName: AppSettings.shared.steamCredentialAccountName,
                    personaName: steamAuth?.displayName ?? "",
                    engine: engine
                )
            } catch is CancellationError {
                launchState = .idle
                currentActivity = nil
                return
            } catch {
                fail("Couldn't prepare \(game.name) to run without Steam: \(error.localizedDescription)", error: error)
                return
            }
        }

        launchState = .launching(appID: game.id)
        currentActivity = "Launching \(game.name)…"
        appendLog("Launching \(game.name)")

        // Pause window suppression so the game window appears naturally.
        steamWindow?.pauseForGame()

        // Both DRM (now satisfied in-process by the Steamworks emulator shim)
        // and DRM-free games launch directly via `wine64 game.exe`. No
        // steam.exe, no Steam IPC. The steam.exe `-applaunch` path
        // (`SteamSession.ensureReadyForDRM` / `launchGameViaSteam`) is retained
        // as a documented fallback for SteamStub exe-encrypted titles the shim
        // can't satisfy, but is not used on the default launch path.
        if needsDRM {
            prefix.writeSteamAppID(game.id)
        }

        let result: GameLaunchResult
        do {
            result = try await launchDirect(game: game, engine: engine, session: session, drmShimActive: needsDRM)
        } catch {
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("Could not launch game: \(error.localizedDescription)", error: error)
            return
        }

        // Begin process monitoring. Pass the game's installdir as `gamePattern`
        // so detection uses `pgrep -f "<installdir>"` against the game's own
        // process — the game-specific path. With nil (the previous behaviour)
        // the monitor falls back to PID-set baseline tracking which can't see
        // the game's process when wineserver hands it off, leaving the user
        // stuck at "Launching…" until the 120 s timeout fires.
        let gamePattern = prefix.gameInstallDir(appID: game.id)
        if gamePattern == nil {
            log.warning("[pipeline] no installdir for appID=\(game.id) — monitor will use fallback PID-set detection")
        }
        gameProcess.startMonitoring(
            appID: game.id,
            launchedPID: result.pid,
            engine: engine,
            prefix: prefix,
            gamePattern: gamePattern,
            onLog: { [weak self] msg in
                // Already invoked on the main actor — GameProcess is
                // @MainActor and the monitor loop runs there.
                self?.currentActivity = msg
            }
        )

        // Don't flip `launchState` to `.running` until Phase 1 confirms the
        // game's own process is actually alive. Set state from observed
        // monitor outcome — never optimistically. UI stays in `.launching`
        // (showing "Launching <game>…") until the game is genuinely running
        // OR a real failure surfaces. Previously `.running` was set
        // immediately after `launchDirect` returned, so any silent crash
        // during startup left the UI claiming "running" while nothing was
        // visible — the symptom user reported May 19 2026.
        appendLog("Waiting for game to start")
        while gameProcess.monitorPhase == .startup {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
        }

        switch gameProcess.monitorPhase {
        case .running:
            AppSettings.shared.recordLaunch(appID: game.id)
            runningSince = Date()
            launchState = .running(appID: game.id)
            currentActivity = nil
            processesConfirmed = true
            appendLog("Game running")
            log.info("[pipeline] game confirmed running appID=\(game.id)")
        case .timedOut:
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "startup timeout (game process never appeared)", exitCode: nil)
            fail("\(game.name) didn't start in time. Check ~/Library/Application Support/com.meridian.app/logs/games/\(game.id).log for the game's own output.")
            return
        case .failed(let reason):
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "monitor failed: \(reason)", exitCode: nil)
            fail("\(game.name) couldn't start: \(reason)")
            return
        case .exited, .idle:
            // Game's startup phase completed without ever entering `.running`
            // — the game process either never appeared or appeared and
            // disappeared faster than the monitor's confirm window. Either
            // way the user sees nothing, so report it as a fast-exit.
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "game exited during startup phase before confirmation", exitCode: nil)
            fail("\(game.name) exited immediately. Check ~/Library/Application Support/com.meridian.app/logs/games/\(game.id).log for the game's own output.")
            return
        case .startup:
            // Cancelled during startup polling — task cancellation path.
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "launch cancelled by user during startup", exitCode: nil)
            launchState = .idle
            currentActivity = nil
            return
        }

        // Wait for runningPhase to detect normal exit. Polls until the
        // monitor leaves `.running` (becomes `.exited` or `.idle`).
        while gameProcess.monitorPhase == .running {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
        }

        steamWindow?.resumeAfterGame(steamPID: 0)
        closeActiveGameLog(reason: "game exited normally", exitCode: nil)
        launchState = .idle
        currentActivity = nil
        runningSince = nil
        activeAppID = nil
        appendLog("Game exited")
        log.info("[pipeline] game exited appID=\(game.id)")
    }

    // MARK: - Private: Online-mode launch (real Steam, -applaunch)

    /// Launches a game in Online mode: brings the real Steam client online in
    /// the background (authenticated from the QR/OAuth session), then dispatches
    /// `steam.exe -applaunch <appID>` via IPC. Steam owns the launch — cloud
    /// saves sync, online multiplayer works, EULAs are handled by Steam itself,
    /// and DRM verification is genuine. No Steam window is shown; the suppressor
    /// hides everything except user-actionable dialogs (EULA/purchase — A2).
    ///
    /// Unlike Offline mode we do NOT install the gbe_fork shim (that would make
    /// the game talk to a local emulator instead of Valve) and we do NOT
    /// `launchDirect` — Steam picks the exe and applies launch options itself,
    /// which also avoids the "launching with custom args" dialog for UE
    /// launcher chains (Pattern 20).
    private func launchOnline(game: Game, engine: WineEngine, session: SteamSession) async {
        // First-time Online on this prefix: no Steam-written session exists,
        // so a ONE-TIME interactive sign-in (a real Steam window) is needed.
        // Never open a Steam window without asking first — raise the consent
        // prompt and bail; `confirmSteamPrompt` re-enters with approval.
        let hasSession = prefix.hasSteamLoginSession()
        let approved = approvedInteractiveSignInAppID == game.id
        approvedInteractiveSignInAppID = nil // one-shot
        if !hasSession && !approved {
            log.info("[launchOnline] no Steam session on disk — prompting for one-time sign-in")
            steamPrompt = .signInRequired(game)
            launchState = .idle
            currentActivity = nil
            return
        }

        launchState = .launching(appID: game.id)
        currentActivity = "Connecting to Steam…"
        appendLog("Online mode: bringing Steam online for \(game.name)")

        do {
            if !hasSession {
                // User approved the one-time interactive sign-in. Steam's own
                // login window renders; Steam persists its own session, so
                // every later Online launch takes the silent path below.
                try await session.signInInteractively(engine: engine) { [weak self] status in
                    self?.currentActivity = status
                }
            } else {
                do {
                    try await session.ensureReadyForDRM(engine: engine) { [weak self] status in
                        self?.currentActivity = status
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The on-disk session went stale (Valve rejected it or the
                    // silent auth timed out). Retry DIFFERENTLY (fail-fast
                    // rule): fall back to the interactive sign-in so the user
                    // can re-establish a session Steam itself persists.
                    log.warning("[launchOnline] silent auth failed (\(error.localizedDescription)) — falling back to interactive sign-in")
                    appendLog("Steam session expired — opening Steam sign-in")
                    currentActivity = "Steam sign-in required…"
                    try await session.signInInteractively(engine: engine) { [weak self] status in
                        self?.currentActivity = status
                    }
                }
            }
        } catch is CancellationError {
            // Tear Steam down so a cancelled bring-up doesn't leave steam.exe /
            // steamwebhelper running with a visible sign-in window.
            await session.shutdown(engine: engine)
            launchState = .idle
            currentActivity = nil
            return
        } catch {
            // Neither silent auto-login nor the interactive sign-in reached
            // [Logged On,]. Tear the whole Steam runtime down before surfacing
            // the error so no Steam UI is ever left on screen
            // (development-standards: Steam UI is never shown). Offline mode
            // remains the working default.
            await session.shutdown(engine: engine)
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("Steam couldn't sign in to launch \(game.name) online. Switch this game to Offline mode to play now. (Online mode needs a completed Steam sign-in.)", error: error)
            return
        }

        currentActivity = "Launching \(game.name) through Steam…"
        appendLog("Dispatching -applaunch \(game.id)")
        // Let the game window appear (suppressor keeps hiding Steam chrome but
        // A2's allowlist surfaces any EULA/purchase dialog Steam raises).
        steamWindow?.pauseForGame()
        do {
            try session.launchGameViaSteam(appID: game.id, engine: engine)
        } catch {
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("Could not launch \(game.name) through Steam: \(error.localizedDescription)", error: error)
            return
        }

        // Steam owns the process tree in Online mode. Monitor via the game's
        // install dir so we still detect the running game + its exit, but the
        // game's stdout/stderr is owned by Steam (Pattern 20) — the engine log
        // under the install dir remains the authoritative diagnostic source.
        let gamePattern = prefix.gameInstallDir(appID: game.id)
        gameProcess.startMonitoring(
            appID: game.id,
            launchedPID: 0,
            engine: engine,
            prefix: prefix,
            gamePattern: gamePattern,
            onLog: { [weak self] msg in self?.currentActivity = msg }
        )

        appendLog("Waiting for game to start")
        while gameProcess.monitorPhase == .startup {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
        }

        switch gameProcess.monitorPhase {
        case .running:
            AppSettings.shared.recordLaunch(appID: game.id)
            runningSince = Date()
            launchState = .running(appID: game.id)
            currentActivity = nil
            processesConfirmed = true
            appendLog("Game running (Online mode)")
        case .timedOut, .exited, .idle, .failed:
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("\(game.name) didn't start through Steam. Check logs/games/\(game.id).log, or try Offline mode.")
            return
        case .startup:
            steamWindow?.resumeAfterGame(steamPID: 0)
            launchState = .idle
            currentActivity = nil
            return
        }

        while gameProcess.monitorPhase == .running {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
        }
        steamWindow?.resumeAfterGame(steamPID: 0)
        launchState = .idle
        currentActivity = nil
        runningSince = nil
        activeAppID = nil
        appendLog("Game exited")
    }

    // MARK: - Private: headless install (DepotDownloader)

    /// Installs an owned game headlessly via the DepotDownloader fork — no
    /// `steam.exe`, no Steam UI. Authenticates with Meridian's OAuth
    /// `refresh_token` (the same token Wine's `steam.exe` rejects but SteamKit2
    /// accepts), downloads depot files into `steamapps/common/<name>/`, and on
    /// success writes a `StateFlags=4` appmanifest so the rest of the app
    /// (launch, uninstall, installed-state) reads the game as installed.
    private func installHeadless(game: Game, engine: WineEngine, steamID: String) async throws {
        let token = AppSettings.shared.steamCredentialRefreshToken
        let account = AppSettings.shared.steamCredentialAccountName
        guard !token.isEmpty, !account.isEmpty else {
            throw InstallError.notSignedIn
        }
        guard let binary = engine.depotDownloaderURL else {
            throw InstallError.installerMissing
        }

        let installDirName = game.name
        let installDir = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDirName)")

        let resuming = prefix.isGameInstalled(appID: game.id)
            || FileManager.default.fileExists(atPath: installDir.path(percentEncoded: false))
        launchState = .installing(appID: game.id)
        currentActivity = resuming
            ? "Resuming download for \(game.name)…"
            : "Preparing download for \(game.name)…"
        downloadProgress = nil
        downloadBytesDone = 0
        downloadBytesTotal = 0
        downloadRateBps = 0
        appendLog("Starting install for \(game.name)")

        // Rate smoothing across progress callbacks.
        var lastBytes: Int64 = 0
        var lastSampleAt = ContinuousClock.now

        let downloaded = try await DepotDownloaderInstall.run(
            binary: binary,
            appID: game.id,
            installDir: installDir,
            username: account,
            refreshToken: token,
            onPhase: { [weak self] phase, _ in
                guard let self else { return }
                switch phase {
                case "connecting": self.currentActivity = "Connecting to Steam…"
                case "loggedon":   self.currentActivity = "Starting download for \(game.name)…"
                default:           break
                }
            },
            onProgress: { [weak self] done, total, _ in
                guard let self else { return }
                if case .downloading = self.launchState {} else {
                    self.launchState = .downloading(appID: game.id)
                }
                self.downloadBytesDone = done
                self.downloadBytesTotal = total
                let fraction = total > 0 ? min(1.0, Double(done) / Double(total)) : 0
                self.downloadProgress = total > 0 ? fraction : nil

                let now = ContinuousClock.now
                let elapsed = now - lastSampleAt
                if elapsed >= .seconds(1) {
                    let secs = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) * 1e-18
                    if secs > 0 {
                        let instant = Double(done - lastBytes) / secs
                        self.downloadRateBps = self.downloadRateBps == 0
                            ? instant
                            : (0.7 * self.downloadRateBps + 0.3 * instant)
                    }
                    lastBytes = done
                    lastSampleAt = now
                }

                let pctInt = Int(fraction * 100)
                let doneMB = done / (1024 * 1024)
                let totalMB = total / (1024 * 1024)
                let rateText = self.downloadRateBps > 0
                    ? String(format: " · %.1f MB/s", self.downloadRateBps / (1024 * 1024))
                    : ""
                self.currentActivity = total > 0
                    ? "Downloading \(game.name)… \(pctInt)% (\(doneMB) / \(totalMB) MB\(rateText))"
                    : "Downloading \(game.name)…"
            }
        )

        // DepotDownloader writes no ACF — write a StateFlags=4 manifest so the
        // launch path, uninstall, and installed-state checks all read the game
        // as installed.
        try prefix.writeInstalledAppManifest(
            appID: game.id,
            name: game.name,
            installDir: installDirName,
            steamID64: steamID,
            sizeOnDisk: downloaded
        )

        downloadProgress = 1.0
        downloadRateBps = 0
        currentActivity = "\(game.name) installed"
        appendLog("\(game.name) install complete (\(downloaded / (1024 * 1024)) MB)")
        log.info("[installHeadless] ✓ appID=\(game.id) bytes=\(downloaded)")
    }

    // MARK: - Private: launch via wine64

    private func launchDirect(
        game: Game,
        engine: WineEngine,
        session: SteamSession,
        drmShimActive: Bool
    ) async throws -> GameLaunchResult {
        guard let installDir = prefix.gameInstallDir(appID: game.id) else {
            throw LaunchError.noInstallDir(game.id)
        }

        let gamePath = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDir)")
        let gamePathStr = gamePath.path(percentEncoded: false)

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: gamePathStr) else {
            throw LaunchError.cannotListDir(gamePathStr)
        }

        let exeFiles = contents.filter { $0.hasSuffix(".exe") }
            .filter {
                let lower = $0.lowercased()
                return !lower.contains("crash") && !lower.contains("redist") && !lower.contains("unins")
            }

        guard let mainExe = exeFiles.first(where: { !$0.lowercased().contains("unity") }) ?? exeFiles.first else {
            throw LaunchError.noExecutable(gamePathStr)
        }

        let exePath = gamePath.appending(path: mainExe).path(percentEncoded: false)
        log.info("[launch] appID=\(game.id) exe=\(exePath)")

        let compat = GameCompatibilityDB.shared
        let profile = compat.profile(for: game.id)
        let launchArgs = profile?.launchArgs ?? []

        // Warm the stack resolver (local file detection + cached PCGamingWiki
        // enrichment, merged with any explicit compat profile) BEFORE building
        // the env, so `gameEnvironment` can route a detected/PCGW DX12 game
        // through GPTK even when it has no hand-written compat entry. On a
        // network failure / offline this still returns local-only detection;
        // on a cold cache `gameEnvironment` falls back to prior behaviour.
        let resolvedStack = await GameStackResolver.shared.resolve(appID: game.id, installDir: gamePath)

        let env = session.gameEnvironment(for: game.id, engine: engine)

        // Resolve the graphics/translation stack from the FINAL env (+ the
        // merged metadata) and log a one-liner to meridian.log + embed a detail
        // block in the per-game header. This makes "what stack did this game
        // run with?" answerable at a glance — active renderer (DXMT / GPTK /
        // DXVK / wined3d), translation layer, bitness, DRM shim, Metal HUD,
        // compat status, and the provenance of each fact.
        let stackReport = GameStackReport.resolve(
            appID: game.id,
            gameName: game.name,
            profile: profile,
            resolved: resolvedStack,
            environment: env,
            drmShimActive: drmShimActive,
            engineVersion: engine.engineVersion
        )
        log.info("[launch] \(stackReport.summaryLine)")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.currentDirectoryURL = gamePath
        process.arguments = [exePath] + launchArgs
        process.environment = env

        // Record session context so the engine-log collector (run on exit in
        // closeActiveGameLog) knows which install dir to scan for Unreal logs
        // and which launch instant to filter Unity Player.log freshness
        // against. Without launchStartedAt we could copy a stale log from a
        // previous run.
        activeGameInstallDir = gamePath
        activeLaunchStartedAt = Date()

        // Per-game log: hand Wine a kernel-level FileHandle for stdout and
        // stderr. The Wine subprocess tree writes every byte directly to
        // disk; no Meridian-side draining required. This avoids the
        // availableData blocking issue (Pattern 1 in
        // engine-research-findings.mdc) AND gives us a complete game log
        // even when wineserver outlives the parent wine64 process.
        let logHandle = GameLogFile.beginSession(
            appID: game.id,
            gameName: game.name,
            executable: exePath,
            launchArgs: launchArgs,
            environment: env,
            stackReport: stackReport
        )
        activeGameLogHandle = logHandle
        if let logHandle {
            process.standardOutput = logHandle
            process.standardError = logHandle
            log.info("[launch] per-game log → \(GameLogFile.currentURL(for: game.id).path(percentEncoded: false))")
        } else {
            // Fallback: black-hole both streams. Better than reintroducing
            // a Pipe that may block; the user can still read meridian.log
            // for Wine errors that bubble up through other layers.
            log.warning("[launch] per-game log unavailable — stderr will not be captured")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        try process.run()
        let pid = process.processIdentifier
        log.info("[launch] pid=\(pid)")

        return GameLaunchResult(pid: pid, process: process)
    }

    /// Append a `Reason:` trailer to the active per-game log and release
    /// the file handle. Called from every exit path of `executePipeline`.
    /// Safe to call when no log is active.
    private func closeActiveGameLog(reason: String, exitCode: Int32?) {
        guard let handle = activeGameLogHandle else { return }
        let appID = activeAppID ?? 0

        // Collect the game's own engine log (Unity Player.log / Unreal
        // Saved/Logs) for this session into <appID>-engine.log BEFORE writing
        // the trailer, so the diagnostic artifact is captured even on the
        // crash / timeout / fast-exit paths — exactly when it's most needed.
        let lowLevelDir = prefix.driveC
            .appending(path: "users/crossover/AppData/LocalLow")
        GameLogFile.collectEngineLogs(
            appID: appID,
            lowLevelDir: lowLevelDir,
            installDir: activeGameInstallDir,
            launchStartedAt: activeLaunchStartedAt
        )

        GameLogFile.endSession(
            handle: handle,
            appID: appID,
            reason: reason,
            exitCode: exitCode
        )
        activeGameLogHandle = nil
        activeGameInstallDir = nil
        activeLaunchStartedAt = nil
    }

    // MARK: - Private: uninstall

    private func uninstallGame(game: Game, engine: WineEngine) async throws {
        log.info("[uninstall] appID=\(game.id)")
        let fm = FileManager.default

        // Resolve the ACF via `prefix.acfURL` — it searches each library
        // folder's `steamapps/` subdir (the correct location). Previously
        // this function searched `<library>/appmanifest_*.acf` directly,
        // missing the `steamapps/` prefix; result was that EVERY uninstall
        // attempt logged `ACF not found — nothing to remove` even though
        // the ACF was right there on disk. CLI-confirmed user report
        // May 20 2026.
        //
        // We capture the install dir BEFORE removing the ACF — `gameInstallDir`
        // reads the ACF for the `installdir` field, so once the ACF is gone
        // we can no longer derive the real install path.
        let installDirFromACF = prefix.gameInstallDir(appID: game.id)

        guard let acfURL = prefix.acfURL(for: game.id) else {
            // Even with no ACF, the game files may still exist on disk
            // (orphan dir from a partial uninstall, or a manual install).
            // Try a best-effort cleanup using the display name as fallback.
            let installDir = installDirFromACF ?? game.name
            let gameDir = prefix.steamInstallDir
                .appending(path: "steamapps/common/\(installDir)")
                .path(percentEncoded: false)
            if fm.fileExists(atPath: gameDir) {
                try fm.removeItem(atPath: gameDir)
                log.info("[uninstall] no ACF; removed orphan game dir: \(gameDir)")
            } else {
                log.info("[uninstall] no ACF and no game dir — nothing to remove for appID=\(game.id)")
            }
            return
        }

        let acfPath = acfURL.path(percentEncoded: false)
        let installDir = installDirFromACF ?? game.name
        let gameDir = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDir)")
            .path(percentEncoded: false)

        // Order: game files first, then ACF. If the game-dir removal
        // fails (permissions, in-use), the ACF still reflects "installed"
        // and we don't end up in an inconsistent state where Steam thinks
        // the game is gone but multi-GB of files linger.
        if fm.fileExists(atPath: gameDir) {
            try fm.removeItem(atPath: gameDir)
            log.info("[uninstall] removed game dir: \(gameDir)")
        }
        // Also clean any incomplete download under steamapps/downloading/<id>/
        let downloadingDir = prefix.steamInstallDir
            .appending(path: "steamapps/downloading/\(game.id)")
            .path(percentEncoded: false)
        if fm.fileExists(atPath: downloadingDir) {
            try? fm.removeItem(atPath: downloadingDir)
            log.info("[uninstall] removed in-flight download dir: \(downloadingDir)")
        }
        try fm.removeItem(atPath: acfPath)
        log.info("[uninstall] removed ACF: \(acfPath)")
    }

    // MARK: - Private: helpers

    private func fail(_ message: String, error: Error? = nil) {
        log.error("[pipeline] failed: \(message)")
        launchState = .failed(message)
        currentActivity = nil
        downloadProgress = nil
        appendLog("Error: \(message)")
    }

    private func appendLog(_ line: String) {
        logs.append(line)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }

}

extension Launcher {
    var isInstalling: Bool {
        switch launchState {
        case .installing, .downloading: return true
        default: return false
        }
    }
    var isLaunching: Bool {
        switch launchState {
        case .launching: return true
        default: return false
        }
    }
    var isRunning: Bool {
        switch launchState {
        case .running: return true
        default: return false
        }
    }
    var isBusy: Bool {
        switch launchState {
        case .idle, .failed: return false
        default: return true
        }
    }
}

// MARK: - Errors

enum LaunchError: LocalizedError {
    case noInstallDir(Int)
    case cannotListDir(String)
    case noExecutable(String)

    var errorDescription: String? {
        switch self {
        case .noInstallDir(let id):  return "Cannot find install directory for appID \(id)."
        case .cannotListDir(let p):  return "Cannot list game directory: \(p)"
        case .noExecutable(let p):   return "No game executable found in \(p)"
        }
    }
}

enum InstallError: LocalizedError {
    case notSignedIn
    case installerMissing

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Not signed in to Steam. Please sign in before installing games."
        case .installerMissing:
            return "The game installer component is missing. Re-download the engine from Settings."
        }
    }
}

// MARK: - GameLaunchResult

struct GameLaunchResult: Sendable {
    let pid: Int32
    let process: Process
}
