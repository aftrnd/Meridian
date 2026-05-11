import Foundation
import Observation

private let log = MeridianLog(category: "BootstrapManager")

/// Orchestrates the full app initialization pipeline at launch.
///
/// Runs each phase in order, skipping steps that are already complete
/// (prefix exists, Steam installed, etc.). Step 7 starts steam.exe -silent
/// so it is running before the library opens:
///
///   • Returning user with valid on-disk session:
///     `-silent` → Steam authenticates from its own ssfn/local.vdf → ~5-10 s
///   • Session expired / no session:
///     `-silent` fails fast (12 s) → sign-in sheet handles recovery
///
/// NEVER sends `-login USER PASS` from bootstrap. That triggers a 2FA push
/// the user didn't ask for. Credential-based login only happens in the sign-in
/// sheet (SteamExeSignIn) where the user is actively engaged.
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
        engineDownloader: EngineDownloader
    ) {
        guard phase == .idle || isFailed else { return }

        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runPipeline(
                engine: engine,
                steamManager: steamManager,
                engineDownloader: engineDownloader
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
        engineDownloader: EngineDownloader
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
        start(engine: engine, steamManager: steamManager, engineDownloader: engineDownloader)
    }

    // MARK: - Pipeline

    private let prefix = WinePrefix.defaultPrefix
    private let settings = AppSettings.shared

    private func runPipeline(
        engine: WineEngine,
        steamManager: WineSteamManager,
        engineDownloader: EngineDownloader
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

        // One-time quarantine cleanup for engines downloaded before EngineDownloader
        // started stripping quarantine automatically. Must run before any Wine process
        // is launched — quarantined Wine binaries have restricted network access on
        // macOS 26, causing Wine's TLS/secur32 to fail silently and SteamCMD to hang.
        if settings.quarantineCleanedVersion < Self.quarantineCleanedCurrentVersion {
            await Self.stripEngineQuarantine()
            settings.quarantineCleanedVersion = Self.quarantineCleanedCurrentVersion
        }

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
            // Record the engine tag and content fingerprint used to create this prefix
            // so we can detect future engine upgrades or same-tag republishes.
            settings.lastPrefixEngineTag = engine.engineVersion ?? ""
            settings.lastPrefixEngineModTime = Self.engineVersionFileModTime()

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
        let currentEngineModTime = Self.engineVersionFileModTime()
        let needsUpdate = prefix.exists && !currentTag.isEmpty
            && (storedTag != currentTag || currentEngineModTime != settings.lastPrefixEngineModTime)
        if needsUpdate {
            if storedTag != currentTag {
                log.info("[bootstrap] engine changed \(storedTag.isEmpty ? "(unknown)" : storedTag) → \(currentTag) — resetting prefix to new engine template")
            } else {
                log.info("[bootstrap] engine content changed (same tag \(currentTag), mtime \(settings.lastPrefixEngineModTime) → \(currentEngineModTime)) — resetting prefix to new engine template")
            }
            transition(to: .creatingPrefix, message: "Applying new Wine engine…")
            let t = ContinuousClock.now
            do {
                try await prefix.resetToEngineTemplate(engine: engine)
                // Kill Wine processes started by wineboot (wineserver, winedevice, etc.)
                // before the registration step so it starts a clean new session.
                steamManager.killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(1))
                settings.lastPrefixEngineTag = currentTag
                settings.lastPrefixEngineModTime = currentEngineModTime
                // Reset versioned setup counters so they re-run against the new prefix.
                // system.reg is wiped by resetToEngineTemplate, so registry keys that
                // were previously written (WoW64 crypto providers, Steam install paths,
                // WinRT classes) must be re-applied even if their version counters are
                // already at the current value.
                settings.steamInstallPathRegistrationVersion = 0
                settings.winRTRegistrationAppliedVersion = 0
                log.info("[bootstrap] prefix reset to new engine template in \(String(format: "%.1f", Double((ContinuousClock.now - t).components.seconds)))s")
                await prefix.registerWinRTClasses(engine: engine)
            } catch {
                log.error("[bootstrap] prefix reset failed (non-fatal): \(error.localizedDescription) — continuing with existing prefix")
            }
        } else {
            log.info("[bootstrap] engine tag unchanged (\(currentTag)) — no prefix update needed")
        }

        guard !Task.isCancelled else { return }

        // 2c. Ensure Wine's core services are registered: nsiproxy, RpcSs,
        //     EventLog, PlugPlay. Without nsiproxy, `\\.\Nsi` is never
        //     created → `iphlpapi::GetAdaptersAddresses` returns
        //     ERROR_FILE_NOT_FOUND → Steam's `CalcUnIPThisBox` asserts and
        //     the main↔webhelper websocket fails → steam.exe enters an
        //     assert/auto-restart loop showing the macOS "wine64 unexpected
        //     error" dialog. Without RpcSs, OLE class registration fails
        //     and some Steam IPC paths break. Our prefix template ships
        //     without these services because `release-engine.sh`'s
        //     `wineboot --init` step is killed by its 180 s timeout
        //     (rundll32 setupapi InstallHinfSection runaway recursion on
        //     macOS hosts, CLI-confirmed April 25 2026). This self-heals
        //     at runtime via `wine64 reg add`, which correctly resolves
        //     the `CurrentControlSet` registry symlink (file-surgery on
        //     `system.reg` would be discarded on the next wineserver
        //     save). Idempotent — fast-paths when all 4 already present.
        await prefix.ensureCoreServices(engine: engine)

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

        // Write Steam HKLM install-path registry keys (once per prefix).
        // steam.exe writes these on first run; our native bootstrap bypasses steam.exe
        // so they are never created. steamcmd.exe (32-bit WoW64) reads
        // HKLM\SOFTWARE\WOW6432Node\Valve\Steam\InstallPath at startup — if absent,
        // it throws a C++ exception before loading any Steam DLLs and exits with code 3.
        if settings.steamInstallPathRegistrationVersion < WinePrefix.steamInstallPathRegistrationVersion {
            log.info("[bootstrap] Steam install path not registered — writing HKLM keys")
            await prefix.writeSteamInstallPathRegistryKeys(engine: engine)
            settings.steamInstallPathRegistrationVersion = WinePrefix.steamInstallPathRegistrationVersion
        }

        // Set the prefix's reported Windows version to win10 (once per prefix).
        // Defence in depth — the real fix for "Steam is no longer supported on
        // your operating system" was a fresh `steam.exe` stub (see the stub
        // refresh below). This reg write covers cases where other Wine-hosted
        // apps query `GetVersionEx` directly.
        if settings.windowsVersionAppliedVersion < WinePrefix.windowsVersionRegistrationVersion {
            log.info("[bootstrap] Windows version not yet set — forcing win10")
            await prefix.setWindowsVersionToWin10(engine: engine)
            settings.windowsVersionAppliedVersion = WinePrefix.windowsVersionRegistrationVersion
        }

        // Replace the `SteamSetup.exe`-installed stub with the engine-bundled
        // one if it's newer. Root cause of "Steam is no longer supported on
        // your operating system" on fresh installs (CLI-verified April 22,
        // 2026): Valve's `cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe`
        // serves a Jan 29 stub whose manifest hard-reports Windows 6.2.9200.0,
        // triggering Steam's deprecation dialog.
        //
        // `release-engine.sh` copies a current stub from CX Preview into the
        // engine tarball at `$ENGINE/wine/share/meridian/steam.exe.stub`; this
        // call overwrites the prefix's stub whenever the engine has a
        // different-size one. Meridian never reads from CX at runtime — per
        // update-system.mdc, CX is a build-time reference only.
        if prefix.refreshSteamStubFromEngineIfStale() {
            log.info("[bootstrap] steam.exe stub refreshed from engine bundle ✓")
        }

        // One-time cleanup: old Meridian sessions running the Jan 29 stub left
        // behind a `Steam Client Service` Windows-service registration whose
        // ImagePath points to the legacy `Program Files (x86)\Common Files\Steam`
        // location that no longer exists under the Mar 12+ install. Steam's
        // `StartService` call fails with GLE 126 (ERROR_MOD_NOT_FOUND) on every
        // launch. Delete the entry — Steam will re-register it with the correct
        // path on demand.
        if settings.staleSteamServiceCleanupVersion < WinePrefix.staleSteamServiceCleanupVersion {
            await prefix.removeStaleSteamServiceRegistration(engine: engine)
            settings.staleSteamServiceCleanupVersion = WinePrefix.staleSteamServiceCleanupVersion
        }

        // 4. Bootstrap Steam (first-run client download) if needed
        if steamManager.needsBootstrap(prefix: prefix) {
            transition(to: .bootstrappingSteam, message: "Downloading Steam client…")
            // Steam's self-bootstrap may render an update/webhelper window while
            // downloading the full client. At this point SteamSetup and prefix
            // operations are complete, so suppression can safely engage before
            // `steam.exe -silent` launches.
            windowSuppressor?.beginSession()
            let t = ContinuousClock.now
            do {
                try await steamManager.bootstrap(engine: engine, prefix: prefix) { [weak self] downloaded, total in
                    Task { @MainActor in
                        guard let self else { return }
                        let pct = total > 0 ? Int(downloaded * 100 / total) : 0
                        let mb = downloaded / 1_048_576
                        let totalMB = total / 1_048_576
                        self.statusMessage = "Downloading Steam client… \(mb)/\(totalMB) MB (\(pct)%)"
                    }
                }
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

        // 5. Check whether a valid Steam session exists on disk.
        //
        // After a successful `steam.exe -login` sign-in (via AuthView → SteamExeSignIn),
        // Steam writes its own ssfn* device-trust token + local.vdf. On every subsequent
        // cold start, `steam.exe -silent` reads the ssfn token and auto-authenticates
        // without 2FA — same mechanism as the Windows Steam desktop client.
        //
        // We consider a session present when EITHER:
        //   • ssfn device-trust token exists (strongest signal — Steam issued it after -login)
        //   • loginusers.vdf has a MostRecent=1 user (written by SteamExeSignIn's onAuthenticated)
        //
        // If neither is present the sign-in sheet will take over at the end of the pipeline.
        transition(to: .syncingSession, message: "Checking Steam session…")
        let hasSsfn     = prefix.hasSsfnToken
        let hasLoginVdf = prefix.hasSteamLoginSession()
        let hasLogin    = hasSsfn || hasLoginVdf
        steamManager.isSteamLoggedIn = hasLogin
        log.info("[bootstrap] Steam session check: hasSsfn=\(hasSsfn) hasLoginVdf=\(hasLoginVdf) → hasLogin=\(hasLogin)")

        guard !Task.isCancelled else { return }

        // 6. Engage window suppression now that all prefix operations are complete.
        windowSuppressor?.beginSession()

        // 7. Start steam.exe -silent. NEVER send -login from bootstrap — that
        //    triggers a 2FA push the user didn't ask for. Only -silent.
        //
        //    Steam authenticates silently using its own on-disk state (ssfn tokens,
        //    local.vdf, ConnectCache). If that state is valid, [Logged On,] appears
        //    in ~5-10 s and the user goes straight to the library. If not, the auth
        //    timeout fires quickly (12 s), isSteamLoggedIn stays false, and the
        //    sign-in sheet handles recovery — that's where the user expects to
        //    interact with credentials and 2FA.
        //
        //    -login USER PASS is ONLY used inside SteamExeSignIn (the sign-in sheet)
        //    where the user is actively engaged and expecting a 2FA prompt.
        if hasLogin {
            transition(to: .startingSteam, message: "Starting Steam…")
            do {
                if !steamManager.isSteamProcessAlive {
                    try await steamManager.startPersistent(engine: engine, prefix: prefix)
                }
                try await steamManager.waitUntilReady(
                    prefix: prefix,
                    timeout: .seconds(60),
                    authTimeout: .seconds(12)
                )
                steamManager.isSteamLoggedIn = true
                if let pid = steamManager.persistentProcessIdentifier {
                    windowSuppressor?.resumeSuppressing(pid: pid)
                }
                log.info("[bootstrap] steam.exe authenticated silently ✓")
            } catch {
                log.warning("[bootstrap] steam.exe silent auth failed: \(error.localizedDescription) — sign-in sheet will handle")
                steamManager.isSteamLoggedIn = false
            }
        } else {
            log.info("[bootstrap] no session on disk — sign-in sheet will handle authentication")
        }

        lastFailedPhase = nil
        transition(to: .ready, message: "Ready")
        let totalSec = String(format: "%.1f", Double((ContinuousClock.now - pipelineStart).components.seconds))
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP COMPLETE (\(totalSec)s total)")
        log.info("╚══════════════════════════════════════════════════")
    }

    // MARK: - Helpers

    /// Version counter for the one-time quarantine cleanup pass.
    /// Increment this when a new cleanup action is needed on existing installations.
    ///
    /// Version history:
    ///   1 — strip com.apple.quarantine from the entire engine directory. Engine files
    ///       downloaded before EngineDownloader started stripping quarantine automatically
    ///       have restricted network access on macOS 26, breaking Wine TLS.
    private static let quarantineCleanedCurrentVersion = 1

    /// Strips `com.apple.quarantine` from the entire engine directory.
    /// Runs off the main actor so it doesn't block the UI during the brief xattr sweep.
    private static func stripEngineQuarantine() async {
        await Task.detached(priority: .userInitiated) {
            let enginePath = WineEngine.engineDir.path(percentEncoded: false)
            log.info("[bootstrap] stripping com.apple.quarantine from engine (one-time cleanup)…")
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xattr")
            process.arguments = ["-rd", "com.apple.quarantine", enginePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError  = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
                log.info("[bootstrap] quarantine stripped from engine ✓")
            } catch {
                log.warning("[bootstrap] xattr quarantine strip failed: \(error.localizedDescription)")
            }
        }.value
    }

    /// Returns the filesystem modification time of `wine/meridian-engine-version.txt`
    /// as a Unix timestamp. This file is written by every `release-engine.sh` run, so
    /// its mtime changes even when the version tag string is unchanged (same-tag republish).
    /// Returns 0.0 if the file does not exist.
    private static func engineVersionFileModTime() -> Double {
        let versionFile = WineEngine.engineDir.appending(path: "wine/meridian-engine-version.txt")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: versionFile.path(percentEncoded: false)),
              let modDate = attrs[.modificationDate] as? Date else { return 0.0 }
        return modDate.timeIntervalSince1970
    }

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
