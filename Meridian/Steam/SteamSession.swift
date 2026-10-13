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
        /// Steam has no usable sign-in: Valve rejected the saved one, or
        /// none was saved. Only Steam's own sign-in fixes this, and the
        /// player is asked before it opens.
        case signedOut
    }

    /// How a wait for `[Logged On,` ended.
    enum LogonResult: Equatable { case loggedOn, signedOut, failed }

    private(set) var state: State = .idle

    /// `WINEDEBUG` the running steam.exe (and so every game it launches)
    /// was started with. Changing the trace channels in Settings restarts
    /// Steam before the next launch (`ensureReadyForDRM`).
    private var runningWineDebug: String?

    /// Apps with an appmanifest when the running steam.exe started. Steam
    /// reads `appmanifest_*.acf` once per start, so a game Meridian installs
    /// after that (DepotDownloader) is unknown to it until it restarts.
    private var appsSteamLoaded: Set<Int> = []

    /// License agreements the player accepted in Meridian, written into
    /// Steam's localconfig.vdf the next time steam.exe starts: Steam reads
    /// that file only when it starts (Pattern 47).
    private(set) var pendingEulaAcceptances: [SteamEula] = []

    func recordEulaAcceptances(_ eulas: [SteamEula]) {
        pendingEulaAcceptances += eulas.filter { !pendingEulaAcceptances.contains($0) }
    }

    /// Steam client download progress while `bootstrapSteamClientIfNeeded`
    /// downloads; nil otherwise (including while it installs). Drives the
    /// onboarding progress ring.
    struct DownloadProgress: Equatable {
        let received: Int64
        let total: Int64
        var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    }
    private(set) var clientDownload: DownloadProgress?

    /// What a running one-time Steam sign-in is doing (onboarding shows it as
    /// a checklist); nil when no sign-in is running. "Waiting for the user" is
    /// `SteamWindow.isSignInWindowShown`.
    enum SignInPhase: Equatable { case downloading, installing, starting, updating, finishing }
    private(set) var signInPhase: SignInPhase?

    var isReady: Bool {
        if case .running = state { return true }
        return false
    }

    // MARK: - Private state

    private var persistentProcess: Process?
    private var connectionLogOffset: Int = 0
    /// Session-start offset into webhelper_js.txt, captured alongside
    /// `connectionLogOffset`. The webhelper fast-fail heuristic must only
    /// count THIS session's "connect attempt failed" lines — reading from
    /// offset 0 counted stale failures from previous Steam runs (Bug E,
    /// HANDOFF-2026-07-02-v4).
    private var webhelperLogOffset: Int = 0
    private let prefix = WinePrefix.defaultPrefix

    /// Background task that watches `persistentProcess` after it has reached
    /// `[Logged On,` and relaunches it if Steam exits code=42 (self-update
    /// restart). Without this, Steam's normal mid-session client-update flow
    /// terminates wineserver, which kills any running game with it. Set on
    /// the same actor as `state`; only one is alive at a time.
    private var healthMonitorTask: Task<Void, Never>?

    /// Sentinel — incremented by `shutdown` so an in-flight health monitor
    /// task can detect that it has been superseded and exit cleanly without
    /// fighting the user's explicit shutdown.
    private var healthGeneration: Int = 0

    /// A background bring-up started by `warmUp` (nil otherwise). Play joins
    /// it rather than racing it: `start()` skips while `.startingSilent`, so a
    /// second caller would otherwise see "not ready" mid-boot.
    private var warmUpTask: Task<Void, Never>?

    // MARK: - Dependency injection (set by MeridianApp)

    var steamWindow: SteamWindow?

    // MARK: - Public API: lifecycle

    /// Start steam.exe -silent. Never sends -login. Never throws.
    ///
    /// Called from BootstrapManager step 7 when a session exists on disk
    /// (ssfn token or loginusers.vdf). If Steam can auth silently from its
    /// own on-disk state (ssfn, local.vdf) it succeeds in ~5-10 s.
    /// If not, fails after 12 s → state = .failed → sign-in sheet recovers.
    func start(engine: WineEngine, onStatus: (@MainActor (String) -> Void)? = nil) async {
        switch state {
        case .running:
            log.info("[start] already running — skip")
            return
        case .startingSilent:
            log.info("[start] already starting — skip")
            return
        case .idle, .failed, .signedOut:
            // `.failed` is retryable — a prior silent-auth failure (e.g. a
            // lazy DRM warm that didn't reach [Logged On,) must be able to
            // re-attempt cleanly. launchSteamProcess no-ops if a live process
            // already exists, so this is safe.
            break
        }

        state = .startingSilent
        steamWindow?.startSuppressing()

        do {
            try await launchSteamProcess(engine: engine)
            let pid = persistentProcess.flatMap { $0.isRunning ? $0.processIdentifier : nil } ?? 0
            let result = await waitForLoggedOn(
                engine: engine,
                timeout: .seconds(60),
                authTimeout: .seconds(12),
                onStatus: onStatus
            )
            switch result {
            case .loggedOn:
                onStatus?("Steam is ready")
                state = .running(pid: pid_t(pid))
                log.info("[start] silent auth succeeded ✓ pid=\(pid)")
                // Begin watching the long-running steam.exe so we can transparently
                // relaunch it when Steam decides to self-update (exit code=42).
                // Without this, the user's running game dies the next time Valve
                // pushes a client update mid-session — CLI-confirmed May 20 2026.
                startHealthMonitor(engine: engine)
            case .signedOut:
                logSteamFailureDiagnostics(reason: "Steam has no usable sign-in")
                markSignedOut()
            case .failed:
                log.warning("[start] silent auth timed out — sign-in sheet will handle re-auth")
                logSteamFailureDiagnostics(reason: "silent auth did not reach [Logged On,")
                state = .failed("Steam could not authenticate silently. Please sign in.")
            }
        } catch {
            log.warning("[start] steam.exe start failed: \(error.localizedDescription)")
            logSteamFailureDiagnostics(reason: "launchSteamProcess threw: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Lazy DRM-only Steam runtime

    /// Brings the full Steam runtime online for a DRM game launch — and ONLY
    /// for that.
    ///
    /// As of Phase 3 (HANDOFF-2026-06-19) Steam is lazy and DRM-only: the
    /// bootstrap pipeline no longer installs the Steam client or starts
    /// steam.exe. The first time a DRM game (`steam_api64.dll`) is launched,
    /// `Launcher` calls this. It performs the deferred Steam bring-up:
    ///
    ///   1. install the Steam stub (`SteamSetup.exe /S`) if absent — silent, small
    ///   2. download the full client (steamui.dll, ~336 MB) NATIVELY if absent
    ///   3. inject `local.vdf` from the persisted OAuth refresh_token so
    ///      `steam.exe -silent` can auto-login
    ///   4. start `steam.exe -silent` and wait for `[Logged On,`
    ///
    /// Idempotent: returns immediately when already `.running`. Recoverable:
    /// `start()` accepts a prior `.failed` state so a second DRM launch can
    /// re-attempt. Throws `SessionError.steamNotReady` when Steam cannot reach
    /// `[Logged On,` so the caller surfaces an actionable error.
    ///
    /// DRM-free games and installs never call this — they use the persisted
    /// refresh_token via DepotDownloader / direct wine64 exec, so a DRM-free-only
    /// user never downloads the Steam client nor runs steam.exe.
    func ensureReadyForDRM(
        engine: WineEngine,
        appID: Int? = nil,
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        if let warmUpTask {
            onStatus?("Starting Steam…")
            // Stop during the wait stops the warm-up too.
            await withTaskCancellationHandler {
                await warmUpTask.value
            } onCancel: {
                warmUpTask.cancel()
            }
        }
        try await bringUpForDRM(engine: engine, appID: appID, onStatus: onStatus)
    }

    /// Starts Steam silently in the background so Play doesn't wait ~10-15 s
    /// for it (user, Oct 11 2026: "why does it have to wait till we want to
    /// play a game"). Every game launches through Steam now, so Steam is
    /// needed for any Play. Only once Steam's own sign-in has succeeded on
    /// this Mac (no sign-in window can appear from here), and a sign-out
    /// Valve has made is found here rather than mid-launch (`state ==
    /// .signedOut`, which `Launcher` checks before it starts).
    ///
    /// With `appID` (a game that just finished installing) a running Steam
    /// that started before the install is restarted now, in the background,
    /// instead of when the player presses Play: Steam reads install
    /// manifests only when it starts (Pattern 43).
    func warmUp(engine: WineEngine, appID: Int? = nil) {
        guard warmUpTask == nil, AppSettings.shared.steamClientSignedIn else { return }
        let missingGame = isReady && appID.map { !appsSteamLoaded.contains($0) } == true
        guard state == .idle || missingGame else { return }
        log.info(missingGame
                 ? "[warmUp] restarting Steam in the background so it loads appID=\(appID ?? 0)"
                 : "[warmUp] starting Steam in the background")
        warmUpTask = Task {
            do {
                try await bringUpForDRM(engine: engine, appID: appID, onStatus: nil)
            } catch {
                log.info("[warmUp] Steam isn't ready (\(error.localizedDescription)); Play will handle it")
            }
            warmUpTask = nil
        }
    }

    private func bringUpForDRM(
        engine: WineEngine,
        appID: Int?,
        onStatus: (@MainActor (String) -> Void)?
    ) async throws {
        if isReady {
            let wanted = engine.steamClientEnvironment(for: prefix)["WINEDEBUG"]
            if wanted != runningWineDebug {
                log.info("[ensureReadyForDRM] Wine trace channels changed (\(runningWineDebug ?? "none") → \(wanted ?? "none")) — restarting Steam")
            } else if let appID, !appsSteamLoaded.contains(appID) {
                // Otherwise -applaunch fails at once with AppError_18 and no
                // game ever starts (Endacopia, The Baby in Yellow, Oct 12 2026).
                log.info("[ensureReadyForDRM] appID=\(appID) was installed after Steam started — restarting Steam so it loads the game")
            } else if !pendingEulaAcceptances.isEmpty {
                log.info("[ensureReadyForDRM] license agreement accepted in Meridian — restarting Steam so it reads the answer")
            } else {
                return
            }
            await shutdown(engine: engine)
        }
        log.info("[ensureReadyForDRM] bringing Steam runtime online for DRM launch (state=\(String(describing: state)))")

        // 1. Steam stub — silent install, only if absent.
        if !prefix.isSteamInstalled {
            onStatus?("Installing Steam…")
            log.info("[ensureReadyForDRM] installing Steam stub (SteamSetup.exe /S)")
            try await prefix.installSteam(engine: engine)
        }
        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()

        try Task.checkCancellation()

        // 2. Full Steam client (steamui.dll, ~336 MB) — only needed for DRM.
        try await bootstrapSteamClientIfNeeded(engine: engine, onStatus: onStatus)
        if prefix.refreshSteamStubFromEngineIfStale() {
            log.info("[ensureReadyForDRM] steam.exe stub refreshed from engine bundle ✓")
        }

        try Task.checkCancellation()

        // 3. Restore Steam's OWN previously-written session (snapshot taken
        //    after a successful login) so `-silent` can auto-login.
        //
        //    NOTE: we deliberately do NOT inject the Meridian OAuth token via
        //    `writeSteamSessionLocalVdf` here. Valve's CM rejects injected
        //    tokens at logon (device-binding wall, Pattern 6 — reconfirmed
        //    Jul 2 2026), and repeated rejected logons feed the anti-abuse
        //    lockout (Pattern 23). Only a session Steam wrote itself (via the
        //    one-time interactive sign-in, `signInInteractively`) is accepted
        //    for silent auto-login.
        SteamSessionBackup.restoreIfNeeded(prefix: prefix)
        let settings = AppSettings.shared
        if settings.hasSteamCredentials {
            // Pre-write the per-user webhelper notification toggles BEFORE Steam
            // starts so the post-login toast burst is silenced before the first
            // toast can render. Best-effort — the userdata dir may not exist
            // until Steam's first -silent launch creates it.
            try? prefix.writeUserNotificationPreferences(steamID64: settings.steamCredentialSteamID)
        }

        // 4. Start steam.exe -silent + wait for [Logged On,].
        onStatus?("Starting Steam…")
        await start(engine: engine, onStatus: onStatus)
        guard isReady else {
            // start() already logged steam.exe diagnostics on the failure path.
            throw state == .signedOut ? SessionError.signedOut : SessionError.steamNotReady
        }
        log.info("[ensureReadyForDRM] Steam ready for DRM ✓")
    }

    // MARK: - Interactive one-time Steam sign-in (Online mode)

    /// Brings up Steam's OWN sign-in window (`steam.exe` WITHOUT `-silent`)
    /// and waits for the user to complete login. One-time per prefix: after a
    /// successful interactive login Steam persists its own session
    /// (`loginusers.vdf` with `RememberPassword=1` + `local.vdf`), so every
    /// subsequent Online launch auto-authenticates via the silent path.
    ///
    /// Why interactive: token injection into the bottle is rejected by Valve's
    /// CM at logon (device-binding wall, Pattern 6), and repeated rejected
    /// logons feed the anti-abuse lockout (Pattern 23). A session established
    /// through Steam's own login UI is device-consistent and accepted —
    /// user-verified Jul 2 2026 on our engine once the prefix had the complete
    /// wine.inf registration (Pattern 24 / v3.1.0-engine).
    ///
    /// Window policy: `SteamWindow.beginSignIn()` shows only Steam's sign-in
    /// window (centred over Meridian; everything else stays hidden).
    /// Suppression re-engages at `[Logged On,`, and once Steam has saved its
    /// session it is shut down, so its post-login library window never stays
    /// up. Callers that need Steam running start it silently afterwards.
    func signInInteractively(
        engine: WineEngine,
        timeout: Duration = .seconds(300),
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        if isReady { return }
        defer { signInPhase = nil }
        log.info("[signInInteractively] starting interactive Steam sign-in (state=\(String(describing: state)))")

        // Same deferred bring-up as ensureReadyForDRM steps 1-2.
        if !prefix.isSteamInstalled {
            onStatus?("Installing Steam…")
            try await prefix.installSteam(engine: engine)
        }
        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()
        try Task.checkCancellation()
        try await bootstrapSteamClientIfNeeded(engine: engine, onStatus: onStatus)
        _ = prefix.refreshSteamStubFromEngineIfStale()
        try Task.checkCancellation()

        // Own a clean process tree — a half-started silent attempt would race
        // the interactive instance on the same prefix.
        await shutdown(engine: engine)

        state = .startingSilent
        // Show Steam's sign-in window — centred over Meridian, everything else
        // Steam opens stays hidden.
        steamWindow?.beginSignIn()

        signInPhase = .starting
        onStatus?("Starting Steam…")
        do {
            try await launchSteamProcess(engine: engine, interactive: true)
        } catch {
            steamWindow?.startSuppressing()
            state = .failed(error.localizedDescription)
            throw error
        }

        let loggedOn = await waitForInteractiveLogon(timeout: timeout, onStatus: onStatus)

        // Re-engage suppression FIRST so Steam's post-login main window is
        // hidden before it paints.
        steamWindow?.startSuppressing()
        if let p = persistentProcess, p.isRunning {
            steamWindow?.registerPID(pid_t(p.processIdentifier))
        }

        guard loggedOn else {
            if Task.isCancelled {
                // Stop button during the sign-in wait — this is a cancel, not
                // an auth failure. The caller's cancellation path tears the
                // sign-in window down; don't overwrite state with .failed.
                state = .idle
                throw CancellationError()
            }
            logSteamFailureDiagnostics(reason: "interactive sign-in did not reach [Logged On,")
            state = .failed("Steam sign-in was not completed.")
            await shutdown(engine: engine)
            throw SessionError.steamNotReady
        }

        AppSettings.shared.steamClientSignedIn = true
        signInPhase = .finishing
        onStatus?("Signed in. Finishing up…")

        // Steam opens its full library window right after signing in, and
        // nothing needs it. Quit Steam, but only after it has saved its
        // session: closing it 5 s after logon lost the session (meridian.log
        // Oct 7 21:19:08 → silent start 21:20:49 "no session on disk").
        // Only the file's modification time is checked, never its contents.
        // A few seconds of slack: Steam can save just before the log poll
        // notices the logon.
        if await waitForSavedSession(since: Date().addingTimeInterval(-5), timeout: .seconds(45)) {
            SteamSessionBackup.snapshot(prefix: prefix)
            await shutdown(engine: engine)
        } else {
            log.warning("[signInInteractively] Steam hasn't saved its session yet — leaving it running hidden")
            state = .running(pid: persistentProcess.map { pid_t($0.processIdentifier) } ?? 0)
        }
        log.info("[signInInteractively] ✓ signed in; Steam saved its session and was closed")
    }

    /// Interactive variant of `waitForLoggedOn`: the user is typing
    /// credentials / scanning a QR, so there is no post-Connected auth
    /// deadline and the login page's webhelper polling is expected traffic.
    /// Fails fast only when steam.exe itself exits (user closed the window,
    /// or a crash) — the timeout is a last-resort safety net for an abandoned
    /// sign-in window.
    /// Waits until Steam has saved its sign-in after `since`: both
    /// `local.vdf` and `config/loginusers.vdf` (the account list auto-login
    /// starts from) modified. Polls modification dates only.
    ///
    /// `local.vdf` alone is not enough: on Oct 7 21:19 Steam wrote it within
    /// 5 s of logon but had not written loginusers.vdf yet, and the next
    /// silent start found no session (21:20:49, 21:34:41 "no session on disk").
    private func waitForSavedSession(since: Date, timeout: Duration) async -> Bool {
        let files = [prefix.localAppDataSteamDir.appending(path: "local.vdf"),
                     prefix.steamConfigDir.appending(path: "loginusers.vdf")]
        func modified(_ url: URL) -> Bool {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
            return (attributes?[.modificationDate] as? Date).map { $0 > since } ?? false
        }
        let started = ContinuousClock.now
        while ContinuousClock.now - started < timeout {
            if files.allSatisfy(modified) {
                log.info("[savedSession] Steam saved its sign-in")
                try? await Task.sleep(for: .seconds(2))  // let Steam finish its other config writes
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        log.warning("[savedSession] no save within \(timeout) (local.vdf=\(modified(files[0])) loginusers.vdf=\(modified(files[1])))")
        return false
    }

    private func waitForInteractiveLogon(
        timeout: Duration,
        onStatus: (@MainActor (String) -> Void)?
    ) async -> Bool {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)
        let started = ContinuousClock.now

        while ContinuousClock.now - started < timeout {
            if Task.isCancelled { return false }

            if let p = persistentProcess, !p.isRunning {
                let code = p.terminationStatus
                if code == 42 {
                    log.info("[interactiveLogon] code=42 self-update restart, continuing…")
                    signInPhase = .updating
                    onStatus?("Updating Steam…")
                    persistentProcess = nil
                } else {
                    log.error("[interactiveLogon] steam.exe exited code=\(code) — window closed or crashed before sign-in")
                    return false
                }
            }

            let content = readLogTail(path: connLogPath, from: connectionLogOffset)
            if content.contains("[Logged On, ") {
                log.info("[interactiveLogon] ✓ Logged On")
                return true
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        log.warning("[interactiveLogon] timeout after \(timeout) — sign-in window abandoned")
        return false
    }

    /// Downloads the full Steam client (steamui.dll) NATIVELY via URLSession.
    ///
    /// Moved here from BootstrapManager as part of making Steam DRM-only
    /// (Phase 3). We do NOT run `steam.exe -silent` to bootstrap: its
    /// statically-linked 32-bit OpenSSL cannot complete TLS handshakes under
    /// WoW64 on macOS 26, producing `http error 0` so steamui.dll never
    /// appears (CLI-reproduced). `SteamClientBootstrap` fetches Valve's CDN
    /// manifest + packages over native macOS TLS instead.
    ///
    /// Re-bootstraps when the client is absent OR the installed `steam.exe` is
    /// the broken 32-bit build (older prefixes fetched the `steam_client_win32`
    /// packages whose 32-bit steam.exe reports Windows 8 and fails every
    /// in-Wine update fetch). FAIL-FAST (fail-fast.mdc): exactly ONE clean
    /// retry (discard partial cache), then surface the error.
    private func bootstrapSteamClientIfNeeded(
        engine: WineEngine,
        onStatus: (@MainActor (String) -> Void)?
    ) async throws {
        let needsClientBootstrap = !prefix.isSteamBootstrapped || !prefix.isSteamExe64Bit
        guard needsClientBootstrap else {
            log.info("[bootstrapClient] steamui.dll present and steam.exe is 64-bit — skipping")
            return
        }
        if prefix.isSteamBootstrapped && !prefix.isSteamExe64Bit {
            log.info("[bootstrapClient] installed steam.exe is 32-bit — re-bootstrapping with win64 client")
        }

        signInPhase = .downloading
        // Engage suppression before the download in case Steam ever renders UI.
        steamWindow?.startSuppressing()
        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()

        let installDir = prefix.steamInstallDir
        let progress: @Sendable (Int64, Int64) -> Void = { [weak self] downloaded, total in
            Task { @MainActor [weak self] in
                if total > 0, downloaded < total {
                    self?.clientDownload = DownloadProgress(received: downloaded, total: total)
                    self?.signInPhase = .downloading
                    onStatus?("Downloading Steam")
                } else {
                    self?.clientDownload = nil
                    self?.signInPhase = .installing
                    onStatus?("Installing Steam")
                }
            }
        }
        defer { clientDownload = nil }

        log.info("[bootstrapClient] native download into \(installDir.path(percentEncoded: false))")
        do {
            try await SteamClientBootstrap.downloadAndInstall(to: installDir, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // FAIL-FAST: one clean retry — discard partial/corrupt package cache.
            log.warning("[bootstrapClient] Steam client download failed (\(error.localizedDescription)) — one clean retry")
            let pkgDir = installDir.appending(path: "package")
            try? FileManager.default.removeItem(at: pkgDir)
            try await SteamClientBootstrap.downloadAndInstall(to: installDir, progress: progress)
        }

        let fm = FileManager.default
        let dllPath = installDir.appending(path: "steamui.dll").path(percentEncoded: false)
        let altPath = installDir.appending(path: "SteamUI.dll").path(percentEncoded: false)
        guard fm.fileExists(atPath: dllPath) || fm.fileExists(atPath: altPath) else {
            log.error("[bootstrapClient] steamui.dll missing after native bootstrap")
            throw SteamClientBootstrap.BootstrapError.steamuiMissing
        }
        log.info("[bootstrapClient] Steam client bootstrap complete ✓")
    }

    // MARK: - Self-update health monitor

    /// Watches the persistent steam.exe and relaunches it when Steam
    /// terminates with `exit=42` — Valve's "self-update completed, please
    /// restart me" sentinel that fires periodically as Valve ships new
    /// client builds.
    ///
    /// **Why this is necessary:** On Windows, `steam.exe` IS its own
    /// launcher and re-execs itself in place. Under Wine on macOS each
    /// process is a separate POSIX process; when steam.exe exits, every
    /// game process attached to the same wineserver dies with it within
    /// seconds (wineserver shuts down when no Wine processes are attached
    /// to it). Without a launcher-side relaunch the game appears to crash
    /// at random — usually 1–3 minutes after Steam first reaches
    /// `[Logged On, ` in connection_log.txt.
    ///
    /// **Why exit=42 specifically:** Steam uses 42 as its
    /// "intentional restart" sentinel both during initial client-bootstrap
    /// (see `bootstrapSteamClientIfNeeded`) and during runtime
    /// auto-update. CLI-verified May 20 2026 — the log line
    /// `[steam.exe] exited code=42` correlates 1:1 with wineserver dying
    /// and the running game ending in `Wine environment stopped before
    /// the game could start`.
    ///
    /// We restart up to `Self.maxRestartAttempts` times in a short window
    /// to prevent a runaway loop if Steam is genuinely broken (e.g.
    /// corrupted client files). Each restart re-runs the silent auth path,
    /// because if Steam updated client files we need to wait for
    /// `[Logged On,` again before declaring success.
    private func startHealthMonitor(engine: WineEngine) {
        healthMonitorTask?.cancel()
        healthGeneration &+= 1
        let generation = healthGeneration
        let process = persistentProcess
        guard let process else { return }

        healthMonitorTask = Task { [weak self] in
            await self?.monitorSteamHealth(
                generation: generation,
                initialProcess: process,
                engine: engine
            )
        }
    }

    /// Max consecutive code=42 restarts within `restartWindow` before
    /// we give up and surface `.failed`. Steam under healthy conditions
    /// self-updates at most once per session — three within 60 s is a
    /// genuine failure (corrupt client, network outage, etc.).
    private static let maxRestartAttempts = 3
    private static let restartWindow: Duration = .seconds(60)

    private func monitorSteamHealth(
        generation: Int,
        initialProcess: Process,
        engine: WineEngine
    ) async {
        var process = initialProcess
        var recentRestarts: [ContinuousClock.Instant] = []

        while !Task.isCancelled {
            // Wait for the current steam.exe to exit. `terminationStatus`
            // is only valid after the process has actually finished, so
            // we sleep-poll on `isRunning` (the only async-safe way).
            while process.isRunning && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard generation == healthGeneration else { return }
            }
            if Task.isCancelled || generation != healthGeneration { return }

            let code = process.terminationStatus
            log.info("[healthMonitor] steam.exe exited code=\(code) generation=\(generation)")

            // Non-42 exit during running state = Steam is genuinely gone
            // (crashed, killed externally, user signed out). The session
            // state must not lie (fail-fast): a dead steam.exe behind
            // `isReady == true` makes `ensureReadyForDRM` skip the entire
            // bring-up and dispatch `-applaunch` against nothing — the
            // fresh steam.exe then cold-boots unmanaged (no waitForLoggedOn,
            // no suppression re-engagement) and steamwebhelper windows can
            // surface. `.idle` is retryable — `start()` accepts it.
            guard code == 42 else {
                log.info("[healthMonitor] non-restart exit — marking session idle (was \(String(describing: state)))")
                if case .running = state { state = .idle }
                return
            }

            // Trim restarts older than the window and bail if we've
            // exceeded our budget. Each restart is appended below.
            let now = ContinuousClock.now
            recentRestarts.removeAll { now - $0 > Self.restartWindow }
            if recentRestarts.count >= Self.maxRestartAttempts {
                log.error("[healthMonitor] \(recentRestarts.count) restarts within \(Self.restartWindow) — giving up")
                state = .failed("Steam keeps restarting unexpectedly. Try quitting and reopening Meridian.")
                return
            }
            recentRestarts.append(now)

            // Relaunch transparently. We DO NOT call `start()` to avoid
            // double-engaging the SteamWindow suppressor (it's already
            // engaged) or resetting state. Instead replicate the minimum
            // needed: launch process + wait for Logged On + register PID.
            log.info("[healthMonitor] relaunching steam.exe -silent after self-update (attempt \(recentRestarts.count)/\(Self.maxRestartAttempts))")
            do {
                try await launchSteamProcess(engine: engine)
            } catch {
                log.error("[healthMonitor] relaunch failed: \(error.localizedDescription)")
                state = .failed("Steam restart failed: \(error.localizedDescription)")
                return
            }

            guard generation == healthGeneration else { return }
            guard let newProcess = persistentProcess else {
                log.error("[healthMonitor] persistentProcess missing after relaunch")
                state = .failed("Steam restart failed: no process reference")
                return
            }
            process = newProcess

            let result = await waitForLoggedOn(
                engine: engine,
                timeout: .seconds(120),
                authTimeout: .seconds(30)
            )
            guard generation == healthGeneration else { return }

            switch result {
            case .loggedOn:
                let pid = newProcess.isRunning ? newProcess.processIdentifier : 0
                state = .running(pid: pid_t(pid))
                log.info("[healthMonitor] ✓ Steam restored after self-update (pid=\(pid))")
            case .signedOut:
                logSteamFailureDiagnostics(reason: "self-update relaunch has no usable sign-in")
                markSignedOut()
                return
            case .failed:
                log.error("[healthMonitor] Steam did not reach Logged On after self-update")
                logSteamFailureDiagnostics(reason: "self-update relaunch did not reach [Logged On,")
                state = .failed("Steam restart didn't complete sign-in. Try quitting and reopening Meridian.")
                return
            }
            // Loop back to wait for the next exit.
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
        // Bump generation FIRST so the health monitor can detect this is an
        // intentional shutdown and not race-relaunch the process we're about
        // to kill. The task itself cancels normally; the generation check is
        // a belt-and-suspenders in case the cancel propagates lazily.
        healthGeneration &+= 1
        healthMonitorTask?.cancel()
        healthMonitorTask = nil

        // Send steam.exe -shutdown via a second process instance. Steam's IPC
        // dispatches this as a graceful shutdown request to the running
        // instance. Only when Steam is running: with none to receive it,
        // `-shutdown` starts a full Steam with its library, store popup and
        // friends list on screen (Oct 8 2026, after quitting Meridian).
        let steamRunning = await Task.detached(operation: { Self.isSteamRunning() }).value
        if steamRunning, let wineURL = engine.wineExecutableURL {
            let shutdown = Process()
            shutdown.executableURL = wineURL
            shutdown.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
            shutdown.environment = engine.steamCMDEnvironment(for: prefix)
            shutdown.standardOutput = FileHandle.nullDevice
            shutdown.standardError = FileHandle.nullDevice
            try? shutdown.run()
            // Let Steam exit on its own (it writes its config on the way
            // out); force-kill only after 15 s.
            let started = ContinuousClock.now
            repeat {
                try? await Task.sleep(for: .milliseconds(500))
            } while await Task.detached(operation: { Self.isSteamRunning() }).value
                && ContinuousClock.now - started < .seconds(15)
        }

        // Always kill — orphan processes can exist outside our tracking.
        killAllWineProcesses(engine: engine)
        // Only now: on -shutdown Steam shows its library window with a
        // "Shutdown" popup over it, which flashed on screen while it exited
        // (webhelper.txt `SP Desktop_uid0-'Steam': WasHidden 0`, Oct 12 2026).
        steamWindow?.stopSuppressing()
        persistentProcess = nil
        state = .idle
    }

    /// Settings › Sign Out, Steam's half: quit Steam before
    /// `SteamAuthService.signOut()` deletes its session file (local.vdf).
    /// Steam writes that file as it quits, and a running Steam stayed signed
    /// in to the old account.
    func signOut(engine: WineEngine) async {
        log.info("[signOut] quitting Steam before its sign-in is deleted")
        warmUpTask?.cancel()
        await shutdown(engine: engine)
        pendingEulaAcceptances = []
    }

    /// Aggressive kill of all Wine processes in the prefix. Used before starting
    /// a fresh steam.exe and during termination cleanup.
    nonisolated private static func isSteamRunning() -> Bool {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/pgrep")
        p.arguments = ["-f", "Steam\\\\steam.exe"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

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

    /// Silently install a game. Requires `isReady == true` (a persistent
    /// `steam.exe -silent` process must already be authenticated).
    ///
    /// ## Why we restart Steam instead of using `steam://install`
    ///
    /// Valve's `steam://install/<appID>` URL handler ALWAYS opens the
    /// install-location picker dialog. There is no Steam URL that bypasses
    /// it — Valve assumes users want to choose a disk + library. CLI-
    /// confirmed user report May 20 2026: every install attempt showed
    /// the full Steam "Choose where to install" dialog before downloading
    /// even started.
    ///
    /// The ONLY silent-install mechanism Steam supports is the
    /// **library-scan-at-startup** path: if `steamapps/appmanifest_<id>.acf`
    /// exists with `StateFlags == 1026` when Steam starts, Steam picks it
    /// up during its login post-callback library scan and silently downloads
    /// from the install location encoded in the ACF — no picker, no UI. This
    /// is the same code path Steam Desktop uses when a user moves their
    /// Steam library to a new disk and restarts Steam.
    ///
    /// So `installGame` writes a pre-seeded ACF, then restarts Steam:
    ///
    ///   1. `writePreseededAppManifest` writes the ACF with `installdir`,
    ///      `name`, `LastOwner`, and `StateFlags=1026`.
    ///   2. `shutdown` tears down the running Steam (graceful `-shutdown`
    ///      IPC + `wineserver -k`).
    ///   3. `start` launches `steam.exe -silent` and waits for `[Logged On, `.
    ///      During Steam's startup library scan it discovers the new ACF and
    ///      silently begins downloading.
    ///
    /// Progress is then observed by `Launcher.pollDownloadProgress` reading
    /// `bytesOnDiskForDownload` + `bytesOnDiskForInstall` directly from the
    /// filesystem. No Steam UI is rendered at any point.
    ///
    /// ## Trade-offs
    ///
    /// - Restarting Steam takes 8–15 s. The UI shows "Preparing install…"
    ///   during that window.
    /// - Any DRM game currently running through this Steam will die when
    ///   wineserver tears down. Callers must ensure no game is in `.running`
    ///   before invoking `installGame`. `Launcher.executePipeline`'s guard
    ///   already enforces this (early-return when `launchState == .running`,
    ///   `.installing`, etc.).
    /// - With `WinePrefix.refreshSteamStubFromEngineIfStale` now repairing
    ///   only on missing/corrupt (not "different size from bundle"), Steam's
    ///   own self-update no longer fires on every restart — the restart is
    ///   quick because Steam verifies its files are current.
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

        // 1. Pre-seed the ACF manifest. StateFlags=1026 (UpdateRequired
        //    bit + Validating bit) is the value Steam writes when an ACF
        //    is queued for download. The installdir field tells Steam
        //    where to put files; with this set, no picker is needed.
        onStatus?("Preparing \(name)…")
        log.info("[installGame] writing pre-seeded appmanifest for appID=\(appID) name=\"\(name)\"")
        try prefix.writePreseededAppManifest(
            appID: appID,
            name: name,
            installDir: installDir,
            steamID64: steamID64
        )

        // 2. Cycle Steam so its login-post-callback library scan picks up
        //    the new ACF. The shutdown is graceful; start re-runs the
        //    silent auth + health monitor pipeline.
        log.info("[installGame] cycling steam.exe so library scan picks up pre-seeded ACF")
        onStatus?("Asking Steam to start the download…")
        await shutdown(engine: engine)
        try? await Task.sleep(for: .seconds(1))
        await start(engine: engine)

        guard isReady else {
            // start() failed to reach Logged On after the restart — the
            // pre-seeded ACF is still on disk, so the next successful
            // Steam start (next Meridian launch, or user sign-in retry)
            // will pick it up and complete the install. Surface as a
            // user-visible error so they know something happened.
            throw SessionError.installRestartFailed(name)
        }

        onStatus?("Downloading \(name)…")
        log.info("[installGame] ACF pre-seeded + Steam restarted — download starts via library scan")
    }

    /// Launch a game whose `steam_api64.dll` requires a live Steam IPC
    /// socket (Steamworks DRM). Dispatched via `steam.exe -applaunch`
    /// instead of `wine64 game.exe` directly so:
    ///
    /// - Steam picks the right exe (UE5 launcher → real game.exe chain
    ///   is handled internally — no "launching with custom args" dialog
    ///   that the direct-wine64 path triggered, CLI-confirmed user report
    ///   May 20 2026 launching Bogos Binted).
    /// - Steam applies registered launch options, environment, and DRM
    ///   verification. SteamAPI_Init succeeds first-try, no race.
    /// - No second Steam process: the new `wine64 steam.exe -applaunch`
    ///   detects the running Steam's IPC pipe and forwards the command,
    ///   exiting in ~1 s. Same pattern as `steam://install` forwarding.
    ///
    /// Every game launches this way (Offline was removed Oct 8 2026).
    /// `arguments` reach the game's command line.
    func launchGameViaSteam(appID: Int, arguments: [String] = [], engine: WineEngine) throws {
        guard isReady else {
            throw SessionError.steamNotReady
        }
        log.info("[launchGameViaSteam] dispatching -applaunch \(appID) \(arguments.joined(separator: " ")) via IPC")
        try sendSteamCommand(["-applaunch", "\(appID)"] + arguments, engine: engine)
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
        let profile = compat.profile(for: appID)
        if let profile {
            switch profile.dxmtMode {
            case .disabled:
                // Per-game opt-out of DXMT: Wine's own D3D for games DXMT
                // mis-renders. Dropping lib/dxmt from the search path is what
                // selects wined3d; `b` keeps a game-shipped d3d11 from winning.
                env["WINEDLLPATH"] = engine.dllSearchPath(preferring: nil)
                env["WINEDLLOVERRIDES"] = mergeWineDllOverrides(
                    env["WINEDLLOVERRIDES"],
                    overriding: ["d3d11", "dxgi"],
                    with: "b"
                )
            case .required, .auto:
                break
            }
        }

        // DX12 → GPTK routing. The effective graphics API is the explicit
        // profile's (hand-verified override) when set, otherwise the resolved
        // value from GameStackResolver (PCGamingWiki's tested Direct3D version,
        // or local engine-default). This means a DX12 game with NO explicit
        // compat entry — identified by detection/PCGW — still gets the GPTK
        // (D3D12 → D3DMetal → Metal) path instead of falling through to the
        // DX11/DXMT global default. The resolver cache is warmed by the
        // launcher immediately before this is called (`resolve(appID:...)`);
        // on a cold cache this is nil and behaviour is unchanged (DXMT default).
        let effectiveAPI: GraphicsAPI = {
            if let a = profile?.graphicsAPI, a != .unknown { return a }
            return GameStackResolver.shared.cached(appID: appID)?.graphicsAPI ?? .unknown
        }()
        if effectiveAPI == .dx12, let gptk = engine.gptkPath {
            // GPTK's builtins (d3d12, dxgi, d3d11) first in the search path.
            env["WINEDLLPATH"] = engine.dllSearchPath(preferring: "\(gptk)/wine")
            env["WINEDLLOVERRIDES"] = mergeWineDllOverrides(
                env["WINEDLLOVERRIDES"],
                overriding: ["d3d12", "dxgi"],
                with: "b"
            )
        }

        // D3DMetal opt-in (per-game): D3D11/DXGI/D3D12 all from Apple GPTK.
        // Why: DXMT cannot service the Media Foundation video processor's D3D11
        // texture path → Unity VideoPlayer / MF cutscenes render black. D3DMetal
        // is a complete D3D11 implementation that does (user-verified June 2026
        // on "No, I'm not a Human"; engine-research-findings.mdc Pattern 22).
        // Only engines that carry lib/gptk have it; the shipped engine does not.
        if profile?.preferD3DMetal == true, let gptk = engine.gptkPath {
            env["WINEDLLPATH"] = engine.dllSearchPath(preferring: "\(gptk)/wine")
            env.removeValue(forKey: "WINEDLLOVERRIDES")
        }

        // DLSS → MetalFX bridge (GPTK 4 `nvngx-on-metalfx`). When a DLSS title
        // opts in and the engine's GPTK ships the shim (nvngx.dll staged by
        // release-engine.sh with GPTK4_ROOT), force Wine to load the native
        // nvngx PE so the game's DLSS calls route to MetalFX Temporal + Metal 4
        // frame interpolation instead of failing on absent NVIDIA hardware.
        // No effect if the shim isn't present (WINEDLLPATH won't resolve it).
        if profile?.enableDLSSBridge == true, let gptk = engine.gptkPath {
            let nvngx = "\(gptk)/wine/x86_64-windows/nvngx.dll"
            if FileManager.default.fileExists(atPath: nvngx) {
                env["WINEDLLOVERRIDES"] = mergeWineDllOverrides(
                    env["WINEDLLOVERRIDES"],
                    overriding: ["nvngx", "nvngx_dlss"],
                    with: "n"
                )
                log.info("[gameEnvironment] DLSS→MetalFX bridge enabled for appID=\(appID)")
            } else {
                log.warning("[gameEnvironment] enableDLSSBridge set but nvngx.dll not in engine — ship a GPTK 4 engine (GPTK4_ROOT)")
            }
        }
        return env
    }

    /// Merges a fresh `key=value` override pair into an existing
    /// `WINEDLLOVERRIDES` string while preserving every other DLL the
    /// caller cared about. Wine's format is `dll1[,dll2]=mode[;dll3=…]`,
    /// where the LAST entry for a given DLL wins on parse — so naive
    /// concatenation usually works, but builds up duplicates fast and
    /// makes the env line unreadable in logs.
    ///
    /// This helper removes any prior entry that mentioned any of
    /// `overriding` and re-appends the consolidated `key1,key2=value`.
    private func mergeWineDllOverrides(
        _ existing: String?,
        overriding dlls: [String],
        with mode: String
    ) -> String {
        let dllSet = Set(dlls)
        var kept: [String] = []
        let current = existing ?? ""
        for entry in current.split(separator: ";", omittingEmptySubsequences: true) {
            let pair = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard let lhs = pair.first else { continue }
            let names = lhs.split(separator: ",").map(String.init)
            if names.allSatisfy({ !dllSet.contains($0) }) {
                kept.append(String(entry))
            }
        }
        kept.append("\(dlls.joined(separator: ","))=\(mode)")
        return kept.joined(separator: ";")
    }

    // MARK: - Private: launch steam.exe

    private func launchSteamProcess(engine: WineEngine, interactive: Bool = false) async throws {
        guard persistentProcess == nil || !(persistentProcess?.isRunning ?? false) else {
            log.info("[launchSteamProcess] already running — skipping")
            return
        }

        // Write registry keys for silent/minimized mode before starting
        // (once per bottle; each key is its own Wine process).
        if await configureSteamRegistry(engine: engine) {
            try? await Task.sleep(for: .seconds(2))
        }

        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()
        prefix.clearCrashMarker()

        appsSteamLoaded = prefix.appManifestIDs()
        if !pendingEulaAcceptances.isEmpty {
            do {
                try prefix.writeEulaAcceptances(pendingEulaAcceptances,
                                                steamID64: AppSettings.shared.steamCredentialSteamID)
                pendingEulaAcceptances = []
            } catch {
                // Steam asks in its own window instead (Launcher shows it).
                log.error("[launchSteamProcess] couldn't record accepted license agreements: \(error.localizedDescription)")
            }
        }
        connectionLogOffset = connectionLogFileSize()
        webhelperLogOffset = fileSize(of: prefix.steamInstallDir
            .appending(path: "logs/webhelper_js.txt")
            .path(percentEncoded: false))

        let steamExePath = prefix.steamExePath.path(percentEncoded: false)
        // Default: -silent — auth comes from Steam's own persisted session
        // (restored by SteamSessionBackup / written by a prior interactive
        // sign-in). Interactive: NO -silent, so Steam renders its own sign-in
        // window for the one-time Online-mode login (`signInInteractively`).
        let args = interactive
            ? [steamExePath, "-nofriendsui"]
            : [steamExePath, "-silent", "-nofriendsui"]

        log.info("[launchSteamProcess] wine64 \(args.joined(separator: " "))")

        var env = engine.steamClientEnvironment(for: prefix)
        // The accessory dylib gives Steam's sign-in window macOS chrome
        // (rounded corners, shadow, fade-in) — only for this launch.
        if interactive { env["MERIDIAN_STEAM_SIGNIN"] = "1" }
        // With Accessibility access, SteamWindow hides Steam's windows and
        // brings back the ones the player needs; the dylib then keeps a hidden
        // window off-screen when Steam shows it again (its library flashed at
        // the top-left as Steam quit). Without access, Steam places them.
        if steamWindow?.isPermissionGranted == true { env["MERIDIAN_HIDE_STEAM_WINDOWS"] = "1" }
        // Diagnostic: confirm the DYLD_INSERT_LIBRARIES dock-suppression payload
        // is in the env Steam will see. If this is missing or the dylib path
        // is broken, the Wine subprocess won't get demoted to .accessory and
        // we'll see a wine64 Dock icon. Pair with the `[meridian-wine-
        // accessory]` lines in logs/wine-steam.log from the
        // dylib's own NSLog when it loads successfully.
        if let dyld = env["DYLD_INSERT_LIBRARIES"] {
            let exists = FileManager.default.fileExists(atPath: dyld)
            log.info("[launchSteamProcess] DYLD_INSERT_LIBRARIES=\(dyld) exists=\(exists)")
        } else {
            log.warning("[launchSteamProcess] DYLD_INSERT_LIBRARIES not set — wine64 will appear in Dock")
        }

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        // Steam's and its games' Wine output, kernel-written to disk
        // (GameLogFile.steamOutputURL); Launcher copies each game session's
        // slice into the game's log.
        let output = GameLogFile.beginSteamOutput(arguments: args)
        process.standardError = output ?? FileHandle.nullDevice
        process.terminationHandler = { finished in
            log.info("[steam.exe] exited code=\(finished.terminationStatus)")
        }

        try process.run()
        try? output?.close()  // the child holds its own descriptor
        persistentProcess = process
        runningWineDebug = env["WINEDEBUG"]
        let pid = process.processIdentifier
        log.info("[launchSteamProcess] pid=\(pid) interactive=\(interactive)")

        // Register PID with window suppressor immediately for instant hide —
        // EXCEPT for the interactive sign-in launch, whose window must render.
        // `signInInteractively` registers the PID itself once `[Logged On,`
        // is reached.
        if !interactive {
            steamWindow?.registerPID(pid_t(pid))
        }

        // Store paths for TerminationCleanup so wineserver -k works at quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )
    }

    /// Bump when the keys below change so existing bottles get them once.
    private static let steamRegistryVersion = "2"

    /// Writes Steam's registry keys unless this bottle already has this
    /// version of them. They cost about 5 s per launch (one Wine process
    /// per key, then a settle delay) and never change between launches.
    /// Returns whether it wrote anything.
    private func configureSteamRegistry(engine: WineEngine) async -> Bool {
        let marker = prefix.path.appending(path: ".meridian-steam-registry")
        if (try? String(contentsOf: marker, encoding: .utf8)) == Self.steamRegistryVersion { return false }
        defer { try? Self.steamRegistryVersion.write(to: marker, atomically: true, encoding: .utf8) }
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
            // Suppress Steam's post-login "you have new games" toast burst.
            // After silent auth, Steam scans cloud-known + locally-cached
            // appmanifests and announces every "installed" game via Windows
            // toasts that Wine forwards to the macOS Notification Center.
            // Meridian renders its own native library — Steam's toasts are
            // never useful and can't be acted on (the user can't see Steam's
            // UI to dismiss them). Belt-and-suspenders with the `localconfig.vdf`
            // toggles that `WinePrefix.writeUserNotificationPreferences` writes
            // post-sign-in — that file controls the webhelper-side toggles,
            // these registry keys control the native-UI side. Both are needed
            // because Steam routes different toasts through different layers.
            reg(["reg", "add",
                 "HKCU\\Software\\Valve\\Steam",
                 "/v", "NotifyAvailableGames", "/t", "REG_DWORD", "/d", "0", "/f"])
            reg(["reg", "add",
                 "HKCU\\Software\\Valve\\Steam",
                 "/v", "DesktopNotifications", "/t", "REG_DWORD", "/d", "0", "/f"])
            reg(["reg", "add",
                 "HKCU\\Software\\Valve\\Steam",
                 "/v", "EnableGameOverlay", "/t", "REG_DWORD", "/d", "0", "/f"])
            // Per executable (an empty value disables the DLL), because games
            // inherit steam.exe's environment and need both:
            // - mmdevapi: Steam's own sounds stay off.
            // - winegstreamer: with the GStreamer plugin paths games need for
            //   video, Steam's web UI stalled before loading the saved
            //   account, so every silent start failed (CLI-bisected Oct 8
            //   2026, Pattern 39). Steam never had working GStreamer before.
            for exe in ["steam.exe", "steamwebhelper.exe"] {
                for dll in ["mmdevapi", "winegstreamer"] {
                    reg(["reg", "add",
                         "HKCU\\Software\\Wine\\AppDefaults\\\(exe)\\DllOverrides",
                         "/v", dll, "/t", "REG_SZ", "/d", "", "/f"])
                }
            }
        }.value
        return true
    }

    // MARK: - Private: wait for auth outcome

    /// True when connection_log content shows Steam actively performing a
    /// CREDENTIALED logon: it has set a non-zero SteamID on the CM interface
    /// and/or issued LogOn. This is the signal (fail-fast rule: observable
    /// signals over wall-clock deadlines) that Steam holds a persisted session
    /// and is authenticating — the short post-Connected deadline must then
    /// yield to the overall timeout, because a cold post-update start can take
    /// 20-40 s to reach `[Logged On,` (observed Jul 2 2026: silent auth was
    /// declared dead at 12 s while `SetSteamID [U:1:86752607]` had appeared at
    /// 3 s and the logon completed fine moments later — Bug E).
    ///
    /// MIRROR CONTRACT: mirrored in OnlineFlowTests.hasCredentialedLogonActivity.
    static func hasCredentialedLogonActivity(_ content: String) -> Bool {
        if content.contains("Logging on [U:1:") { return true }
        if content.contains("LogOn() called") { return true }
        // SetSteamID with a NON-ZERO id — "[U:1:0]" appears during anonymous
        // connect and must not count.
        var search = content[...]
        while let r = search.range(of: "SetSteamID( [U:1:") {
            let after = search[r.upperBound...]
            if let first = after.first, first != "0" { return true }
            search = after
        }
        return false
    }

    /// Wait for `[Logged On, ]` in connection_log.txt. State remains unchanged;
    /// the caller sets it from the result. `.signedOut` when Valve rejects the
    /// saved sign-in (fast-fail) or Steam starts no logon at all; `.failed` on
    /// a crash, a wedged webhelper or the overall timeout.
    ///
    /// `authTimeout` bounds the "Connected but Steam has NOT started a
    /// credentialed logon" window (fresh user, no session on disk — fail fast
    /// to the sign-in sheet). Once credentialed logon activity is observed,
    /// only the overall `timeout` and the explicit rejection markers apply.
    ///
    /// `onStatus` emits human-readable stages as connection_log markers
    /// appear so the launch card never sits on one message for 20+ s.
    private func waitForLoggedOn(
        engine: WineEngine,
        timeout: Duration,
        authTimeout: Duration,
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async -> LogonResult {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)

        let started = ContinuousClock.now
        var connectedAt: ContinuousClock.Instant?
        var logonActivitySeen = false
        var poll = 0
        var lastReportedStage = ""
        func report(_ message: String) {
            guard message != lastReportedStage else { return }
            lastReportedStage = message
            onStatus?(message)
        }

        report("Starting Steam client…")

        while ContinuousClock.now - started < timeout {
            if Task.isCancelled { return .failed }
            poll += 1

            // If tracked process exited non-42, fail immediately.
            if let p = persistentProcess, !p.isRunning {
                let code = p.terminationStatus
                if code == 42 {
                    // Steam self-update restart — keep waiting.
                    log.info("[waitForLoggedOn] code=42 self-update restart, continuing…")
                    persistentProcess = nil
                    report("Steam is updating itself…")
                } else {
                    log.error("[waitForLoggedOn] steam.exe exited code=\(code)")
                    return .failed
                }
            }

            let content = readLogTail(path: connLogPath, from: connectionLogOffset)

            if content.contains("[Logged On, ") {
                log.info("[waitForLoggedOn] ✓ Logged On after \(poll) polls")
                killWebhelper()
                return .loggedOn
            }

            // Fast-fail: Valve explicitly rejected the token.
            if content.contains("LogonFailureReceived")
                || content.contains("Sending SteamServerConnectFailure_t Invalid Password") {
                log.error("[waitForLoggedOn] Valve rejected token — auth failed")
                killWebhelper()
                return .signedOut
            }

            // User-facing stages — most advanced marker wins (fail-fast: observable
            // signals from connection_log, not wall-clock guesses).
            if content.contains("RecvMsgClientLogOnResponse") && content.contains("'OK'") {
                report("Finishing sign-in…")
            } else if !logonActivitySeen, Self.hasCredentialedLogonActivity(content) {
                logonActivitySeen = true
                log.info("[waitForLoggedOn] credentialed logon in progress — extending deadline to overall timeout")
                report("Signing in to your Steam account…")
            } else if connectedAt != nil {
                report("Connected to Steam servers")
            } else if persistentProcess?.isRunning == true, poll > 4 {
                report("Connecting to Steam servers…")
            }

            if connectedAt == nil, content.contains("Connectivity test: result=Connected") {
                connectedAt = ContinuousClock.now
                log.info("[waitForLoggedOn] Connected — waiting up to \(authTimeout) for logon activity")
            }

            // The short deadline only applies while Steam shows NO sign of a
            // credentialed logon (fresh user / no session). Once logon
            // activity is observed, Valve's explicit rejection markers and the
            // overall timeout own failure detection.
            if !logonActivitySeen, let ca = connectedAt, ContinuousClock.now - ca > authTimeout {
                log.warning("[waitForLoggedOn] no credentialed logon activity within \(authTimeout) of Connected — no session on disk")
                killWebhelper()
                return .signedOut
            }

            // Webhelper connect failures = silent auth wedged (hidden
            // "Who's playing" prompt). Only meaningful BEFORE a credentialed
            // logon starts, and only for THIS session's log tail — reading
            // from offset 0 counted stale failures from previous runs.
            if !logonActivitySeen {
                let webhelperPath = prefix.steamInstallDir
                    .appending(path: "logs/webhelper_js.txt")
                    .path(percentEncoded: false)
                let webContent = readLogTail(path: webhelperPath, from: webhelperLogOffset)
                let failures = webContent.components(separatedBy: "connect attempt failed").count - 1
                if failures >= 2 {
                    log.error("[waitForLoggedOn] webhelper connect failed ×\(failures) this session — rejecting")
                    killWebhelper()
                    return .failed
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        log.warning("[waitForLoggedOn] overall timeout after \(timeout) (logonActivitySeen=\(logonActivitySeen))")
        return .failed
    }

    /// Steam has no usable sign-in. Forget that Steam was signed in, so the
    /// next launch asks before opening Steam's sign-in, and drop the backup of
    /// Steam's session file: restoring it would only bring back the rejected
    /// sign-in. Valve can end a saved sign-in on its own (meridian.log
    /// Oct 11 2026: a 4-day-old Steam sign-in that logged on 7 times on Oct 8
    /// came back 'Access Denied' with Meridian not running in between).
    private func markSignedOut() {
        log.warning("[signedOut] Steam has no usable sign-in; the next launch asks to sign in again")
        AppSettings.shared.steamClientSignedIn = false
        SteamSessionBackup.clear()
        state = .signedOut
    }

    // MARK: - Private: helpers

    private func connectionLogFileSize() -> Int {
        fileSize(of: prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false))
    }

    private func fileSize(of path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int) ?? 0
    }

    private func readLogTail(path: String, from offset: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: URL(filePath: path)) else { return "" }
        try? fh.seek(toOffset: UInt64(offset))
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Dumps the tails of steam.exe's own diagnostic logs into meridian.log so a
    /// failed start is self-explanatory without attaching Xcode or hand-reading
    /// the prefix. Called from every failure path in `start()` / the health
    /// monitor.
    ///
    /// `bootstrap_log.txt` records the bootstrapper's verify/update/handoff
    /// decisions (e.g. `Download failed: http error 0`, `Crypto API failed
    /// certificate check`, `steam_client_win64.installed` verify result).
    /// `connection_log.txt` records the CM logon outcome (`[Logged On,`,
    /// `LogonFailureReceived`, etc.). Together they pinpoint whether the failure
    /// was client-bootstrap (no steamclient handoff) or auth (CM rejection).
    private func logSteamFailureDiagnostics(reason: String) {
        let steamDir = prefix.steamInstallDir
        let logsDir = steamDir.appending(path: "logs")
        let sources: [(label: String, path: String)] = [
            ("bootstrap_log.txt", logsDir.appending(path: "bootstrap_log.txt").path(percentEncoded: false)),
            ("connection_log.txt", logsDir.appending(path: "connection_log.txt").path(percentEncoded: false)),
        ]

        log.error("╔══ STEAM START FAILED: \(reason)")
        for (label, path) in sources {
            guard FileManager.default.fileExists(atPath: path) else {
                log.error("║ [\(label)] (absent — steam.exe wrote no \(label))")
                continue
            }
            let full = readLogTail(path: path, from: 0)
            let tail = Self.lastLines(of: full, count: 30)
            if tail.isEmpty {
                log.error("║ [\(label)] (empty)")
                continue
            }
            log.error("║ ── \(label) (last 30 lines) ──")
            for line in tail.components(separatedBy: .newlines) where !line.isEmpty {
                log.error("║   \(line)")
            }
        }
        log.error("╚══════════════════════════════════════════════════")
    }

    private static func lastLines(of text: String, count: Int) -> String {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > count else { return lines.joined(separator: "\n") }
        return lines.suffix(count).joined(separator: "\n")
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
    /// Steam has no usable sign-in (`State.signedOut`).
    case signedOut
    case installRestartFailed(String)

    var errorDescription: String? {
        switch self {
        case .steamNotReady:
            return "Steam is not ready. Please sign in first."
        case .signedOut:
            return "Steam signed you out on this Mac. Sign in to Steam again to play."
        case .installRestartFailed(let name):
            return "Couldn't restart Steam to begin downloading \(name). The install is queued. Try again in a moment."
        }
    }
}
