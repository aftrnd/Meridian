import Foundation
import Observation

private let log = MeridianLog(category: "BootstrapManager")

/// Orchestrates the full app initialization pipeline at launch.
///
/// Runs each phase in order, skipping steps that are already complete
/// (prefix exists, Steam installed, etc.). The final phase starts a
/// persistent SteamCMD interactive session so game installs are instant.
///
/// steam.exe is NOT started at bootstrap — steam.exe authentication is unreliable — use SteamCMD batch mode for installs
/// and its crash-restart loop destabilizes the shared wineserver. steam.exe is only
/// started on-demand for games that require Steam DRM (steam_api64.dll).
///
/// State is published for the splash screen to display real milestones.
@Observable
@MainActor
final class BootstrapManager {

    // MARK: - Phase

    enum Phase: Equatable {
        case idle
        case awaitingPermission
        case detectingEngine
        case downloadingEngine
        case creatingPrefix
        case installingSteam
        case bootstrappingSteam
        case syncingSession
        case startingSteam
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// Human-readable status line for the splash screen.
    private(set) var statusMessage: String = ""

    var isReady: Bool { phase == .ready }

    private var bootstrapTask: Task<Void, Never>?

    /// The pipeline phase that was active when the last failure occurred.
    /// Used by retry() to decide whether targeted Steam cleanup is needed.
    private var lastFailedPhase: Phase?

    /// Set when the user taps "Continue Without" on the permission gate.
    /// Lets the pipeline proceed even though Accessibility was not granted.
    private(set) var permissionSkipped: Bool = false

    /// Set by `MeridianApp` so the bootstrap pipeline can engage window suppression
    /// after `startPersistent` completes and after automatic Steam restarts.
    var windowSuppressor: SteamWindowSuppressor?

    /// Mirrors `EngineDownloader.state` during the `.downloadingEngine` phase so
    /// `SplashView` can show a progress bar without holding a direct downloader ref.
    private(set) var engineDownloadState: EngineDownloader.DownloadState = .idle

    // MARK: - Public API

    func start(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        engineDownloader: EngineDownloader,
        steamCMDService: SteamCMDService
    ) {
        guard phase == .idle || isFailed else { return }

        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runPipeline(
                engine: engine,
                steamManager: steamManager,
                sessionBridge: sessionBridge,
                engineDownloader: engineDownloader,
                steamCMDService: steamCMDService
            )
        }
    }

