import Foundation
import Observation

private let log = MeridianLog(category: "BootstrapManager")

/// Orchestrates the app initialization pipeline at launch.
///
/// Bootstrap handles ONLY engine + prefix setup: engine download/detect,
/// prefix creation / engine-upgrade reset, core Wine services, and the
/// general one-time registry setup (WinRT classes, WoW64 crypto provider
/// types, Windows version) that EVERY game needs — including DRM-free games.
///
/// As of Phase 3 (HANDOFF-2026-06-19) bootstrap does NOT install the Steam
/// client, inject local.vdf, or start `steam.exe`. Steam is LAZY and
/// DRM-ONLY: `SteamSession.ensureReadyForDRM` brings the full Steam runtime
/// online on demand the first time a DRM game (`steam_api64.dll`) is
/// launched. A DRM-free-only user never downloads the ~336 MB Steam client
/// nor runs steam.exe — so the Steam "Who's playing" account-picker window
/// never surfaces, and there is no silent-auth wait on every cold start.
///
/// INVARIANT: bootstrap NEVER starts steam.exe and NEVER sends `-login`.
/// `-login USER PASS` triggers an unsolicited 2FA push; credential-based
/// login only happens in the sign-in sheet (SetupSheet → AuthView) where
/// the user is engaged.
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
    private(set) var statusMessage: String = ""
    var isReady: Bool { phase == .ready }

    private var bootstrapTask: Task<Void, Never>?
    private var lastFailedPhase: Phase?
    private(set) var permissionSkipped: Bool = false

    /// Set by MeridianApp so the pipeline can tell SteamWindow to engage
    /// after prefix operations complete.
    var steamWindow: SteamWindow?

    private(set) var engineDownloadState: EngineDownloader.DownloadState = .idle

    // MARK: - Public API

    func start(
        engine: WineEngine,
        session: SteamSession,
        engineDownloader: EngineDownloader
    ) {
        guard phase == .idle || isFailed else { return }
        bootstrapTask?.cancel()
        bootstrapTask = Task { [weak self] in
            await self?.runPipeline(engine: engine, session: session, engineDownloader: engineDownloader)
        }
    }

    func cancelForTermination() {
        bootstrapTask?.cancel()
        bootstrapTask = nil
        log.info("[bootstrap] pipeline cancelled for termination")
    }

    func skipPermissionRequirement() {
        permissionSkipped = true
    }

    func retry(
        engine: WineEngine,
        session: SteamSession,
        engineDownloader: EngineDownloader
    ) {
        let cleanupPhases: [Phase] = [.creatingPrefix, .installingSteam, .bootstrappingSteam, .startingSteam]
        if let failed = lastFailedPhase, cleanupPhases.contains(failed) {
            log.info("[retry] wiping prefix for clean retry")
            session.killAllWineProcesses(engine: engine)
            prefix.reset()
        }
        lastFailedPhase = nil
        phase = .idle
        statusMessage = ""
        engineDownloadState = .idle
        start(engine: engine, session: session, engineDownloader: engineDownloader)
    }

    // MARK: - Pipeline

    private let prefix = WinePrefix.defaultPrefix
    private let settings = AppSettings.shared

    private func runPipeline(
        engine: WineEngine,
        session: SteamSession,
        engineDownloader: EngineDownloader
    ) async {
        let pipelineStart = ContinuousClock.now

        // Set TerminationCleanup context early from static paths.
        if engine.isReady, TerminationCleanup.context == nil {
            let engineDir = WineEngine.engineDir
            TerminationCleanup.context = TerminationCleanup.Context(
                wineserverPath: engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false),
                winePrefix: prefix.path.path(percentEncoded: false),
                engineDirPath: engineDir.path(percentEncoded: false),
                libraryPath: engineDir.appending(path: "wine/lib").path(percentEncoded: false)
            )
        }

        // Kill orphaned Wine processes from a previous unclean session.
        await Task.detached(priority: .userInitiated) {
            TerminationCleanup.killAllWineProcesses()
        }.value

        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP PIPELINE START")
        log.info("║ engine ready=\(engine.isReady)")
        log.info("║ prefix exists=\(prefix.exists)")
        log.info("║ steam installed=\(prefix.isSteamInstalled)")
        log.info("║ steam bootstrapped=\(prefix.isSteamBootstrapped)")
        log.info("╚══════════════════════════════════════════════════")

        // 1. Detect engine — auto-download if absent, auto-UPDATE if a newer
        //    engine release is published.
        transition(to: .detectingEngine, message: "Detecting Wine engine…")
        if !engine.isReady {
            transition(to: .downloadingEngine, message: "Downloading Wine engine…")
            engineDownloadState = .fetching
            engineDownloader.download {}
            pollLoop: while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let current = engineDownloader.state
                engineDownloadState = current
                switch current {
                case .complete:  break pollLoop
                case .failed(let msg): fail("Engine download failed: \(msg)"); return
                default:         continue
                }
            }
            engine.detect()
            guard engine.isReady else {
                let detail: String
                if case .error(let msg) = engine.state { detail = msg }
                else { detail = "Engine could not be verified after download." }
                fail(detail); return
            }
        } else {
            // 1a. Engine auto-update. Engine-only releases (vX.Y.Z-engine) never
            // bump the app version, so without this check users stay on an old
            // engine until they manually visit Settings → Updates. Running the
            // update HERE is race-free: it happens before any Wine process is
            // started this session (orphan cleanup above), so replacing the
            // engine directory cannot delete a live wine64 — the hazard
            // EngineDownloader's same-tag short-circuit exists for. When the
            // installed tag already matches GitHub's latest, download() is a
            // ~single-API-call no-op.
            //
            // Fail-OPEN: any check/download failure keeps the installed engine
            // and the launch proceeds — an offline user must never be blocked
            // by a GitHub fetch.
            transition(to: .detectingEngine, message: "Checking for engine updates…")
            engineDownloader.download {}
            updateLoop: while true {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                let current = engineDownloader.state
                switch current {
                case .complete:
                    break updateLoop
                case .failed(let msg):
                    log.warning("[bootstrap] engine update check failed — continuing with installed engine: \(msg)")
                    break updateLoop
                case .downloading, .extracting:
                    if phase != .downloadingEngine {
                        transition(to: .downloadingEngine, message: "Updating Wine engine…")
                    }
                    engineDownloadState = current
                default:
                    continue
                }
            }
            // Re-detect unconditionally: on success the version/paths must
            // reflect the freshly-extracted engine; on a mid-extraction
            // failure the engine dir may be gone and the cached isReady would
            // lie — detect() surfaces that as a real failure instead.
            engine.detect()
            guard engine.isReady else {
                let detail: String
                if case .error(let msg) = engine.state { detail = msg }
                else { detail = "Engine could not be verified after update." }
                fail(detail); return
            }
        }
        log.info("[bootstrap] engine OK — \(engine.backendName) \(engine.engineVersion ?? "unknown")")

        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )

        if settings.quarantineCleanedVersion < Self.quarantineCleanedCurrentVersion {
            await Self.stripEngineQuarantine()
            settings.quarantineCleanedVersion = Self.quarantineCleanedCurrentVersion
        }

        guard !Task.isCancelled else { return }

        // 1b. Permission gate.
        if !(steamWindow?.isPermissionGranted ?? false) && !permissionSkipped {
            transition(to: .awaitingPermission, message: "Accessibility permission required…")
            while !(steamWindow?.isPermissionGranted ?? false) && !permissionSkipped {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                steamWindow?.refreshPermission()
            }
        }

        guard !Task.isCancelled else { return }

        // 2. Create prefix if needed.
        if !prefix.exists {
            transition(to: .creatingPrefix, message: "Creating Wine environment…")
            do {
                try await prefix.create(engine: engine)
            } catch {
                fail("Failed to create Wine environment: \(error.localizedDescription)"); return
            }
            settings.lastPrefixEngineTag = engine.engineVersion ?? ""
            settings.lastPrefixEngineModTime = Self.engineVersionFileModTime()
            // A freshly-created prefix has NONE of the versioned registry
            // mutations (WinRT classes, WoW64 crypto provider types, Windows
            // version, steamservice cleanup). The version counters live in
            // global UserDefaults, NOT tied to prefix identity, so a prefix
            // recreated after a manual `bottles/` wipe inherits the old
            // "already applied" counters and the step-3 block below would SKIP
            // all of it — leaving the new prefix without the WoW64 crypto keys
            // and re-breaking 32-bit games (Pattern 11 / HL2). Zero the
            // counters so step 3 re-applies the full registry setup. (The
            // engine-reset path does the same — see 2b.)
            resetVersionedRegistryCounters()
        }

        guard !Task.isCancelled else { return }

        // 2b. Handle engine upgrades.
        let storedTag = settings.lastPrefixEngineTag
        let currentTag = engine.engineVersion ?? ""
        let currentEngineModTime = Self.engineVersionFileModTime()
        let needsUpdate = prefix.exists && !currentTag.isEmpty
            && (storedTag != currentTag || currentEngineModTime != settings.lastPrefixEngineModTime)
        if needsUpdate {
            log.info("[bootstrap] engine changed \(storedTag.isEmpty ? "(unknown)" : storedTag) → \(currentTag) — resetting prefix")
            transition(to: .creatingPrefix, message: "Applying new Wine engine…")
            do {
                try await prefix.resetToEngineTemplate(engine: engine)
                session.killAllWineProcesses(engine: engine)
                try? await Task.sleep(for: .seconds(1))
                settings.lastPrefixEngineTag = currentTag
                settings.lastPrefixEngineModTime = currentEngineModTime
                // resetToEngineTemplate copies a fresh system.reg from the
                // template (Pattern 10), so EVERY versioned registry mutation
                // is gone and must be re-applied. Previously only 2 of the 4
                // counters were reset here, leaving windowsVersion +
                // staleSteamService stale after an engine upgrade. Zero all of
                // them; step 3 below re-applies everything (incl. WinRT, so the
                // explicit registerWinRTClasses call here is no longer needed).
                resetVersionedRegistryCounters()
            } catch {
                log.error("[bootstrap] prefix reset failed (non-fatal): \(error.localizedDescription)")
            }
        } else {
            log.info("[bootstrap] engine tag unchanged (\(currentTag)) — no prefix update needed")
        }

        guard !Task.isCancelled else { return }

        // 2c. Ensure core Wine services.
        await prefix.ensureCoreServices(engine: engine)

        // 3. One-time prefix REGISTRY setup. These are GENERAL prefix
        //    requirements needed by ALL games — they are NOT Steam-runtime
        //    setup and do NOT require Steam to be installed or running:
        //      • WinRT classes — Unity 6.3+ games (DispatcherQueue); DRM-free too
        //      • WoW64 crypto provider types — any 32-bit game calling
        //        CryptAcquireContextA (Pattern 11); DRM-free too
        //      • Windows 10 version — general compatibility
        //      • stale steamservice registration cleanup — harmless registry tidy
        //    `ensureDefaultLibrary` establishes `steamapps/` so headless
        //    DepotDownloader installs + their `StateFlags=4` manifests have a
        //    home — again, no steam.exe required.
        //
        //    Steam itself — the stub install, the ~336 MB client download,
        //    local.vdf injection, and `steam.exe -silent` — is NOT touched here.
        //    It is now LAZY and DRM-ONLY: `SteamSession.ensureReadyForDRM`
        //    brings the Steam runtime online on demand the first time a DRM
        //    game (`steam_api64.dll`) is launched. A DRM-free-only user
        //    therefore never downloads the Steam client nor runs steam.exe —
        //    no "Who's playing" window and no silent-auth wait on every cold
        //    start (Phase 3, HANDOFF-2026-06-19).
        try? prefix.ensureDefaultLibrary()

        if settings.winRTRegistrationAppliedVersion < WinePrefix.winRTRegistrationVersion {
            await prefix.registerWinRTClasses(engine: engine)
            settings.winRTRegistrationAppliedVersion = WinePrefix.winRTRegistrationVersion
        }
        if settings.steamInstallPathRegistrationVersion < WinePrefix.steamInstallPathRegistrationVersion {
            await prefix.writeSteamInstallPathRegistryKeys(engine: engine)
            settings.steamInstallPathRegistrationVersion = WinePrefix.steamInstallPathRegistrationVersion
        }
        if settings.windowsVersionAppliedVersion < WinePrefix.windowsVersionRegistrationVersion {
            await prefix.setWindowsVersionToWin10(engine: engine)
            settings.windowsVersionAppliedVersion = WinePrefix.windowsVersionRegistrationVersion
        }
        if settings.staleSteamServiceCleanupVersion < WinePrefix.staleSteamServiceCleanupVersion {
            await prefix.removeStaleSteamServiceRegistration(engine: engine)
            settings.staleSteamServiceCleanupVersion = WinePrefix.staleSteamServiceCleanupVersion
        }
        // 32-bit (WoW64) COM classes — audio (MMDeviceEnumerator → no sound),
        // DirectInput8, WBEM. The prefix template ships the 32-bit CLSID view
        // EMPTY (Pattern 7's killed wineboot), so 32-bit games (HL2/Source/DX9)
        // get REGDB_E_CLASSNOTREG. DRM-free + 64-bit games unaffected.
        if settings.wow64ComRegistrationAppliedVersion < WinePrefix.wow64ComRegistrationVersion {
            await prefix.registerWoW64ComClasses(engine: engine)
            settings.wow64ComRegistrationAppliedVersion = WinePrefix.wow64ComRegistrationVersion
        }

        guard !Task.isCancelled else { return }

        lastFailedPhase = nil
        transition(to: .ready, message: "Ready")
        let totalSec = String(format: "%.1f", Double((ContinuousClock.now - pipelineStart).components.seconds))
        log.info("╔══════════════════════════════════════════════════")
        log.info("║ BOOTSTRAP COMPLETE (\(totalSec)s total)")
        log.info("╚══════════════════════════════════════════════════")
    }

    // MARK: - Helpers

    private static let quarantineCleanedCurrentVersion = 1

    private static func stripEngineQuarantine() async {
        await Task.detached(priority: .userInitiated) {
            let enginePath = WineEngine.engineDir.path(percentEncoded: false)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/xattr")
            process.arguments = ["-rd", "com.apple.quarantine", enginePath]
            process.standardOutput = FileHandle.nullDevice
            process.standardError  = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            log.info("[bootstrap] quarantine stripped from engine")
        }.value
    }

    /// Zeros every versioned prefix-registry counter so the step-3 setup block
    /// re-applies the full registry state (WinRT classes, WoW64 crypto provider
    /// types, Windows version, stale steamservice cleanup) to a freshly
    /// created OR engine-reset prefix.
    ///
    /// These counters track "applied to the current prefix" but persist in
    /// global UserDefaults, decoupled from prefix identity. Whenever the prefix
    /// is (re)built — `prefix.create()` on a fresh/wiped bottle, or
    /// `resetToEngineTemplate()` on an engine change (which copies a fresh
    /// system.reg per Pattern 10) — the on-disk registry is empty but the
    /// counters still read "already applied", causing step 3 to skip the
    /// writes. That left 32-bit games (HL2) without the WoW64 crypto provider
    /// types and crashing in `CryptAcquireContextA` (Pattern 11). Resetting all
    /// of them on every (re)build keeps the registry and the counters in sync.
    private func resetVersionedRegistryCounters() {
        settings.winRTRegistrationAppliedVersion = 0
        settings.steamInstallPathRegistrationVersion = 0
        settings.windowsVersionAppliedVersion = 0
        settings.staleSteamServiceCleanupVersion = 0
        settings.wow64ComRegistrationAppliedVersion = 0
    }

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
