import Foundation
import Observation

private let log = MeridianLog(category: "BootstrapManager")

/// Orchestrates the full app initialization pipeline at launch.
///
/// Steps 1–6 handle engine, prefix, and Steam installation (all one-time setup).
/// Step 7 starts steam.exe -silent so it is running when the library opens.
///
///   • Returning user with valid on-disk session (ssfn or loginusers.vdf):
///     `-silent` → Steam authenticates from its own on-disk state → ~5-10 s
///   • Session expired or absent:
///     `-silent` fails fast (12 s) → sign-in sheet handles recovery
///
/// INVARIANT: bootstrap NEVER sends `-login USER PASS`. That triggers an
/// unsolicited 2FA push. Credential-based login only happens in the sign-in
/// sheet (SetupSheet → SteamSession.signIn) where the user is engaged.
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

        // 1. Detect engine — auto-download if absent.
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
        }
        log.info("[bootstrap] engine OK — \(engine.backendName)")

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
            await prefix.registerWinRTClasses(engine: engine)
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
                settings.steamInstallPathRegistrationVersion = 0
                settings.winRTRegistrationAppliedVersion = 0
                await prefix.registerWinRTClasses(engine: engine)
            } catch {
                log.error("[bootstrap] prefix reset failed (non-fatal): \(error.localizedDescription)")
            }
        } else {
            log.info("[bootstrap] engine tag unchanged (\(currentTag)) — no prefix update needed")
        }

        guard !Task.isCancelled else { return }

        // 2c. Ensure core Wine services.
        await prefix.ensureCoreServices(engine: engine)

        // 3. Install Steam stub if needed.
        if !prefix.isSteamInstalled {
            transition(to: .installingSteam, message: "Downloading and installing Steam…")
            do {
                try await prefix.installSteam(engine: engine)
            } catch {
                fail("Failed to install Steam: \(error.localizedDescription)"); return
            }
        }

        guard !Task.isCancelled else { return }

        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()
        log.info("[bootstrap] steam.cfg and libraryfolders.vdf written")

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
        if prefix.refreshSteamStubFromEngineIfStale() {
            log.info("[bootstrap] steam.exe stub refreshed from engine bundle ✓")
        }
        if settings.staleSteamServiceCleanupVersion < WinePrefix.staleSteamServiceCleanupVersion {
            await prefix.removeStaleSteamServiceRegistration(engine: engine)
            settings.staleSteamServiceCleanupVersion = WinePrefix.staleSteamServiceCleanupVersion
        }

        // 4. Bootstrap the full Steam client if steamui.dll is absent.
        // Runs steam.exe -silent which downloads and installs its own client files.
        // ONLY needed on first launch or after a full prefix reset.
        if !prefix.isSteamBootstrapped {
            transition(to: .bootstrappingSteam, message: "Downloading Steam client…")
            steamWindow?.startSuppressing()
            do {
                try await bootstrapSteamClient(engine: engine) { [weak self] downloaded, total in
                    Task { @MainActor in
                        guard let self else { return }
                        let pct = total > 0 ? Int(downloaded * 100 / total) : 0
                        let mb = downloaded / 1_048_576
                        let totalMB = total / 1_048_576
                        self.statusMessage = "Downloading Steam client… \(mb)/\(totalMB) MB (\(pct)%)"
                    }
                }
            } catch {
                fail("Steam bootstrap failed: \(error.localizedDescription)"); return
            }
        }

        guard !Task.isCancelled else { return }

        try? prefix.ensureSteamCFG()
        try? prefix.ensureDefaultLibrary()

        // 5. Check whether a valid Steam session exists.
        //    A session can come from any of:
        //      • ssfn device-trust token on disk (legacy)
        //      • loginusers.vdf with valid AllowAutoLogin entry (post-Steam-UI sign-in)
        //      • persisted IAuthenticationService refresh_token in AppSettings
        //        (Meridian OAuth) — this is the canonical path. Even with no
        //        on-disk state in the prefix, hasSteamCredentials means we can
        //        DPAPI-inject local.vdf from the refresh_token and Steam will
        //        silently auto-log-in.
        transition(to: .syncingSession, message: "Checking Steam session…")
        let hasSsfn         = prefix.hasSsfnToken
        let hasLoginVdf     = prefix.hasSteamLoginSession()
        let hasCredentials  = AppSettings.shared.hasSteamCredentials
        let hasLogin        = hasSsfn || hasLoginVdf || hasCredentials
        log.info("[bootstrap] Steam session check: hasSsfn=\(hasSsfn) hasLoginVdf=\(hasLoginVdf) hasCredentials=\(hasCredentials) → hasLogin=\(hasLogin)")

        guard !Task.isCancelled else { return }

        // 6. Engage window suppression now that all prefix operations are complete.
        steamWindow?.startSuppressing()

        // 7. Ensure local.vdf is present and usable.
        //    First try the on-disk backup (covers prefix-reset survival). Then,
        //    if we have a persisted refresh_token, ALWAYS re-DPAPI-inject from
        //    AppSettings — this makes local.vdf reproducible from purely Meridian-
        //    owned state, so engine upgrades (new Wine crypt32 secret), prefix
        //    resets, backup loss, etc. all self-heal without re-prompting the user.
        SteamSessionBackup.restoreIfNeeded(prefix: prefix)

        if hasCredentials {
            do {
                let settings = AppSettings.shared
                try await prefix.writeSteamSessionLocalVdf(
                    engine: engine,
                    steamID: settings.steamCredentialSteamID,
                    accountName: settings.steamCredentialAccountName,
                    refreshToken: settings.steamCredentialRefreshToken
                )
                log.info("[bootstrap] local.vdf re-injected from persisted credentials ✓")
            } catch {
                log.warning("[bootstrap] local.vdf re-inject failed: \(error.localizedDescription) — falling back to on-disk state")
            }
        }

        // 8. Start steam.exe -silent. NEVER -login from here.
        //    Returns fast: ~5-10 s on success, 12 s on auth failure.
        //    If auth fails → session.state = .failed → ContentView shows sign-in sheet.
        if hasLogin {
            transition(to: .startingSteam, message: "Starting Steam…")
            await session.start(engine: engine)
            if session.isReady {
                log.info("[bootstrap] steam.exe authenticated silently ✓")
            } else {
                log.warning("[bootstrap] silent auth failed — sign-in sheet will handle re-auth")
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

    // MARK: - Steam client self-bootstrap

    /// Runs steam.exe -silent to download the full Steam client (steamui.dll).
    /// Only called when isSteamBootstrapped is false (first launch / full wipe).
    /// Steam exits code=42 to restart itself during the process — that's normal.
    private func bootstrapSteamClient(
        engine: WineEngine,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        guard !FileManager.default.fileExists(atPath: dllPath) else {
            log.info("[bootstrap:steam] steamui.dll already present — skipping")
            return
        }

        try? prefix.ensureSteamCFG()
        prefix.stripBootStrapperInhibit()
        prefix.clearCrashMarker()

        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let bootstrapLogPath = prefix.steamInstallDir
            .appending(path: "logs/bootstrap_log.txt")
            .path(percentEncoded: false)
        let logStartOffset = (try? FileManager.default.attributesOfItem(atPath: bootstrapLogPath)[.size] as? Int) ?? 0

        log.info("[bootstrap:steam] launching wine64 steam.exe -silent")
        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamExe, "-silent"]
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()

        try process.run()
        let pid = process.processIdentifier
        log.info("[bootstrap:steam] pid=\(pid)")
        steamWindow?.registerPID(pid_t(pid))

        // Watch bootstrap_log.txt for progress and steamui.dll for completion.
        let maxDuration: Duration = .seconds(900)
        let stuckWindow: Duration = .seconds(90)
        let started = ContinuousClock.now
        var lastLogSize = logStartOffset
        var lastGrowthAt = ContinuousClock.now
        var sawAnyProgress = false

        while ContinuousClock.now - started < maxDuration {
            guard !Task.isCancelled else {
                process.terminate()
                throw BootstrapError.cancelled
            }
            try? await Task.sleep(for: .milliseconds(500))

            if FileManager.default.fileExists(atPath: dllPath) {
                log.info("[bootstrap:steam] steamui.dll present ✓")
                try? await Task.sleep(for: .seconds(2))
                let stillAlive = process.isRunning
                log.info("[bootstrap:steam] process still alive=\(stillAlive) (code-42 restart expected)")
                if stillAlive { process.terminate() }
                return
            }

            // Parse bootstrap_log.txt progress.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: bootstrapLogPath),
               let size = attrs[.size] as? Int, size > lastLogSize {
                if let fh = try? FileHandle(forReadingFrom: URL(filePath: bootstrapLogPath)) {
                    try? fh.seek(toOffset: UInt64(lastLogSize))
                    let data = (try? fh.readToEnd()) ?? Data()
                    try? fh.close()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    lastLogSize = size
                    lastGrowthAt = ContinuousClock.now
                    sawAnyProgress = true

                    // Parse "Downloading update (X of Y KB)..."
                    for line in text.components(separatedBy: .newlines) {
                        if line.contains("Downloading update") {
                            let numbers = line.components(separatedBy: .whitespaces)
                                .compactMap { Int64($0.replacingOccurrences(of: ",", with: "")) }
                            if numbers.count >= 2 {
                                progress?(numbers[0] * 1024, numbers[1] * 1024)
                            }
                        }
                    }
                }
            }

            if sawAnyProgress, ContinuousClock.now - lastGrowthAt > stuckWindow {
                log.error("[bootstrap:steam] stuck — log not growing for \(stuckWindow)")
                process.terminate()
                throw BootstrapError.stuck
            }

            if !process.isRunning {
                let code = process.terminationStatus
                if code == 42 {
                    // Steam self-update restart — wait for the new process.
                    log.info("[bootstrap:steam] code=42 self-update restart — continuing")
                    try? await Task.sleep(for: .seconds(3))
                } else if FileManager.default.fileExists(atPath: dllPath) {
                    return
                } else {
                    log.error("[bootstrap:steam] steam.exe exited code=\(code) before steamui.dll appeared")
                    throw BootstrapError.steamExited(code)
                }
            }
        }

        process.terminate()
        throw BootstrapError.timeout
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

// MARK: - Errors

enum BootstrapError: LocalizedError {
    case cancelled
    case stuck
    case steamExited(Int32)
    case timeout

    var errorDescription: String? {
        switch self {
        case .cancelled:          return "Bootstrap was cancelled."
        case .stuck:              return "Steam client download stalled. Check internet connection."
        case .steamExited(let c): return "Steam exited unexpectedly during bootstrap (code \(c))."
        case .timeout:            return "Steam client download timed out."
        }
    }
}
