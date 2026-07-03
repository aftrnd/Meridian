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
        switch state {
        case .running:
            log.info("[start] already running — skip")
            return
        case .startingSilent:
            log.info("[start] already starting — skip")
            return
        case .idle, .failed:
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
            let loggedOn = await waitForLoggedOn(
                engine: engine,
                timeout: .seconds(60),
                authTimeout: .seconds(12)
            )
            if loggedOn {
                state = .running(pid: pid_t(pid))
                log.info("[start] silent auth succeeded ✓ pid=\(pid)")
                // Begin watching the long-running steam.exe so we can transparently
                // relaunch it when Steam decides to self-update (exit code=42).
                // Without this, the user's running game dies the next time Valve
                // pushes a client update mid-session — CLI-confirmed May 20 2026.
                startHealthMonitor(engine: engine)
            } else {
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
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        if isReady { return }
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
        await start(engine: engine)
        guard isReady else {
            // start() already logged steam.exe diagnostics on the failure path.
            throw SessionError.steamNotReady
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
    /// Window policy: suppression is paused while the sign-in window is up
    /// (it must render and receive input — the ONE sanctioned Steam window
    /// besides EULA/purchase dialogs), and re-engaged the moment
    /// `[Logged On,` appears so Steam's post-login main window never paints.
    func signInInteractively(
        engine: WineEngine,
        timeout: Duration = .seconds(300),
        onStatus: (@MainActor (String) -> Void)? = nil
    ) async throws {
        if isReady { return }
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
        // Pause suppression so the sign-in window can render and take input.
        steamWindow?.pauseForGame()

        onStatus?("Opening Steam sign-in…")
        do {
            try await launchSteamProcess(engine: engine, interactive: true)
        } catch {
            steamWindow?.startSuppressing()
            state = .failed(error.localizedDescription)
            throw error
        }

        onStatus?("Waiting for you to sign in to Steam…")
        let loggedOn = await waitForInteractiveLogon(timeout: timeout)

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

        let pid = persistentProcess.flatMap { $0.isRunning ? $0.processIdentifier : nil } ?? 0
        if pid == 0 {
            // steam.exe self-updated (code=42) mid-sign-in and re-exec'd with
            // a PID we don't own. Window suppression still covers it (the
            // polling discovery + game-mode pgrep find the new PID), but the
            // code=42 health monitor cannot watch a process we have no handle
            // for — a mid-game Steam self-update will not be auto-restarted
            // this session.
            log.warning("[signInInteractively] steam.exe re-exec'd during sign-in (code=42) — pid unknown, health monitor inactive")
        }
        state = .running(pid: pid_t(pid))
        startHealthMonitor(engine: engine)

        // Snapshot Steam's own freshly-written session so it survives prefix
        // resets. Steam flushes local.vdf shortly after logon (Pattern 12).
        Task {
            try? await Task.sleep(for: .seconds(5))
            SteamSessionBackup.snapshot(prefix: self.prefix)
        }
        log.info("[signInInteractively] ✓ signed in — Steam persisted its own session")
    }

    /// Interactive variant of `waitForLoggedOn`: the user is typing
    /// credentials / scanning a QR, so there is no post-Connected auth
    /// deadline and the login page's webhelper polling is expected traffic.
    /// Fails fast only when steam.exe itself exits (user closed the window,
    /// or a crash) — the timeout is a last-resort safety net for an abandoned
    /// sign-in window.
    private func waitForInteractiveLogon(timeout: Duration) async -> Bool {
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

        // Engage suppression before the download in case Steam ever renders UI.
        steamWindow?.startSuppressing()
        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()

        let installDir = prefix.steamInstallDir
        let progress: @Sendable (Int64, Int64) -> Void = { downloaded, total in
            Task { @MainActor in
                let pct = total > 0 ? Int(downloaded * 100 / total) : 0
                let mb = downloaded / 1_048_576
                let totalMB = total / 1_048_576
                onStatus?("Downloading Steam client… \(mb)/\(totalMB) MB (\(pct)%)")
            }
        }

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

            let loggedOn = await waitForLoggedOn(
                engine: engine,
                timeout: .seconds(120),
                authTimeout: .seconds(30)
            )
            guard generation == healthGeneration else { return }

            if loggedOn {
                let pid = newProcess.isRunning ? newProcess.processIdentifier : 0
                state = .running(pid: pid_t(pid))
                log.info("[healthMonitor] ✓ Steam restored after self-update (pid=\(pid))")
            } else {
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
    /// Non-DRM games (no `steam_api64.dll`) keep using direct wine64 exec —
    /// no Steam involvement needed and a faster launch path. See
    /// `Launcher.launchDirect`.
    func launchGameViaSteam(appID: Int, engine: WineEngine) throws {
        guard isReady else {
            throw SessionError.steamNotReady
        }
        log.info("[launchGameViaSteam] dispatching -applaunch \(appID) via IPC")
        try sendSteamCommand(["-applaunch", "\(appID)"], engine: engine)
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
                // Per-game opt-out of DXMT. Replace the d3d11/dxgi pair
                // from the global override with builtin (wined3d) so games
                // that DXMT mis-renders fall back gracefully. d3d10core is
                // left as `n,b` because the global override already
                // includes it and disabling DXMT for one game shouldn't
                // also nuke d3d10core for it.
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
        if effectiveAPI == .dx12,
           let gptk = engine.gptkPath,
           let lib = engine.libraryPath {
            env["WINEDLLPATH"] = "\(gptk)/wine:\(lib)/wine"
            // Route d3d12 + dxgi through GPTK builtins. Preserve
            // d3d11/d3d10core overrides from the global DX11 default —
            // some DX12 games still load d3d11 for legacy components
            // (e.g. Unity's preprocessor probe) and need DXMT there.
            env["WINEDLLOVERRIDES"] = mergeWineDllOverrides(
                env["WINEDLLOVERRIDES"],
                overriding: ["d3d12", "dxgi"],
                with: "b"
            )
        }

        // D3DMetal opt-in (per-game). Routes D3D11/DXGI/D3D12 through Apple GPTK
        // (D3DMetal) using CX Wine's NATIVE graphics-backend switch rather than
        // hand-hacked WINEDLLOVERRIDES (the latter was tried June 2026 and failed
        // — `d3d11=b` always loads wined3d's builtin from lib/wine, never GPTK's).
        //
        // Mechanism: `CX_GRAPHICS_BACKEND=d3dmetal` makes CX Wine's `cxcompatdb.so`
        // prepend `$CX_ROOT/lib64/apple_gptk/wine/x86_64-windows` (the GPTK
        // d3d11/dxgi/d3d12 PE builtins) to the DLL search path, so they win as
        // builtins. We therefore STRIP the DXMT-first WINEDLLOVERRIDES that
        // engine.environment(for:) sets and clear WINEDLLPATH's DXMT entry so the
        // prepended GPTK builtins are not shadowed. `WineEngine.ensureAppleGptkSymlink`
        // guarantees the `lib64/apple_gptk` path resolves.
        //
        // Why: DXMT cannot service the Media Foundation video processor's D3D11
        // texture path → Unity VideoPlayer / MF cutscenes render black. D3DMetal
        // is a complete D3D11 implementation that DOES service it. CLI + user-
        // verified June 2026 on "No, I'm not a Human" (matches CrossOver 26).
        // See engine-research-findings.mdc Pattern 22.
        if profile?.preferD3DMetal == true,
           let gptk = engine.gptkPath {
            env["CX_ROOT"] = engine.cxRootPath
            env["CX_GRAPHICS_BACKEND"] = "d3dmetal"
            env.removeValue(forKey: "WINEDLLOVERRIDES")
            if let lib = engine.libraryPath {
                env["WINEDLLPATH"] = "\(gptk)/wine:\(lib)/wine"
            } else {
                env.removeValue(forKey: "WINEDLLPATH")
            }
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

        // Write registry keys for silent/minimized mode before starting.
        await configureSteamRegistry(engine: engine)
        try? await Task.sleep(for: .seconds(2))

        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()
        prefix.clearCrashMarker()

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

        let env = engine.steamCMDEnvironment(for: prefix)
        // Diagnostic: confirm the DYLD_INSERT_LIBRARIES dock-suppression payload
        // is in the env Steam will see. If this is missing or the dylib path
        // is broken, the Wine subprocess won't get demoted to .accessory and
        // we'll see a wine64 Dock icon. Pair with the `[meridian-wine-
        // accessory]` lines that show up in `[steam.exe:stderr]` from the
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

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        persistentProcess = process
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
        }.value
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

    /// Wait for `[Logged On, ]` in connection_log.txt.
    /// Returns true on success, false on timeout (state remains unchanged — caller sets it).
    /// Fast-fails immediately on explicit rejection from Valve CM.
    ///
    /// `authTimeout` bounds the "Connected but Steam has NOT started a
    /// credentialed logon" window (fresh user, no session on disk — fail fast
    /// to the sign-in sheet). Once credentialed logon activity is observed,
    /// only the overall `timeout` and the explicit rejection markers apply.
    private func waitForLoggedOn(engine: WineEngine, timeout: Duration, authTimeout: Duration) async -> Bool {
        let connLogPath = prefix.steamInstallDir
            .appending(path: "logs/connection_log.txt")
            .path(percentEncoded: false)

        let started = ContinuousClock.now
        var connectedAt: ContinuousClock.Instant?
        var logonActivitySeen = false
        var poll = 0

        while ContinuousClock.now - started < timeout {
            if Task.isCancelled { return false }
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

            if !logonActivitySeen, Self.hasCredentialedLogonActivity(content) {
                logonActivitySeen = true
                log.info("[waitForLoggedOn] credentialed logon in progress — extending deadline to overall timeout")
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
                return false
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
                    return false
                }
            }

            try? await Task.sleep(for: .milliseconds(500))
        }

        log.warning("[waitForLoggedOn] overall timeout after \(timeout) (logonActivitySeen=\(logonActivitySeen))")
        return false
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
    case installRestartFailed(String)

    var errorDescription: String? {
        switch self {
        case .steamNotReady:
            return "Steam is not ready. Please sign in first."
        case .installRestartFailed(let name):
            return "Couldn't restart Steam to begin downloading \(name). The install is queued — try again in a moment."
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
