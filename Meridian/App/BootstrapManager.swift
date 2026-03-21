import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "BootstrapManager")

/// Orchestrates the full app initialization pipeline at launch.
///
/// Runs each phase in order, skipping steps that are already complete
/// (prefix exists, Steam installed, etc.). The final phase starts a
/// persistent Steam process so game launches are near-instant via IPC.
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
        case creatingPrefix
        case installingSteam
        case bootstrappingSteam
        case syncingSession
        case startingSteam
        case waitingForSteam
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

    // MARK: - Public API

    func start(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge
    ) {
        guard phase == .idle || isFailed else { return }

        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runPipeline(
                engine: engine,
                steamManager: steamManager,
                sessionBridge: sessionBridge
            )
        }
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
        sessionBridge: SteamSessionBridge
    ) {
        let cleanupPhases: [Phase] = [.creatingPrefix, .installingSteam, .bootstrappingSteam, .startingSteam, .waitingForSteam]
        if let failed = lastFailedPhase, cleanupPhases.contains(failed) {
            log.info("[retry] previous failure in \(String(describing: failed)) — killing Wine and wiping entire prefix for clean start")
            steamManager.killAll(engine: engine, prefix: prefix)
            prefix.reset()
        }
        lastFailedPhase = nil
        phase = .idle
        statusMessage = ""
        start(engine: engine, steamManager: steamManager, sessionBridge: sessionBridge)
    }

    // MARK: - Pipeline

    private let prefix = WinePrefix.defaultPrefix

    private func runPipeline(
        engine: WineEngine,
        steamManager: WineSteamManager,
        sessionBridge: SteamSessionBridge
    ) async {
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP PIPELINE START")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(self.prefix.exists)")
        log.info("║ steam installed=\(self.prefix.isSteamInstalled)")
        log.info("║ needs bootstrap=\(steamManager.needsBootstrap(prefix: self.prefix))")
        log.info("╚══════════════════════════════════════════════════")

        // 1. Detect engine
        transition(to: .detectingEngine, message: "Detecting Wine engine…")

        guard engine.isReady else {
            fail("Wine engine not installed. Open Settings to download it.")
            return
        }
        log.info("[bootstrap] engine OK — \(engine.backendName)")

        // Populate TerminationCleanup context as soon as we have the engine and prefix.
        // This ensures wineserver -k works even if the user quits during bootstrap
        // before startPersistent has a chance to set it.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false)
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

        // Engage all suppression layers NOW, before any Wine process is launched.
        // The 0.5s polling timer will catch the bootstrap Wine process within its first tick.
        windowSuppressor?.beginSession()

        guard !Task.isCancelled else { return }

        // 2. Create prefix if needed
        if !prefix.exists {
            transition(to: .creatingPrefix, message: "Creating Wine environment…")
            do {
                try await prefix.create(engine: engine)
                log.info("[bootstrap] prefix created")
            } catch {
                fail("Failed to create Wine environment: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 3. Install Steam if needed
        if !prefix.isSteamInstalled {
            transition(to: .installingSteam, message: "Downloading and installing Steam…")
            do {
                try await prefix.installSteam(engine: engine)
                log.info("[bootstrap] Steam installed")
            } catch {
                fail("Failed to install Steam: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 4. Bootstrap Steam (first-run client download) if needed
        if steamManager.needsBootstrap(prefix: prefix) {
            transition(to: .bootstrappingSteam, message: "Steam is updating — first launch takes a few minutes…")
            do {
                try await steamManager.bootstrap(engine: engine, prefix: prefix)
                log.info("[bootstrap] Steam client bootstrapped")
            } catch {
                fail("Steam update failed: \(error.localizedDescription)")
                return
            }
        }

        guard !Task.isCancelled else { return }

        // 5. Sync macOS Steam session for auto-login
        transition(to: .syncingSession, message: "Syncing Steam session…")
        let strategy = await sessionBridge.prepare(prefix: prefix)
        switch strategy {
        case .sessionFileCopy:
            log.info("[bootstrap] session files copied for auto-login")
        case .none:
            log.info("[bootstrap] no macOS Steam session — manual login may be needed")
        }

        guard !Task.isCancelled else { return }

        // 6. Start persistent Steam process
        transition(to: .startingSteam, message: "Starting Steam…")
        do {
            try await steamManager.startPersistent(engine: engine, prefix: prefix)
            log.info("[bootstrap] persistent Steam process launched")
        } catch {
            fail("Failed to start Steam: \(error.localizedDescription)")
            return
        }

        // Engage window suppression immediately after Steam starts.
        // beginSession() was already called earlier (before bootstrap phases), so the
        // polling timer is already running. resumeSuppressing gives an immediate focus
        // on the new persistent Steam PID.
        if let pid = steamManager.persistentProcessIdentifier {
            windowSuppressor?.resumeSuppressing(pid: pid)
        }

        // Wire up the health monitor callback so automatic Steam restarts re-engage
        // suppression with the new process PID.
        steamManager.onSteamRevived = { [weak self, weak steamManager] in
            guard let pid = steamManager?.persistentProcessIdentifier else { return }
            self?.windowSuppressor?.resumeSuppressing(pid: pid)
            log.info("[bootstrap] suppressor re-engaged after Steam revival (pid=\(pid))")
        }

        guard !Task.isCancelled else { return }

        // 7. Wait for Steam to be fully ready (including any post-boot self-update).
        transition(to: .waitingForSteam, message: "Waiting for Steam to initialize…")
        do {
            try await steamManager.waitUntilReady(prefix: prefix) { [weak self] message in
                // Called back when waitUntilReady detects a Steam self-update in progress.
                // Update the splash status message so the user knows what's happening.
                self?.statusMessage = message
                log.info("[bootstrap] waitUntilReady status: \(message)")
            }
            log.info("[bootstrap] Steam is ready ✓")
        } catch {
            fail("Steam failed to start: \(error.localizedDescription)")
            return
        }

        lastFailedPhase = nil
        transition(to: .ready, message: "Ready")
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP COMPLETE — Steam is running")
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