    /// Cancels the bootstrap pipeline immediately.
    ///
    /// Called during app termination so Wine commands spawned by the pipeline are
    /// not left running concurrently with the termination cleanup. Without this,
    /// the bootstrap Task keeps launching Wine processes while `TerminationCleanup`
    /// is simultaneously killing them — causing race conditions and partial state.
    func cancelForTermination() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        log.info("[bootstrap] pipeline cancelled for termination")
    }

    /// Called by the SplashView "Continue Without" button.
    /// Allows the bootstrap pipeline to proceed without Accessibility permission.
    func skipPermissionRequirement() {
        permissionSkipped = true
    }

    /// Retry after a failure — performs a full Wine prefix reset then restarts.
    ///
    /// If the previous failure was during prefix creation or any Steam phase,
    /// all lingering Wine processes are killed and the entire Wine prefix is
    /// removed so the next attempt starts completely clean. This prevents the
    /// pipeline from re-running on top of a corrupt or partial state.
    func retry(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        engineDownloader: EngineDownloader,
        steamCMDService: SteamCMDService
    ) {
        let cleanupPhases: [Phase] = [.creatingPrefix, .installingSteam, .bootstrappingSteam, .startingSteam]
        if let failed = lastFailedPhase, cleanupPhases.contains(failed) {
            log.info("[retry] previous failure in \(String(describing: failed)) — killing Wine and wiping entire prefix for clean start")
            steamManager.killAll(engine: engine, prefix: prefix)
            prefix.reset()
        }
        lastFailedPhase = nil
        phase = .idle
        statusMessage = ""
        engineDownloadState = .idle
        start(engine: engine, steamManager: steamManager, sessionBridge: sessionBridge, engineDownloader: engineDownloader, steamCMDService: steamCMDService)
    }

    // MARK: - Pipeline

    private let prefix = WinePrefix.defaultPrefix
    private let settings = AppSettings.shared

    private func runPipeline(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge,
        engineDownloader: EngineDownloader,
        steamCMDService: SteamCMDService
    ) async {
        let pipelineStart = ContinuousClock.now

        // Pre-flight: set cleanup context from known static paths BEFORE running cleanup.
        //
        // The paths are fixed constants — they never vary per-machine. Setting context here
        // ensures wineserver -k runs at startup even on the very first call, before
        // startPersistent ever sets the context in the normal flow.
        //
        // Without this, wineserver -k is skipped and pkill -f is the only fallback.
        // pkill -f cannot find orphan Wine processes because Wine replaces its argv[0]
        // with the Windows program path (e.g. "C:\...\steamcmd.exe") after startup —
        // the engine path is no longer visible to pkill. wineserver -k is the only
        // reliable way to kill all Wine processes for a specific WINEPREFIX.
        if engine.isReady && TerminationCleanup.context == nil {
            let engineDir = WineEngine.engineDir
            TerminationCleanup.context = TerminationCleanup.Context(
                wineserverPath: engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false),
                winePrefix: prefix.path.path(percentEncoded: false),
                engineDirPath: engineDir.path(percentEncoded: false),
                libraryPath: engineDir.appending(path: "wine/lib").path(percentEncoded: false)
            )
            log.info("[bootstrap] cleanup context set from static paths (early, pre-cleanup)")
        }

        // Kill any orphaned Wine processes from a previous session that didn't shut down
        // cleanly. Without this, leftover wineserver processes cause SteamCMD to connect
        // to a stale/corrupt wineserver and hang indefinitely during login.
        await Task.detached(priority: .userInitiated) {
            TerminationCleanup.killAllWineProcesses()
        }.value

        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP PIPELINE START")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(self.prefix.exists)")
        log.info("║ steam installed=\(self.prefix.isSteamInstalled)")
        log.info("║ needs bootstrap=\(steamManager.needsBootstrap(prefix: self.prefix))")
        log.info("╚══════════════════════════════════════════════════")

        // 1. Detect engine — auto-download if not installed or incomplete
        transition(to: .detectingEngine, message: "Detecting Wine engine…")

        if !engine.isReady {
            log.info("[bootstrap] engine not ready (state=\(String(describing: engine.state))) — starting auto-download")
            transition(to: .downloadingEngine, message: "Downloading Wine engine…")
            engineDownloadState = .fetching

            // Start the download — onComplete fires only on success.
            // Poll the downloader state every 100 ms to forward progress to SplashView
            // and detect failure (state == .failed) since there is no error callback.
            engineDownloader.download { /* completion handled below via polling */ }

            pollLoop: while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let current = engineDownloader.state
                engineDownloadState = current
                switch current {
                case .complete:
                    log.info("[bootstrap] engine download reported complete")
                    break pollLoop
                case .failed(let msg):
                    fail("Engine download failed: \(msg)")
                    return
                default:
                    continue
                }
            }

            engine.detect()

            guard engine.isReady else {
                let detail: String
                if case .error(let msg) = engine.state { detail = msg }
                else { detail = "Engine could not be verified after download." }
                fail(detail)
                return
            }

            log.info("[bootstrap] engine downloaded and ready ✓")
        }

        log.info("[bootstrap] engine OK — \(engine.backendName)")

        // Populate TerminationCleanup context as soon as we have the engine and prefix.
        // This ensures wineserver -k works even if the user quits during bootstrap
        // before startPersistent has a chance to set it.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )

        guard !Task.isCancelled else { return }

        // 1b. Permission gate — block here until Accessibility is granted or user skips.
        //
        // The SteamWindowSuppressor requires Accessibility permission to suppress
        // Steam's windows. Without it, Steam UI will appear during install and launch.
        // We show a dedicated full-screen gate and wait. The user may skip if they choose.
        if !(windowSuppressor?.isPermissionGranted ?? false) && !permissionSkipped {
            transition(to: .awaitingPermission, message: "Accessibility permission required…")
            log.info("[bootstrap] waiting for Accessibility permission")

            // Poll every 2 s; refreshPermission() also auto-engages suppression on grant.
            while !(windowSuppressor?.isPermissionGranted ?? false) && !permissionSkipped {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                windowSuppressor?.refreshPermission()
            }

            if windowSuppressor?.isPermissionGranted == true {
                log.info("[bootstrap] Accessibility permission granted — suppressor will engage")
            } else {
                log.warning("[bootstrap] user skipped permission — Steam UI may be visible")
            }
        }

        // Window suppression is NOT engaged here — prefix operations (wineboot --init,
        // wineboot --update, SteamSetup.exe) may show transient Wine GUI windows that
        // the user doesn't need to interact with but that must be allowed to render so
        // the process can complete. Suppression begins later, right before starting
        // the persistent Steam process (step 6).

        guard !Task.isCancelled else { return }

        // 2. Create prefix if needed
        if !prefix.exists {
            transition(to: .creatingPrefix, message: "Creating Wine environment…")
            let t = ContinuousClock.now
            do {
                try await prefix.create(engine: engine)
                log.info("[bootstrap] prefix created in \(String(format: "%.1f", Double((ContinuousClock.now - t).components.seconds)))s")
            } catch {
                fail("Failed to create Wine environment: \(error.localizedDescription)")
                return
            }
            // Record the engine tag used to create this prefix so we can detect
            // future engine upgrades that require a DLL symlink refresh.
            settings.lastPrefixEngineTag = engine.engineVersion ?? ""

            // Register WinRT class mappings that Wine's wineboot doesn't create.
            await prefix.registerWinRTClasses(engine: engine)
        }

        guard !Task.isCancelled else { return }

        // 2b. Handle engine upgrades.
        //
        //     When the engine version changes, the prefix's system32 DLLs may be
        //     outdated. The preferred path (when the engine ships a prefix template)
        //     is to reset the prefix from the new template — instant file copy, no
        //     Wine processes. Steam config (loginusers.vdf, config.vdf) is preserved
        //     across the reset so auto-login continues to work.
        //
        //     Falls back to `wineboot --update` for engines without a template.
        let storedTag = settings.lastPrefixEngineTag
        let currentTag = engine.engineVersion ?? ""
        if prefix.exists && !currentTag.isEmpty && storedTag != currentTag {
            log.info("[bootstrap] engine changed \(storedTag.isEmpty ? "(unknown)" : storedTag) → \(currentTag) — resetting prefix to new engine template")
            transition(to: .creatingPrefix, message: "Applying new Wine engine…")
            let t = ContinuousClock.now
            do {
                try await prefix.resetToEngineTemplate(engine: engine)
                settings.lastPrefixEngineTag = currentTag
                log.info("[bootstrap] prefix reset to new engine template in \(String(format: "%.1f", Double((ContinuousClock.now - t).components.seconds)))s")
                await prefix.registerWinRTClasses(engine: engine)
            } catch {
                log.error("[bootstrap] prefix reset failed (non-fatal): \(error.localizedDescription) — continuing with existing prefix")
            }
        } else if storedTag == currentTag {
            log.info("[bootstrap] engine tag unchanged (\(currentTag)) — no prefix update needed")
        }

        guard !Task.isCancelled else { return }

        // 3. Install Steam if needed
        if !prefix.isSteamInstalled {
            transition(to: .installingSteam, message: "Downloading and installing Steam…")
            let t = ContinuousClock.now
            do {
                try await prefix.installSteam(engine: engine)
                log.info("[bootstrap] Steam installed in \(String(format: "%.1f", Double((ContinuousClock.now - t).components.seconds)))s")
            } catch {
                fail("Failed to install Steam: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 3b. Write steam.cfg (SteamNoSandbox=1) BEFORE bootstrap.
        //
        // Steam's webhelper (steamwebhelper.exe) renders the entire Steam UI — including
        // the update dialog and login screen. Under Wine, Chrome's sandbox fails to
        // initialise because Wine does not implement the required Windows kernel security
        // primitives. Without SteamNoSandbox=1, the webhelper crashes immediately, leaving
        // Steam headless — no update UI, no login window, no install dialogs.
        //
        // This must be written before the bootstrap step because the bootstrapper may
        // transition directly into the full client during its first run, immediately
        // trying to start the webhelper. Without this file in place at that moment,
        // the webhelper crashes and Steam appears to silently fail.
        //
        // Also ensure libraryfolders.vdf is present so Steam's install IPC works without
        // showing a hidden library-location picker on first game install.
        //
        // Both calls are idempotent: no-op if the files already contain the correct content.
        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()
        log.info("[bootstrap] steam.cfg and libraryfolders.vdf pre-written before bootstrap")

        // Ensure WinRT class registrations are up to date.
        // Only runs when the stored version is behind the current version — avoids
        // spawning a Wine process on every launch for an already-configured prefix.
        if settings.winRTRegistrationAppliedVersion < WinePrefix.winRTRegistrationVersion {
            log.info("[bootstrap] WinRT registration version \(settings.winRTRegistrationAppliedVersion) < \(WinePrefix.winRTRegistrationVersion) — re-registering")
            await prefix.registerWinRTClasses(engine: engine)
            settings.winRTRegistrationAppliedVersion = WinePrefix.winRTRegistrationVersion
        }

        // 4. Bootstrap Steam (first-run client download) if needed
        if steamManager.needsBootstrap(prefix: prefix) {
            transition(to: .bootstrappingSteam, message: "Steam is updating — first launch takes a few minutes…")
            let t = ContinuousClock.now
            do {
                try await steamManager.bootstrap(engine: engine, prefix: prefix)
                log.info("[bootstrap] Steam client bootstrapped in \(String(format: "%.1f", Double((ContinuousClock.now - t).components.seconds)))s")
            } catch {
                fail("Steam update failed: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 4b. Ensure steam.cfg and libraryfolders.vdf are still correct after bootstrap
        // (idempotent — no-op if already written above, but defensive in case bootstrap
        // replaced the Steam install directory).
        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()

        // 4b. Ensure SteamCMD is present (download if missing).
        // SteamCMD is a ~1.6MB download that self-updates to ~5MB on first run.
        // It must be in the Steam directory BEFORE any game install is attempted.
        let steamcmdPath = prefix.steamInstallDir.appending(path: "steamcmd.exe").path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: steamcmdPath) {
            log.info("[bootstrap] SteamCMD not found — downloading")
            do {
                let steamcmdURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip")!
                let (data, _) = try await URLSession.shared.data(from: steamcmdURL)
                let tempZip = FileManager.default.temporaryDirectory.appending(path: "steamcmd.zip")
                try data.write(to: tempZip)
                let unzipProcess = Process()
                unzipProcess.executableURL = URL(filePath: "/usr/bin/unzip")
                unzipProcess.arguments = ["-o", tempZip.path(percentEncoded: false), "-d", prefix.steamInstallDir.path(percentEncoded: false)]
                unzipProcess.standardOutput = FileHandle.nullDevice
                unzipProcess.standardError = FileHandle.nullDevice
                try unzipProcess.run()
                unzipProcess.waitUntilExit()
                try? FileManager.default.removeItem(at: tempZip)
                log.info("[bootstrap] SteamCMD installed ✓")
            } catch {
                log.warning("[bootstrap] SteamCMD download failed: \(error.localizedDescription) — game installs may fail")
            }
        } else {
            log.debug("[bootstrap] SteamCMD already present ✓")
        }

        // 4c. Restore SteamCMD credential cache from backup.
        // If the prefix was recreated (reset or engine upgrade), the credential
        // cache is gone. We back it up in WinePrefix.reset() and
        // resetToEngineTemplate() — restore it here so game installs don't
        // require Steam Guard re-confirmation.
        prefix.restoreSteamCMDConfig()

        // 5. Sync macOS Steam session for auto-login
        transition(to: .syncingSession, message: "Syncing Steam session…")
        let strategy = await sessionBridge.prepare(prefix: prefix)
        // Sync account username from prefix if not already in AppSettings (migration for existing users).
        sessionBridge.syncAccountNameIfNeeded(prefix: prefix)
        switch strategy {
        case .credentialAuth:
            log.info("[bootstrap] session written from credential-auth tokens ✓")
        case .sessionFileCopy:
            log.info("[bootstrap] session files copied from macOS Steam ✓")
        case .none:
            log.info("[bootstrap] no session available — Wine Steam login required")
        }

        // Record login state. credentialAuth strategy means the user already
        // authenticated through onboarding — mark as logged in immediately.
        // sessionFileCopy also sets up a session. Only .none requires interactive login.
        let hasLogin = strategy == .credentialAuth || prefix.hasSteamLoginSession()
        steamManager.isSteamLoggedIn = hasLogin
        log.info("[bootstrap] Steam login session present=\(hasLogin) strategy=\(String(describing: strategy))")

        guard !Task.isCancelled else { return }

        // 6. Engage window suppression now that all prefix operations are complete.
        // This must NOT happen earlier — prefix operations (wineboot --init,
        // wineboot --update, SteamSetup.exe) spawn transient Wine GUI windows that
        // must be allowed to render and exit naturally.
        // steam.exe is NOT started at bootstrap. We use SteamCMD batch mode for all
        // game installs. steam.exe is only started on-demand for DRM games that need
        // a live Steam IPC socket (startSteamForDRM).
        windowSuppressor?.beginSession()

        // 7. Warm up SteamCMD: run `+login USERNAME +quit` so the self-update and
        //    credential cache are ready before the user clicks Install.
        //
        // On first ever run: SteamCMD downloads ~300MB of self-updates. This takes
        // 1–3 minutes and happens here on the splash screen ("Preparing game tools…").
        //
        // On subsequent launches: SteamCMD verifies its install in ~7 seconds.
        //
        // The warm-up is non-fatal — if it fails (no network, stale credentials),
        // bootstrap still completes and installGame() will retry on demand.
        let steamCMDUsername = AppSettings.shared.steamCredentialAccountName
        if !steamCMDUsername.isEmpty && FileManager.default.fileExists(atPath: steamcmdPath) {
            // Save credentials first (instantaneous).
            try? await steamCMDService.start(
                username: steamCMDUsername,
                engine: engine,
                prefix: prefix
            )
            // Now warm up — this is where the self-update and login cache happen.
            transition(to: .startingSteam, message: "Preparing game tools…")
            log.info("[bootstrap] warming up SteamCMD (+login +quit)…")
            await steamCMDService.warmUp { [weak self] line in
                // Forward notable SteamCMD output to the splash status line
                if line.hasPrefix("[") || line.contains("Logging in") || line.contains("Waiting") {
                    self?.statusMessage = line
                }
            }
            log.info("[bootstrap] SteamCMD warm-up complete ✓")

            // Kill any lingering Wine processes from the SteamCMD PTY session.
            // The `script -q /dev/null` wrapper leaves the wine64/wineserver alive
            // after steamcmd.exe exits, causing an orphaned Wine CMD window to
            // appear in the library. Killing here is safe — warmUp is the last
            // Wine operation before bootstrap completes.
            steamManager.killAll(engine: engine, prefix: prefix)
            try? await Task.sleep(for: .seconds(1))
        } else {
            log.info("[bootstrap] skipping SteamCMD setup (username=\(steamCMDUsername.isEmpty ? "empty" : "set"), steamcmd=\(FileManager.default.fileExists(atPath: steamcmdPath)))")
        }

        lastFailedPhase = nil
        transition(to: .ready, message: "Ready")
        let totalSec = String(format: "%.1f", Double((ContinuousClock.now - pipelineStart).components.seconds))
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP COMPLETE (\(totalSec)s total)")
        log.info("╚══════════════════════════════════════════════════")
    }

    // MARK: - Helpers

    private func transition(to newPhase: Phase, message: String) {
        phase = newPhase
        statusMessage = message
        log.info("[bootstrap] phase=\(String(describing: newPhase)) | \(message)")
    }

    private func fail(_ message: String) {
        lastFailedPhase = phase
        let failedIn = String(describing: lastFailedPhase!)
        phase = .failed(message)
        statusMessage = message
        log.error("[bootstrap] FAILED in \(failedIn): \(message)")
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }
}
