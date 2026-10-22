import Foundation
import AppKit
import Observation

private let log = MeridianLog(category: "Launcher")

// MARK: - Launcher

/// Orchestrates game installs and launches. Does NOT own steam.exe.
///
/// - Installs run headlessly via the DepotDownloader fork (`installHeadless`)
///   using the persisted OAuth refresh_token — no steam.exe involvement.
/// - Every launch goes through the real Steam client, started silently
///   (`launchOnline` → `SteamSession.launchGameViaSteam`, `-applaunch`), so
///   cloud saves, achievements and multiplayer always work. The Offline mode
///   (gbe_fork Steamworks emulator + direct wine64 exec) was removed Oct 8
///   2026.
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
        /// Launching needs a ONE-TIME interactive Steam sign-in (no
        /// Steam-written session exists on this prefix yet). Explain that a
        /// Steam window will open once before actually opening it.
        case signInRequired(Game)

        var game: Game {
            switch self {
            case .signInRequired(let g): return g
            }
        }
    }

    private(set) var steamPrompt: SteamPrompt?

    /// One-shot approval for the interactive sign-in, set when the user
    /// confirms a prompt. Consumed (reset) by the next `launchOnline` run so
    /// a later cold launch re-prompts instead of silently opening Steam.
    private var approvedInteractiveSignInAppID: Int?

    /// User confirmed the pending prompt: mark the interactive sign-in as
    /// approved and re-enter the launch pipeline.
    func confirmSteamPrompt(
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        guard let prompt = steamPrompt else { return }
        steamPrompt = nil
        let game = prompt.game
        approvedInteractiveSignInAppID = game.id
        launch(game: game, engine: engine, session: session, steamAuth: steamAuth, library: library)
    }

    func dismissSteamPrompt() {
        steamPrompt = nil
    }

    // MARK: - License agreements (shown by Meridian, recorded for Steam)

    /// A game's license agreements the player hasn't accepted. Meridian shows
    /// them in its own sheet before Steam starts the game; Steam's dialog
    /// would open its whole library window (Pattern 47).
    struct EulaPrompt: Identifiable, Equatable {
        let game: Game
        let eulas: [SteamEula]
        var id: Int { game.id }
    }

    private(set) var eulaPrompt: EulaPrompt?

    /// The player accepted every agreement in the sheet: hand the answers to
    /// Steam (written before it next starts) and launch again.
    func acceptEulas(
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        guard let prompt = eulaPrompt else { return }
        eulaPrompt = nil
        log.info("[eula] accepted \(prompt.eulas.map(\.id).joined(separator: ", ")) for appID=\(prompt.game.id)")
        session.recordEulaAcceptances(prompt.eulas)
        launch(game: prompt.game, engine: engine, session: session, steamAuth: steamAuth, library: library)
    }

    /// The player declined: nothing is recorded and the game doesn't start.
    func declineEulas() {
        if let prompt = eulaPrompt {
            log.info("[eula] declined for appID=\(prompt.game.id)")
        }
        eulaPrompt = nil
    }

    // MARK: - Steam Cloud sync failures (asked by Meridian)

    /// Steam couldn't sync a game's cloud saves before starting it and waits
    /// on the player (`SynchronizingCloud "syncfailed"`). Meridian asks in
    /// its own sheet while Steam's dialog stays hidden: Steam's would open
    /// its whole library window (Pattern 66).
    struct CloudSyncPrompt: Identifiable, Equatable {
        let game: Game
        var id: Int { game.id }
    }

    private(set) var cloudSyncPrompt: CloudSyncPrompt?

    /// The player's answer, read by the launch loop holding for it.
    private enum CloudSyncAnswer { case tryAgain, cancel, decideInSteam }
    private var cloudSyncAnswer: CloudSyncAnswer?
    /// Launches the game again after Try Again, once Steam has quit.
    private var cloudSyncRelaunch: (() -> Void)?

    /// Try Again: quitting Steam closes its dialog, and the game launches
    /// again, so Steam syncs again.
    func retryCloudSync(
        engine: WineEngine,
        session: SteamSession,
        steamAuth: SteamAuthService? = nil,
        library: SteamLibraryStore? = nil
    ) {
        guard let prompt = cloudSyncPrompt else { return }
        cloudSyncPrompt = nil
        cloudSyncRelaunch = { [weak self] in
            self?.launch(game: prompt.game, engine: engine, session: session, steamAuth: steamAuth, library: library)
        }
        cloudSyncAnswer = .tryAgain
    }

    /// Cancel: quitting Steam closes its dialog; the game doesn't start.
    func cancelCloudSync() {
        guard cloudSyncPrompt != nil else { return }
        cloudSyncPrompt = nil
        cloudSyncAnswer = .cancel
    }

    /// Play Anyway can only be answered in Steam, so its dialog is shown.
    func decideCloudSyncInSteam() {
        guard cloudSyncPrompt != nil else { return }
        cloudSyncPrompt = nil
        cloudSyncAnswer = .decideInSteam
    }

    private(set) var launchState: LaunchState = .idle
    private(set) var currentActivity: String?
    /// The few beats the launch card names. Steam reports a dozen statuses on
    /// its way up; the player only needs to know which of these is happening,
    /// so the card's headline changes only when the beat does. The usual
    /// launch is just `gettingReady` then `startingGame`; the rest are the
    /// moments worth explaining.
    enum LaunchPhase: Equatable {
        case gettingReady, settingUpSteam, updatingSteam, startingGame, checkingFiles
    }

    /// Staged launch progress for the launch card. The phase follows the
    /// LATEST recognized status marker; the fraction is monotonic per
    /// pipeline run (only fills, never regresses) so the bar reads as steady
    /// forward progress even when statuses alternate (e.g. "validating" ↔
    /// "waiting for game").
    private(set) var launchPhase: LaunchPhase = .gettingReady
    private(set) var launchStageFraction: Double = 0

    /// Why the launch is waiting on Steam's own sign-in, while it does; nil
    /// otherwise. The card says so and holds the bar still.
    enum SteamSignIn: Equatable {
        /// Steam was never signed in on this Mac (the player said yes to
        /// `SteamPrompt.signInRequired`), or didn't sign in on its own.
        case required
        /// Valve rejected Steam's saved sign-in (Pattern 42).
        case signedOut
    }
    private(set) var steamSignIn: SteamSignIn?
    /// A short, happy line under "Starting the game…": what Steam is doing for
    /// the launch, from its own console log. nil outside that beat.
    private(set) var launchStep: String?
    /// The step Steam is waiting on the player for mid-launch (`ShowEula`),
    /// while its window is shown; nil otherwise. The card asks for it.
    private(set) var steamWaitingOnPlayer: String?
    private(set) var downloadProgress: Double?
    /// The install in progress brings an installed game up to date rather
    /// than downloading it from scratch: the UI says "Updating".
    private(set) var installIsUpdate = false
    private(set) var downloadBytesDone: Int64 = 0
    private(set) var downloadBytesTotal: Int64 = 0
    private(set) var downloadRateBps: Double = 0

    /// "1.2 GB of 4.5 GB · 12.3 MB/s" while bytes are flowing, nil before.
    var downloadProgressText: String? {
        guard isInstalling, downloadBytesTotal > 0 else { return nil }
        let style = ByteCountFormatStyle(style: .file)
        var text = "\(downloadBytesDone.formatted(style)) of \(downloadBytesTotal.formatted(style))"
        if downloadRateBps > 0 {
            text += " · \(Int64(downloadRateBps).formatted(style))/s"
        }
        return text
    }
    private(set) var logs: [String] = []
    private(set) var activeAppID: Int?
    private(set) var processesConfirmed: Bool = false
    private(set) var runningSince: Date?

    private let gameProcess = GameProcess()
    private let prefix = WinePrefix.defaultPrefix
    private var launchTask: Task<Void, Never>?

    /// Per-game log file handle, opened in `launchOnline` and closed on
    /// every exit path (`closeActiveGameLog`).
    private var activeGameLogHandle: FileHandle?

    /// The game's `steamapps/common/<dir>` directory for the active session,
    /// and the instant its process started. Used by `closeActiveGameLog` to
    /// collect the game's own engine log (Unity `Player.log` / Unreal
    /// `Saved/Logs`) for THIS session into `<appID>-engine.log`.
    private var activeGameInstallDir: URL?
    private var activeLaunchStartedAt: Date?
    /// Where the Steam output file (GameLogFile.steamOutputURL) stood when
    /// the game was handed to Steam; the rest is this session's Wine output.
    private var activeSteamOutputOffset: UInt64?

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
        // Stop the process monitor too — its onLog callback would otherwise
        // keep overwriting currentActivity with "Waiting for game to start…"
        // long after the user cancelled (Bug D, HANDOFF-2026-07-02-v4).
        gameProcess.cancelMonitoring()
        closeActiveGameLog(reason: "user cancelled launch", exitCode: nil)
        launchState = .idle
        currentActivity = nil
        resetLaunchStage()
        downloadProgress = nil
        downloadBytesDone = 0
        downloadBytesTotal = 0
        downloadRateBps = 0
        activeAppID = nil
    }

    // Stored reference to session for cancelInstall forwarding.
    private weak var activeSession: SteamSession?

    func stopGame(engine: WineEngine) {
        switch launchState {
        case .running(let appID):
            launchState = .stopping(appID: appID)
            currentActivity = "Stopping game…"
            // Steam shares the prefix's wineserver. `wineserver -k` while a
            // persistent Steam session is alive SIGKILLs steam.exe +
            // steamwebhelper — CEF then treats the next Steam boot as crash
            // recovery and surfaces webhelper windows, and the health
            // monitor's non-42 exit left a stale `.running` session state
            // (user-reported "steamwebhelper opens a lot… hit quit early",
            // Jul 3 2026). Kill only the game's own processes whenever Steam
            // is alive; full wineserver -k only when nothing else shares it.
            let steamAlive = activeSession?.isReady == true
            let gamePattern = prefix.gameInstallDir(appID: appID)
            Task { [weak self] in
                guard let self else { return }
                if steamAlive, let pattern = gamePattern {
                    await gameProcess.killGameProcesses(pattern: pattern)
                } else {
                    if steamAlive {
                        log.warning("[stopGame] no installdir pattern for appID=\(appID) — falling back to wineserver -k (kills Steam)")
                    }
                    await gameProcess.stopGame(engine: engine, prefix: prefix)
                }
                // Restore blanket suppression — this was missing here, so a
                // stop-while-running left the suppressor paused or
                // in game mode (Online) indefinitely, letting steamwebhelper
                // windows surface at will.
                steamWindow?.resumeAfterGame(steamPID: 0)
                closeActiveGameLog(reason: "user requested stop", exitCode: nil)
                launchState = .idle
                currentActivity = nil
                resetLaunchStage()
                activeAppID = nil
            }

        case .launching(let appID):
            // Stop during a launch in flight (previously a silent no-op —
            // Bug D, HANDOFF-2026-07-02-v4). Cancel the pipeline task first
            // so its wait loops exit, then tear down what the launch started.
            launchTask?.cancel()
            launchState = .stopping(appID: appID)
            currentActivity = "Stopping…"
            let gamePattern = prefix.gameInstallDir(appID: appID)
            Task { [weak self] in
                guard let self else { return }
                // Steam owns the process tree; killing wineserver would take
                // the persistent Steam session down with it. Stop tracking,
                // keep Steam alive in the background (if it is mid-validation,
                // letting it finish helps the next Play).
                gameProcess.cancelMonitoring()
                // Best-effort: if Steam already spawned the game before the
                // stop, kill it — otherwise it keeps running with its window
                // hidden by the resumed blanket suppression.
                if let pattern = gamePattern {
                    await gameProcess.killGameProcesses(pattern: pattern)
                }
                steamWindow?.resumeAfterGame(steamPID: 0)
                closeActiveGameLog(reason: "user stopped launch in flight", exitCode: nil)
                launchState = .idle
                currentActivity = nil
                resetLaunchStage()
                activeAppID = nil
            }

        default:
            return
        }
    }

    func uninstall(game: Game, library: SteamLibraryStore) {
        launchTask?.cancel()
        launchTask = Task { [weak self] in
            guard let self else { return }
            // This game's page shows the progress, and a failure with Reset.
            activeAppID = game.id
            launchState = .uninstalling
            currentActivity = "Uninstalling \(game.name)…"
            let prefix = self.prefix
            do {
                // Gigabytes of files: deleted off the main actor, which this
                // used to block until the whole folder was gone.
                try await Task.detached(priority: .userInitiated) {
                    try Self.uninstallGame(game: game, prefix: prefix)
                }.value
                // The library follows at once, not at its next disk poll
                // (LibraryView animates the change).
                library.setInstalled(false, for: game.id)
                launchState = .idle
                activeAppID = nil
            } catch {
                launchState = .failed(error.localizedDescription)
            }
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
        installIsUpdate = false
        runningSince = nil
        processesConfirmed = false
        resetLaunchStage()

        let steamID = steamAuth?.steamID ?? AppSettings.shared.steamCredentialSteamID

        // Install or update if needed — headless via the DepotDownloader fork
        // (no steam.exe), unless Steam is already updating the game itself.
        let installState = prefix.installState(appID: game.id)
        if installState != .installed {
            installIsUpdate = installState == .updateRequired
            do {
                if installIsUpdate, session.isReady, prefix.isSteamDownloading(appID: game.id) {
                    try await waitForSteamUpdate(game: game, session: session)
                }
                if prefix.installState(appID: game.id) != .installed {
                    try await installHeadless(game: game, engine: engine, steamID: steamID)
                }
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
            // Steam up (or restarted) with the new game now, so its first
            // Play doesn't wait on Steam.
            session.warmUp(engine: engine, appID: game.id)
            return
        }

        // Every game launches through the real Steam client (`-applaunch`),
        // so cloud saves, achievements and multiplayer always work. Offline
        // (a local Steamworks emulator, or no Steam at all) was removed
        // Oct 8 2026: it cost cloud saves and achievements.
        await launchOnline(game: game, engine: engine, session: session, library: library)
    }

    // MARK: - Private: Online-mode launch (real Steam, -applaunch)

    /// Launches a game: brings the real Steam client online in
    /// the background (authenticated from the QR/OAuth session), then dispatches
    /// `steam.exe -applaunch <appID>` via IPC. Steam owns the launch — cloud
    /// saves sync, online multiplayer works, EULAs are handled by Steam itself,
    /// and DRM verification is genuine. No Steam window is shown; the suppressor
    /// hides everything except user-actionable dialogs (EULA/purchase — A2).
    ///
    /// Steam picks the exe and applies launch options itself, which also
    /// avoids the "launching with custom args" dialog for UE launcher chains
    /// (Pattern 20).
    private func launchOnline(game: Game, engine: WineEngine, session: SteamSession, library: SteamLibraryStore?) async {
        // First-time Online on this prefix: no Steam-written session exists,
        // so a ONE-TIME interactive sign-in (a real Steam window) is needed.
        // Never open a Steam window without asking first — raise the consent
        // prompt and bail; `confirmSteamPrompt` re-enters with approval.
        // Meridian records Steam's own sign-in (it doesn't inspect Steam's
        // files): Steam's saved login doesn't set loginusers.vdf MostRecent,
        // so that file check asked again right after a successful sign-in.
        let hasSession = AppSettings.shared.steamClientSignedIn
        // Valve ended Steam's saved sign-in, found by the background warm-up
        // or an earlier launch: go straight to Steam's sign-in (as a launch
        // that finds it does) rather than booting Steam into a rejection again.
        let signedOut = session.state == .signedOut
        let approved = approvedInteractiveSignInAppID == game.id
        approvedInteractiveSignInAppID = nil // one-shot
        if !hasSession && !approved && !signedOut {
            log.info("[launchOnline] no Steam session on disk — prompting for one-time sign-in")
            steamPrompt = .signInRequired(game)
            launchState = .idle
            currentActivity = nil
            return
        }

        // The game's license agreement, asked in Meridian's own sheet.
        let appID = game.id
        let appInfoURL = prefix.appInfoCacheURL
        let localConfigURL = prefix.localConfigURL(steamID64: AppSettings.shared.steamCredentialSteamID)
        let pending = session.pendingEulaAcceptances
        if let localConfigURL {
            let unaccepted = await Task.detached(priority: .userInitiated) {
                SteamEula.unaccepted(appID: appID, appInfo: appInfoURL, localConfig: localConfigURL, pending: pending)
            }.value
            if !unaccepted.isEmpty {
                log.info("[launchOnline] \(game.name) needs \(unaccepted.map(\.id).joined(separator: ", ")) accepted — asking")
                eulaPrompt = EulaPrompt(game: game, eulas: unaccepted)
                launchState = .idle
                currentActivity = nil
                return
            }
        }

        launchState = .launching(appID: game.id)
        setLaunchActivity("Connecting to Steam…")
        appendLog("Online mode: bringing Steam online for \(game.name)")

        do {
            if signedOut {
                try await signInToSteam(.signedOut, appID: game.id, session: session, engine: engine)
            } else if !hasSession {
                // User approved the one-time interactive sign-in. Steam's own
                // login window renders; Steam persists its own session, so
                // every later Online launch takes the silent path below.
                try await signInToSteam(.required, appID: game.id, session: session, engine: engine)
            } else {
                do {
                    try await session.ensureReadyForDRM(engine: engine, appID: game.id) { [weak self] status in
                        self?.setLaunchActivity(status)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch SessionError.signedOut where !Task.isCancelled {
                    // Steam's saved sign-in no longer works. The player already
                    // pressed Play, so go straight to Steam's sign-in in this
                    // same launch: the card says Steam signed them out and the
                    // bar holds where it is. An alert followed by a fresh
                    // launch read as a restart (user, Oct 11 2026).
                    log.info("[launchOnline] Steam signed out, opening Steam's sign-in")
                    appendLog("Steam signed you out, opening Steam's sign-in")
                    try await signInToSteam(.signedOut, appID: game.id, session: session, engine: engine)
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    // Silent auth failed for another reason (timeout, wedged
                    // webhelper). Retry DIFFERENTLY (fail-fast rule): fall
                    // back to the interactive sign-in so the user can
                    // re-establish a session Steam itself persists.
                    log.warning("[launchOnline] silent auth failed (\(error.localizedDescription)) — falling back to interactive sign-in")
                    appendLog("Steam didn't sign in on its own, opening Steam's sign-in")
                    try await signInToSteam(.required, appID: game.id, session: session, engine: engine)
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
            if Task.isCancelled {
                // Stop button mid-bring-up surfaced as a non-cancellation
                // error (e.g. steamNotReady from an interrupted logon wait).
                // Treat it as a cancel: tear the sign-in window down and
                // return to idle — never .failed (Bug D).
                await session.shutdown(engine: engine)
                launchState = .idle
                currentActivity = nil
                return
            }
            // Neither silent auto-login nor the interactive sign-in reached
            // [Logged On,] — Steam failed to start or to sign in (the log has
            // which). Tear the whole Steam runtime down before surfacing the
            // error so no Steam UI is ever left on screen
            // (development-standards: Steam UI is never shown).
            await session.shutdown(engine: engine)
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("Meridian couldn't connect to Steam to launch \(game.name). Please try again.", error: error)
            return
        }

        setLaunchActivity("Launching \(game.name) through Steam…")
        launchStep = "Handing off to Steam"
        appendLog("Dispatching -applaunch \(game.id)")
        // Game-mode suppression: Steam chrome (steam.exe / steamwebhelper
        // windows, including the main window left over from an interactive
        // sign-in) keeps getting hidden, while the game's own Wine process is
        // exempt so its window appears naturally. The allowlist still surfaces
        // any EULA/purchase dialog Steam raises. The previous blanket
        // suppression pause here disabled ALL hiding and let Steam's full
        // post-login UI stay on screen (Bug A, HANDOFF-2026-07-02-v4).
        steamWindow?.enterGameMode()
        // Per-game log: a header now, and at exit the game's own engine log
        // (Unity Player.log). Wine's output goes to Steam, which owns the
        // game's process (Pattern 20).
        let arguments = await launchArguments(for: game, engine: engine)
        await applyGameEnvironment(for: game, session: session, engine: engine)
        activeGameInstallDir = prefix.gameInstallDir(appID: game.id)
            .map { prefix.steamInstallDir.appending(path: "steamapps/common/\($0)") }
        activeLaunchStartedAt = Date()
        activeSteamOutputOffset = GameLogFile.steamOutputSize()
        // Before the dispatch, so every line Steam writes in answer is read.
        let consoleLog = prefix.steamInstallDir.appending(path: "logs/console_log.txt")
        var consoleLogOffset = Self.fileSize(consoleLog)
        activeGameLogHandle = GameLogFile.beginSession(
            appID: game.id,
            gameName: game.name,
            executable: "steam.exe -applaunch \(game.id)",
            launchArgs: arguments,
            environment: engine.steamClientEnvironment(for: prefix)
        )
        do {
            try session.launchGameViaSteam(appID: game.id, arguments: arguments, engine: engine)
        } catch {
            closeActiveGameLog(reason: "Steam did not accept the launch", exitCode: nil)
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
            onLog: { [weak self] msg in self?.setLaunchActivity(msg) }
        )

        // Install state cannot change while a game runs; avoid a main-actor
        // filesystem scan of every library entry every five seconds.
        library?.setInstallStatePollingSuspended(true)
        defer { library?.setInstallStatePollingSuspended(false) }

        appendLog("Waiting for game to start")
        cloudSyncAnswer = nil
        cloudSyncRelaunch = nil
        var latestStep: String?
        var stepShownAt = ContinuousClock.now
        var openedAt: ContinuousClock.Instant?
        var pendingWait: (step: String, detail: String, since: ContinuousClock.Instant)?
        var eulaHandOff: [SteamEula]?
        var steamFailed = false
        var runningInstallScript = false
        // Steam-side failure/progress signal (fail-fast rule): if Steam
        // decided the app needs an update/validation instead of launching, the
        // ACF's StateFlags leaves "4". Report THAT instead of a mislabeled
        // "waiting for game to start" — Steam launches the game itself once
        // the validation completes (observed Jul 2 2026: validation of a
        // DepotDownloader install took ~80 s, then the game launched).
        var lastReportedValidating = false
        while gameProcess.monitorPhase == .startup {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
            // Steam's own launch steps, each line shown at least 1.2 s so a
            // burst stays readable (the latest wins when it is time).
            let appended = Self.readAppended(consoleLog, from: &consoleLogOffset)
            for event in Self.steamLaunchEvents(in: appended, appID: game.id) {
                switch event {
                case .waitingForPlayer(let step, let detail):
                    pendingWait = (step, detail, .now)
                case .answered, .task:
                    pendingWait = nil
                    if steamWaitingOnPlayer != nil { showSteamPrompt(nil) }
                }
                guard case .task(let task) = event else { continue }
                runningInstallScript = task == "RunningInstallScript"
                if let step = Self.launchStepText(for: task, gameName: game.name) { latestStep = step }
                if task == "CreatingProcess" { openedAt = .now }
                if task == "Failed" { steamFailed = true }
            }
            if steamFailed { break }
            // Steam answers some prompts itself within a second (no
            // interstitials to show); one still open is the player's to answer.
            if let pendingWait, steamWaitingOnPlayer == nil, ContinuousClock.now - pendingWait.since >= .seconds(1) {
                // The check before Steam started reads Steam's app cache,
                // which Steam writes only once it runs: after an engine update
                // reset Steam, there was none and Steam's own window asked
                // (meridian.log Oct 12 19:44:17 "no app info cache"; cache
                // written 19:45:24, ShowEula 19:45:26). By now it is there.
                if pendingWait.step == "ShowEula", let localConfigURL {
                    let eulas = await Task.detached(priority: .userInitiated) {
                        SteamEula.unaccepted(appID: appID, appInfo: appInfoURL, localConfig: localConfigURL, pending: pending)
                    }.value
                    if !eulas.isEmpty {
                        eulaHandOff = eulas
                        break
                    }
                }
                // Steam couldn't sync the game's cloud saves: Meridian asks
                // while Steam's dialog stays hidden. Try Again and Cancel quit
                // Steam (below); only Play Anyway needs Steam's own window.
                if pendingWait.step == "SynchronizingCloud", pendingWait.detail == "syncfailed",
                   cloudSyncAnswer != .decideInSteam {
                    if cloudSyncPrompt == nil, cloudSyncAnswer == nil {
                        log.info("[launchOnline] Steam couldn't sync \(game.name)'s cloud saves; asking in Meridian")
                        appendLog("Steam couldn't sync \(game.name)'s cloud saves")
                        cloudSyncPrompt = CloudSyncPrompt(game: game)
                    }
                    if cloudSyncAnswer != nil { break }
                } else {
                    showSteamPrompt(pendingWait.step)
                }
            }
            // Steam hasn't started the game while it waits on the player or
            // runs the game's install scripts (DirectX, Visual C++): hold the
            // startup timeout, and don't take the installers for the game.
            gameProcess.startupHeld = steamWaitingOnPlayer != nil || runningInstallScript || cloudSyncPrompt != nil
            // Some games sit a long while before their first window; past
            // "Almost there" the card says that's normal instead of going quiet.
            if let openedAt {
                let waited = ContinuousClock.now - openedAt
                if waited > .seconds(25) {
                    latestStep = "Some games take a minute to open"
                } else if waited > .seconds(5) {
                    latestStep = "Almost there"
                }
            }
            if let latestStep, latestStep != launchStep, ContinuousClock.now - stepShownAt >= .milliseconds(1200) {
                launchStep = latestStep
                stepShownAt = .now
            }
            if let acfState = prefix.gameDownloadProgress(appID: game.id) {
                let validating = acfState.stateFlags != "4"
                if validating != lastReportedValidating {
                    lastReportedValidating = validating
                    if validating {
                        setLaunchActivity("Steam is validating \(game.name) before launch…")
                        appendLog("Steam queued a validation/update for \(game.name) (StateFlags=\(acfState.stateFlags))")
                    }
                }
            }
        }

        launchStep = nil
        if steamWaitingOnPlayer != nil { showSteamPrompt(nil) }
        cloudSyncPrompt = nil

        if let answer = cloudSyncAnswer, answer != .decideInSteam {
            // Quitting Steam closes its "Unable to Sync" dialog. Try Again
            // launches again, which syncs again.
            log.info("[launchOnline] cloud sync failure answered in Meridian: \(answer == .tryAgain ? "try again" : "cancel")")
            gameProcess.cancelMonitoring()
            closeActiveGameLog(reason: "cloud sync failed, \(answer == .tryAgain ? "trying again" : "cancelled")", exitCode: nil)
            await session.shutdown(engine: engine)
            steamWindow?.resumeAfterGame(steamPID: 0)
            launchState = .idle
            currentActivity = nil
            let relaunch = answer == .tryAgain ? cloudSyncRelaunch : nil
            cloudSyncAnswer = nil
            cloudSyncRelaunch = nil
            relaunch?()
            return
        }

        if let eulas = eulaHandOff {
            // Ask in Meridian's sheet. Quitting Steam closes its own dialog
            // (and a Decline leaves nothing waiting); Accept starts Steam again
            // with the answer written, as when it is accepted before Steam runs.
            log.info("[launchOnline] Steam asked for \(eulas.map(\.id).joined(separator: ", ")); asking in Meridian")
            gameProcess.cancelMonitoring()
            closeActiveGameLog(reason: "license agreement asked in Meridian", exitCode: nil)
            await session.shutdown(engine: engine)
            steamWindow?.resumeAfterGame(steamPID: 0)
            eulaPrompt = EulaPrompt(game: game, eulas: eulas)
            launchState = .idle
            currentActivity = nil
            return
        }

        if steamFailed {
            // Steam gave up on the launch itself (a declined EULA, an
            // AppError): nothing will start, so say so now instead of
            // waiting out the startup timeout.
            gameProcess.cancelMonitoring()
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "Steam did not start the game", exitCode: nil)
            fail("Steam didn't start \(game.name). Please try again.")
            return
        }

        switch gameProcess.monitorPhase {
        case .running:
            AppSettings.shared.recordLaunch(appID: game.id)
            runningSince = Date()
            launchState = .running(appID: game.id)
            currentActivity = nil
            processesConfirmed = true
            appendLog("Game running (Online mode)")
        case .timedOut:
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "startup timeout (game process never appeared)", exitCode: nil)
            if lastReportedValidating {
                fail("Steam is still validating \(game.name). Wait a moment and press Play again. The download/validation continues in the background.")
            } else {
                fail("\(game.name) didn't start through Steam. Please try again.")
            }
            return
        case .exited, .idle, .failed:
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "game exited during startup", exitCode: nil)
            fail("\(game.name) didn't start through Steam. Please try again.")
            return
        case .startup:
            // Cancelled (Stop button / cancelLaunch). Teardown is owned by
            // stopGame/cancelLaunch; make sure the monitor is stopped and
            // suppression restored even if they raced us.
            gameProcess.cancelMonitoring()
            steamWindow?.resumeAfterGame(steamPID: 0)
            closeActiveGameLog(reason: "launch cancelled during startup", exitCode: nil)
            launchState = .idle
            currentActivity = nil
            return
        }

        while gameProcess.monitorPhase == .running {
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { break }
        }
        steamWindow?.resumeAfterGame(steamPID: 0)
        closeActiveGameLog(reason: "game exited", exitCode: nil)
        launchState = .idle
        currentActivity = nil
        runningSince = nil
        activeAppID = nil
        appendLog("Game exited")
    }

    // MARK: - Private: Steam's own update

    /// Steam is already applying this game's update (it auto-updates at
    /// sign-in: Far Far West, Oct 22 2026, 2.8 GB within a minute of Steam
    /// starting). Wait for it to commit rather than start a second download
    /// into the same folder. Returns once the game is current, Steam exits,
    /// or Steam stops downloading without finishing (its staging folder gone
    /// for 5 s); the caller then updates the game itself if it still needs it.
    private func waitForSteamUpdate(game: Game, session: SteamSession) async throws {
        launchState = .installing(appID: game.id)
        currentActivity = "Updating…"
        appendLog("Steam is already updating \(game.name); waiting for it to finish")
        log.info("[waitForSteamUpdate] appID=\(game.id) Steam is mid-update, waiting instead of a second download")
        var lastSeenDownloading = ContinuousClock.now
        while session.isReady, prefix.installState(appID: game.id) == .updateRequired {
            if prefix.isSteamDownloading(appID: game.id) {
                lastSeenDownloading = .now
            } else if ContinuousClock.now - lastSeenDownloading > .seconds(5) {
                break
            }
            try await Task.sleep(for: .seconds(1))
        }
        log.info("[waitForSteamUpdate] appID=\(game.id) done waiting, state=\(prefix.installState(appID: game.id))")
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

        // An update goes into the folder the game is already in.
        let installDirName = installIsUpdate ? (prefix.gameInstallDir(appID: game.id) ?? game.name) : game.name
        let installDir = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDirName)")

        let resuming = prefix.isGameInstalled(appID: game.id)
            || FileManager.default.fileExists(atPath: installDir.path(percentEncoded: false))
        launchState = .installing(appID: game.id)
        // Steps only: the numbers are `downloadProgressText`, so the line
        // that names the step doesn't change on every progress tick.
        currentActivity = installIsUpdate ? "Preparing update…"
            : resuming ? "Resuming download…" : "Preparing download…"
        let downloadingActivity = installIsUpdate ? "Updating…" : "Downloading…"
        downloadProgress = nil
        downloadBytesDone = 0
        downloadBytesTotal = 0
        downloadRateBps = 0
        appendLog("Starting \(installIsUpdate ? "update" : "install") for \(game.name)")

        // Rate smoothing across progress callbacks.
        var lastBytes: Int64 = 0
        var lastSampleAt = ContinuousClock.now

        let result = try await DepotDownloaderInstall.run(
            binary: binary,
            appID: game.id,
            installDir: installDir,
            username: account,
            refreshToken: token,
            onPhase: { [weak self] phase, _ in
                guard let self else { return }
                switch phase {
                case "connecting": self.currentActivity = "Connecting to Steam…"
                case "loggedon":   self.currentActivity = "Starting download…"
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

                if self.currentActivity != downloadingActivity {
                    self.currentActivity = downloadingActivity
                }
            }
        )

        // DepotDownloader writes no ACF — write a StateFlags=4 manifest so the
        // launch path, uninstall, and installed-state checks all read the game
        // as installed. buildid + InstalledDepots come from the fork's `done`
        // event so Steam's own library scan (Online mode) agrees the install
        // is CURRENT — without them Steam flips the ACF to update-pending and
        // `-applaunch` queues a validation instead of launching (Bug B,
        // HANDOFF-2026-07-02-v4).
        //
        // SizeOnDisk = sum of the own-app depots' full manifest sizes (matches
        // what Steam itself records; shared depots are excluded there too).
        // Falls back to the raw downloaded byte count on older fork binaries.
        let ownedSize = result.depots
            .filter { $0.sharedApp == nil }
            .reduce(Int64(0)) { $0 + $1.size }
        try prefix.writeInstalledAppManifest(
            appID: game.id,
            name: game.name,
            installDir: installDirName,
            steamID64: steamID,
            sizeOnDisk: ownedSize > 0 ? ownedSize : result.bytesDownloaded,
            buildID: result.buildID,
            depots: result.depots
        )
        activeSession?.manifestRewritten(appID: game.id)

        downloadProgress = 1.0
        downloadRateBps = 0
        currentActivity = installIsUpdate ? "Updated" : "Installed"
        appendLog("\(game.name) \(installIsUpdate ? "update" : "install") complete (\(result.bytesDownloaded / (1024 * 1024)) MB)")
        log.info("[installHeadless] ✓ appID=\(game.id) bytes=\(result.bytesDownloaded) buildid=\(result.buildID)")
    }

    // MARK: - Private: launch arguments

    /// The game's compat-profile arguments plus, on its first launch, a
    /// default resolution. Steam forwards them to the game:
    /// `-applaunch <id> <args>` passed `-force-d3d11` with no prompt
    /// (CLI-verified Oct 8 2026).
    private func launchArguments(for game: Game, engine: WineEngine) async -> [String] {
        let profile = GameCompatibilityDB.shared.profile(for: game.id)
        let profileArgs = profile?.launchArgs ?? []
        guard AppSettings.shared.lastLaunchDate(appID: game.id) == nil,
              let installDir = prefix.gameInstallDir(appID: game.id) else { return profileArgs }
        let gamePath = prefix.steamInstallDir.appending(path: "steamapps/common/\(installDir)")
        let gameEngine: GameEngine
        if let profile {
            gameEngine = profile.gameEngine
        } else {
            gameEngine = await GameStackResolver.shared.resolve(appID: game.id, name: game.name, installDir: gamePath).engine
        }
        return profileArgs + (await seedDefaultResolution(
            game: game, engine: engine, gameEngine: gameEngine, profileArgs: profileArgs
        ))
    }

    // MARK: - Private: per-game environment

    /// Stores the variables the game's profile sets under the executable
    /// Steam starts (the install root's main exe); a launcher or bootstrap
    /// passes them on to the game it starts. No profile variables and nothing
    /// written before: no Wine process at all.
    private func applyGameEnvironment(for game: Game, session: SteamSession, engine: WineEngine) async {
        guard let installDir = prefix.gameInstallDir(appID: game.id) else { return }
        let gamePath = prefix.steamInstallDir.appending(path: "steamapps/common/\(installDir)")
        let top = (try? FileManager.default.contentsOfDirectory(atPath: gamePath.path(percentEncoded: false))) ?? []
        guard let executable = GameStackDetector.mainExecutable(in: top) else { return }
        let variables = session.gameEnvironmentOverrides(for: game.id, engine: engine)
        if !variables.isEmpty {
            log.info("[launch] \(executable) environment: \(variables.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " "))")
        }
        await prefix.writeAppEnvironment(executable: executable, variables: variables, engine: engine)
    }

    // MARK: - Private: first-launch resolution

    /// The display's scaled ("Default for display") resolution in points, e.g.
    /// 2560×1440 on a 5K Studio Display. With winemac `RetinaMode=y` games see
    /// the native pixel desktop and default to it; native 5K is fill-bound on
    /// the GL path (user-verified: equally choppy mouse AND video) while the
    /// scaled resolution is smooth. Uses the screen the Meridian window is on.
    static func defaultGameResolution() -> (width: Int, height: Int)? {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main else { return nil }
        let size = screen.frame.size
        return (Int(size.width.rounded()), Int(size.height.rounded()))
    }

    /// On a game's FIRST launch (no `AppSettings.launchTimestamps` entry) point
    /// its fullscreen resolution at `defaultGameResolution()`. Never touches a
    /// game that has already been launched — the user's own choice wins after
    /// that. Returns extra launch args for engines configured that way; Source
    /// is seeded through its registry settings key instead.
    private func seedDefaultResolution(
        game: Game,
        engine: WineEngine,
        gameEngine: GameEngine,
        profileArgs: [String]
    ) async -> [String] {
        guard AppSettings.shared.lastLaunchDate(appID: game.id) == nil,
              let res = Self.defaultGameResolution() else { return [] }
        let w = String(res.width), h = String(res.height)

        switch gameEngine {
        case .source:
            // Source persists video settings under HKCU\Software\Valve\Source\<mod>\Settings.
            // The mod folder is the `-game` argument; without one we cannot name the key.
            guard let i = profileArgs.firstIndex(of: "-game"), i + 1 < profileArgs.count else { return [] }
            let key = "HKCU\\Software\\Valve\\Source\\\(profileArgs[i + 1])\\Settings"
            for (name, value) in [("ScreenWidth", w), ("ScreenHeight", h), ("ScreenWindowed", "0")] {
                _ = try? await engine.run(
                    args: ["reg", "add", key, "/v", name, "/t", "REG_DWORD", "/d", value, "/f"],
                    prefix: prefix
                )
            }
            log.info("[launch] first launch appID=\(game.id): seeded Source video settings \(w)x\(h) fullscreen")
            return []
        case .unity:
            log.info("[launch] first launch appID=\(game.id): Unity \(w)x\(h) fullscreen")
            return ["-screen-width", w, "-screen-height", h, "-screen-fullscreen", "1"]
        case .unreal:
            log.info("[launch] first launch appID=\(game.id): Unreal \(w)x\(h) fullscreen")
            return ["-ResX=\(w)", "-ResY=\(h)", "-fullscreen"]
        case .godot:
            log.info("[launch] first launch appID=\(game.id): Godot \(w)x\(h) fullscreen")
            return ["--resolution", "\(w)x\(h)", "--fullscreen"]
        case .gamebryo, .custom, .unknown:
            return []
        }
    }

    /// Append a `Reason:` trailer to the active per-game log and release
    /// the file handle. Called from every exit path of `executePipeline`.
    /// Safe to call when no log is active.
    private func closeActiveGameLog(reason: String, exitCode: Int32?) {
        guard let handle = activeGameLogHandle else { return }
        let appID = activeAppID ?? 0
        let lowLevelDir = prefix.userProfileDir.appending(path: "AppData/LocalLow")
        let installDir = activeGameInstallDir
        let startedAt = activeLaunchStartedAt
        let steamOutputOffset = activeSteamOutputOffset
        activeGameLogHandle = nil
        activeGameInstallDir = nil
        activeLaunchStartedAt = nil
        activeSteamOutputOffset = nil

        // File work (the Wine output slice can be tens of MB) stays off the
        // main actor.
        Task.detached(priority: .utility) {
            // Collect the game's own engine log (Unity Player.log / Unreal
            // Saved/Logs) for this session into <appID>-engine.log BEFORE
            // writing the trailer, so the diagnostic artifact is captured even
            // on the crash / timeout / fast-exit paths.
            GameLogFile.collectEngineLogs(
                appID: appID,
                lowLevelDir: lowLevelDir,
                installDir: installDir,
                launchStartedAt: startedAt
            )
            if let steamOutputOffset {
                GameLogFile.appendSteamOutput(since: steamOutputOffset, to: handle)
            }
            GameLogFile.endSession(handle: handle, appID: appID, reason: reason, exitCode: exitCode)
        }
    }

    // MARK: - Private: uninstall

    private nonisolated static func uninstallGame(game: Game, prefix: WinePrefix) throws {
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

    // MARK: - Private: Steam's sign-in inside a launch

    /// Steam's own sign-in, then Steam started silently again for the game
    /// (signing in closes Steam). `steamSignIn` is set only while the player
    /// is needed, so the card shows "Sign in to Steam" and then carries on
    /// from where the bar stood.
    private func signInToSteam(_ reason: SteamSignIn, appID: Int, session: SteamSession, engine: WineEngine) async throws {
        steamSignIn = reason
        do {
            try await session.signInInteractively(engine: engine) { [weak self] status in
                self?.setLaunchActivity(status)
            }
        } catch {
            steamSignIn = nil
            throw error
        }
        steamSignIn = nil
        try await session.ensureReadyForDRM(engine: engine, appID: appID) { [weak self] status in
            self?.setLaunchActivity(status)
        }
    }

    // MARK: - Private: launch-stage mapping (Steam-boot overlay)

    /// Ordered marker table mapping launch status strings → (phase, fraction).
    /// FIRST match wins, so more specific markers must precede their
    /// substrings (e.g. "Connecting to Steam servers" before "Connecting to
    /// Steam"). Statuses come from three sources (the pipeline itself,
    /// `SteamSession`'s `onStatus` callbacks, and `GameProcess.onLog`), all
    /// funneled through `setLaunchActivity`. Unrecognized statuses update
    /// only `currentActivity` (the launch log). Steam's sign-in is not a
    /// marker: the card follows `steamSignIn` instead.
    ///
    /// MIRROR CONTRACT: mirrored in LaunchStageTests.launchStages.
    static let launchStages: [(marker: String, phase: LaunchPhase, fraction: Double)] = [
        ("Connecting to Steam servers",      .gettingReady,   0.54),
        ("Connected to Steam servers",       .gettingReady,   0.58),
        ("Signing in to your Steam account", .gettingReady,   0.62),
        ("Finishing sign-in",                .gettingReady,   0.66),
        ("Steam is ready",                   .gettingReady,   0.70),
        ("Steam is updating itself",         .updatingSteam,  0.50),
        ("Updating Steam",                   .updatingSteam,  0.50),
        ("Starting Steam client",            .gettingReady,   0.46),
        ("Connecting to Steam",              .gettingReady,   0.08),
        ("Downloading Steam",                .settingUpSteam, 0.28),
        ("Installing Steam",                 .settingUpSteam, 0.18),
        ("Signed in",                        .gettingReady,   0.44),
        ("Starting Steam",                   .gettingReady,   0.42),
        ("through Steam",                    .startingGame,   0.76),
        ("validating",                       .checkingFiles,  0.82),
        ("Waiting for Steam to start",       .startingGame,   0.88),
        ("Waiting for game to start",        .startingGame,   0.92),
        ("Game is running",                  .startingGame,   1.00),
    ]

    /// Sets `currentActivity` and, when the status matches a known marker,
    /// advances the staged phase + fraction for the launch card.
    private func setLaunchActivity(_ status: String) {
        currentActivity = status
        if let stage = Self.launchStages.first(where: { status.localizedCaseInsensitiveContains($0.marker) }) {
            launchPhase = stage.phase
            launchStageFraction = max(launchStageFraction, stage.fraction)
        }
        if launchPhase == .gettingReady, let step = Self.gettingReadyStepText(for: status) {
            launchStep = step
        }
    }

    /// The line under "Getting ready…" while Steam starts and signs in, which
    /// can take 20 s from cold (user, Oct 12 2026: "it doesn't give much
    /// feedback"). Three beats in plain words, not Steam's every status
    /// (Oct 11: the card names beats, it doesn't narrate). nil keeps the
    /// current line.
    nonisolated static func gettingReadyStepText(for status: String) -> String? {
        if status.localizedCaseInsensitiveContains("Steam is ready") { return "Steam is ready" }
        if status.localizedCaseInsensitiveContains("Signing in")
            || status.localizedCaseInsensitiveContains("sign-in")
            || status.localizedCaseInsensitiveContains("Signed in") { return "Signing in to your account" }
        if status.localizedCaseInsensitiveContains("Steam servers") { return "Connecting to Steam" }
        if status.localizedCaseInsensitiveContains("Starting Steam") { return "Starting Steam in the background" }
        return nil
    }

    /// Resets the staged progress at the start of a launch attempt (and on
    /// cancel/stop) so the next run's bar starts empty.
    private func resetLaunchStage() {
        launchStep = nil
        steamWaitingOnPlayer = nil
        launchPhase = .gettingReady
        launchStageFraction = 0
    }

    // MARK: - Steam's launch steps

    /// One of Steam's launch events in console_log.txt (CLI-verified Oct 12
    /// 2026, the cabin game and Super Battle Golf).
    enum SteamLaunchEvent: Equatable {
        /// `LaunchApp changed task to SynchronizingCloud with ""`
        case task(String)
        /// `LaunchApp waiting for user response to ShowEula ""`: Steam shows
        /// a dialog and waits (it answers `ShowInterstitials` itself when
        /// there are none). `detail` is the quoted reason, as in
        /// `SynchronizingCloud "syncfailed"`; empty for most steps.
        case waitingForPlayer(String, detail: String = "")
        /// `LaunchApp continues with user response "ShowEula"`
        case answered
    }

    /// Steam's launch events for `appID`, oldest first, from lines like
    /// `GameAction [AppID 4069520, ActionID 1] : LaunchApp …`. Steam writes
    /// CRLF, and "\r\n" is one Character, so splitting on "\n" saw a whole
    /// poll as one line and only its first event (the EULA wait was missed).
    nonisolated static func steamLaunchEvents(in text: String, appID: Int) -> [SteamLaunchEvent] {
        let marker = "GameAction [AppID \(appID),"
        func word(after prefix: String, in line: Substring) -> String? {
            guard let range = line.range(of: prefix) else { return nil }
            return String(line[range.upperBound...].prefix { $0 != " " })
        }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains(marker) else { return nil }
            if let task = word(after: "LaunchApp changed task to ", in: line) { return .task(task) }
            if let step = word(after: "LaunchApp waiting for user response to ", in: line) {
                let detail = line.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first ?? ""
                return .waitingForPlayer(step, detail: String(detail))
            }
            if line.contains("LaunchApp continues with user response") { return .answered }
            return nil
        }
    }

    /// Shows (or, with nil, hides) Steam's window while it waits on the
    /// player, and holds the card meanwhile (the launch loop holds the
    /// startup timeout from `steamWaitingOnPlayer`).
    private func showSteamPrompt(_ step: String?) {
        steamWaitingOnPlayer = step
        if let step {
            appendLog("Steam is waiting for your answer (\(step)); showing its window")
            steamWindow?.presentSteamPrompt()
        } else {
            steamWindow?.endSteamPrompt()
        }
    }

    /// The happy-path line for one of Steam's launch steps, or nil to keep the
    /// current line (the steps that don't mean anything to a player).
    nonisolated static func launchStepText(for task: String, gameName: String) -> String? {
        switch task {
        case "UpdatingAppTicket", "SiteLicenseSeatCheckout": return "Checking with Steam"
        // Steam's install scripts: the game's Visual C++ and DirectX
        // redistributables (`_CommonRedist`, `Redists` in older games), again
        // after an engine update resets the Windows folder they install into.
        case "RunningInstallScript": return "Installing Windows components"
        case "SynchronizingCloud": return "Syncing your saves"
        case "SynchronizingStats": return "Loading your achievements"
        case "CreatingProcess": return "Opening \(gameName)"
        default: return nil
        }
    }

    private nonisolated static func fileSize(_ url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Whole lines appended to `url` since `offset`, which moves past them; a
    /// line Steam is still writing waits for the next poll. A few hundred
    /// bytes per poll while a game starts.
    private nonisolated static func readAppended(_ url: URL, from offset: inout UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { offset = size; return "" }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return "" }
        let complete = data[data.startIndex...lastNewline]
        offset += UInt64(complete.count)
        return String(decoding: complete, as: UTF8.self)
    }

    // MARK: - Private: helpers

    private func fail(_ message: String, error: Error? = nil) {
        log.error("[pipeline] failed: \(message)")
        launchState = .failed(message)
        currentActivity = nil
        launchStep = nil
        steamWaitingOnPlayer = nil
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

