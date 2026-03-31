import AppKit
import Foundation
import Observation
import os.log

private let log = MeridianLog(category: "WineSteamManager")

/// Manages the Steam client running inside Wine.
///
/// Responsible for:
///   - Bootstrapping Steam on first run (downloading the full client)
///   - Launching games directly via wine64 (bypassing steam.exe -applaunch)
///   - Starting steam.exe on-demand for DRM games (startSteamForDRM)
///   - Stopping Steam / killing Wine processes
///
/// steam.exe is NOT started at app launch. It is started only
/// on-demand when a game ships steam_api64.dll and needs a live Steam IPC socket for DRM.
@Observable
@MainActor
final class WineSteamManager {

    /// Whether a persistent Steam process is currently running.
    /// True only when steam.exe has been started (DRM game launch or showSteamUI).
    var isRunning: Bool = false

    /// Whether the Wine Steam client has an authenticated user session.
    /// Persisted to UserDefaults so the setup sheet doesn't re-appear after
    /// view lifecycle events (game exit, navigation changes).
    var isSteamLoggedIn: Bool = UserDefaults.standard.bool(forKey: "isSteamLoggedIn") {
        didSet { UserDefaults.standard.set(isSteamLoggedIn, forKey: "isSteamLoggedIn") }
    }

    /// The Steam process started on-demand for DRM games or showSteamUI.
    private var persistentProcess: Process?

    /// When the persistent process was last launched.
    private var persistentLaunchDate: Date?

    /// Set by `GameLauncher` while a game is actively running.
    var gameIsRunning: Bool = false

    /// Set by `MeridianApp` so every Wine process launched here can be registered
    /// with the suppressor for immediate window hiding.
    var windowSuppressor: SteamWindowSuppressor?

    // MARK: - Bootstrap

    /// Whether Steam needs its first-run bootstrap.
    ///
    /// `SteamSetup.exe /S` installs only the bootstrapper (~2MB). The full
    /// Steam client (including `steamui.dll`) is downloaded when Steam.exe
    /// runs for the first time.
    func needsBootstrap(prefix: WinePrefix) -> Bool {
        let dllPath = prefix.steamInstallDir.appending(path: "steamui.dll")
        let exists = FileManager.default.fileExists(atPath: dllPath.path(percentEncoded: false))
        log.info("[needsBootstrap] steamui.dll exists=\(exists) at \(dllPath.path(percentEncoded: false))")
        return !exists
    }

    /// Runs Steam non-silently to complete the first-run client download.
    ///
    /// Launches Steam.exe without `-silent` so it can show its update UI
    /// and download the full client (~150MB). Waits for `steamui.dll` to
    /// appear on disk, then shuts Steam down.
    /// Runs Steam to complete the first-run client download.
    ///
    /// Steam's update pipeline has two observable phases under Wine:
    ///   1. **Download** — Steam writes ~150 MB of `.zip` packages into its
    ///      `package/` subdirectory. The progress bar is determinate.
    ///   2. **Apply (stuck)** — Steam enters an indeterminate "applying update"
    ///      phase (blue bar cycling left-to-right). Under Wine this phase never
    ///      completes; Steam does not write `steamui.dll` until relaunched.
    ///
    /// We detect phase transition by watching the `package/` directory size.
    /// Once it stops growing for `quiescenceWindow` seconds the download is
    /// done. We then kill Steam and relaunch — the next run finds the cached
    /// packages, extracts them in seconds, and writes `steamui.dll`.
    func bootstrap(engine: WineEngine, prefix: WinePrefix) async throws {
        // Kill any stale processes from a prior attempt to avoid wineserver conflicts.
        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        let steamExe  = prefix.steamExePath.path(percentEncoded: false)
        let dllPath   = prefix.steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        let pkgDirURL = prefix.steamInstallDir.appending(path: "package")
        let maxLaunches = 4
        // Hard backstop — should never be reached when quiescence detection works.
        let launchTimeout: Duration = .seconds(600)
        // How long the package dir must be size-stable before we declare download done.
        let quiescenceWindow: Duration = .seconds(25)

        for launchNum in 1...maxLaunches {
            // dll may already be present if a prior launch wrote it just before exiting.
            if FileManager.default.fileExists(atPath: dllPath) {
                log.info("[bootstrap] steamui.dll already present at start of launch \(launchNum) — done")
                break
            }

            if launchNum > 1 {
                log.info("[bootstrap] re-launching Steam (attempt \(launchNum)/\(maxLaunches))")
                killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(3))
            }

            log.info("[bootstrap] launching Steam (attempt \(launchNum)/\(maxLaunches))")
            // Run Steam directly — no virtual desktop wrapper.
            //
            // Previous code wrapped Steam in `explorer.exe /desktop=meridian-setup,800x600`.
            // This was intended to give the 32-bit bootstrapper a window station, but
            // Wine Staging 11.x with WoW64 (syswow64 populated from engine i386-windows/)
            // handles 32-bit PE binaries natively. The virtual desktop caused Steam's
            // self-restart cycle to loop indefinitely, preventing the client download.
            //
            // Running steam.exe directly matches the approach used by macos-wine-steam
            // (Wine Staging 11.3, confirmed working March 2026) and allows Steam's update
            // windows to be natively visible to the user during bootstrap.
            let args = [steamExe]
            log.info("[bootstrap] wine64 \(args.joined(separator: " "))")

            let process = Process()
            process.executableURL = engine.wine64URL
            process.arguments = args
            process.environment = engine.environment(for: prefix)

            let errPipe = Pipe()
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                log.error("[bootstrap] failed to launch Steam on attempt \(launchNum): \(error.localizedDescription)")
                if launchNum == maxLaunches { throw error }
                continue
            }

            isRunning = true
            let launchedPID = process.processIdentifier
            log.info("[bootstrap] Steam started pid=\(launchedPID) attempt=\(launchNum)/\(maxLaunches)")
            log.info("[bootstrap] waiting for steamui.dll — watching package/ dir for download completion")

            let started = ContinuousClock.now
            var pollCount = 0
            var dllFound  = false
            var steamExited = false

            // Package-dir quiescence state
            var lastPackageSize: Int = -1
            var packageSizeStableAt: ContinuousClock.Instant? = nil

            pollLoop: while ContinuousClock.now - started < launchTimeout {
                pollCount += 1

                if FileManager.default.fileExists(atPath: dllPath) {
                    let elapsed = ContinuousClock.now - started
                    log.info("[bootstrap] steamui.dll found after \(pollCount) polls (\(elapsed)) — attempt \(launchNum)")
                    dllFound = true
                    break pollLoop
                }

                if !process.isRunning {
                    // Steam's bootstrapper self-restarts during updates. Check if a
                    // wineserver is still alive for this prefix — that is a more
                    // reliable signal than `pgrep -f steam.exe` which matches any
                    // steam.exe on the system and caused infinite-loop false positives
                    // when the virtual desktop was in use.
                    let wineserverPath = engine.wineserverURL.path(percentEncoded: false)
                    let prefixEnv = engine.environment(for: prefix)
                    let wineserverAlive = await Task.detached {
                        let t = Process()
                        t.executableURL = URL(filePath: wineserverPath)
                        t.arguments = ["-p"]
                        t.environment = prefixEnv
                        t.standardOutput = FileHandle.nullDevice
                        t.standardError = FileHandle.nullDevice
                        try? t.run(); t.waitUntilExit()
                        return t.terminationStatus == 0
                    }.value

                    if wineserverAlive {
                        if pollCount % 10 == 0 {
                            log.info("[bootstrap] wine64 process exited but wineserver alive — Steam self-restarted (poll \(pollCount))")
                        }
                        try? await Task.sleep(for: .seconds(3))
                        continue
                    }

                    // Wineserver is also gone — give a 10s grace period before giving up.
                    let exitCode = process.terminationStatus
                    log.info("[bootstrap] Steam exited (exit=\(exitCode)) and wineserver dead on attempt \(launchNum) — 10s grace period")
                    try? await Task.sleep(for: .seconds(10))

                    if FileManager.default.fileExists(atPath: dllPath) {
                        log.info("[bootstrap] steamui.dll appeared during grace period — attempt \(launchNum) OK")
                        dllFound = true
                        break pollLoop
                    }

                    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    log.error("[bootstrap] Steam exited without steamui.dll on attempt \(launchNum) (exit=\(exitCode))")
                    let filteredStderr = filterWineStderr(stderr)
                    if !filteredStderr.isEmpty { log.error("[bootstrap] stderr: \(filteredStderr.prefix(4000))") }
                    if !stdout.isEmpty { log.info("[bootstrap] stdout: \(stdout.prefix(2000))") }

                    // Log Steam's own bootstrap_log.txt for additional diagnostics.
                    let steamBootstrapLog = prefix.steamInstallDir
                        .appending(path: "logs/bootstrap_log.txt")
                        .path(percentEncoded: false)
                    if let steamLog = try? String(contentsOfFile: steamBootstrapLog, encoding: .utf8), !steamLog.isEmpty {
                        log.info("[bootstrap] Steam bootstrap_log.txt:\n\(steamLog.suffix(2000))")
                    }

                    steamExited = true
                    break pollLoop
                }

                // --- Package directory quiescence detection ---
                // Steam writes update packages to package/ during the download phase.
                // Once those files stop growing, the download is complete and Steam
                // enters the "apply" phase — which hangs under Wine indefinitely.
                // Detecting size stability lets us restart without any fixed timeout.
                let currentPackageSize: Int = {
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: pkgDirURL,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: .skipsHiddenFiles
                    ) else { return 0 }
                    return children.reduce(0) {
                        $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }()

                if currentPackageSize != lastPackageSize {
                    if lastPackageSize > 0 {
                        log.debug("[bootstrap] package dir: \(lastPackageSize) → \(currentPackageSize) bytes")
                    }
                    lastPackageSize = currentPackageSize
                    packageSizeStableAt = nil
                } else if currentPackageSize > 0 {
                    if packageSizeStableAt == nil {
                        packageSizeStableAt = ContinuousClock.now
                        log.info("[bootstrap] package dir stable at \(currentPackageSize) bytes — quiescence timer started")
                    } else if let stableAt = packageSizeStableAt,
                              ContinuousClock.now - stableAt >= quiescenceWindow {
                        let elapsed = ContinuousClock.now - started
                        log.info("[bootstrap] package dir quiescent for \(quiescenceWindow) (\(elapsed) total) — download done, Steam stuck in apply phase — restarting")
                        break pollLoop
                    }
                }

                if pollCount % 5 == 0 {
                    let elapsed = ContinuousClock.now - started
                    let stableFor = packageSizeStableAt.map { ContinuousClock.now - $0 }
                    let pkgDirExists = FileManager.default.fileExists(atPath: pkgDirURL.path(percentEncoded: false))
                    log.info("[bootstrap] poll=\(pollCount) elapsed=\(elapsed) pkg=\(currentPackageSize)b pkgDirExists=\(pkgDirExists) stable=\(String(describing: stableFor)) wine64Running=\(process.isRunning)")
                }

                // Every 30 polls (~90s), dump Steam's own bootstrap log for visibility
                if pollCount % 30 == 0 {
                    let steamBootstrapLog = prefix.steamInstallDir
                        .appending(path: "logs/bootstrap_log.txt")
                        .path(percentEncoded: false)
                    if let steamLog = try? String(contentsOfFile: steamBootstrapLog, encoding: .utf8), !steamLog.isEmpty {
                        log.info("[bootstrap] Steam bootstrap_log.txt (poll \(pollCount)):\n\(steamLog.suffix(2000))")
                    }
                }

                try? await Task.sleep(for: .seconds(3))
            }

            if dllFound { break }

            if !steamExited {
                log.info("[bootstrap] killing all Wine processes before retry \(launchNum + 1)")
                killAll(engine: engine, prefix: prefix)
                try? await Task.sleep(for: .seconds(3))
            }

            if launchNum == maxLaunches {
                isRunning = false
                // Log Steam's own bootstrap_log.txt so the failure reason is visible
                // without needing to dig into the Wine prefix manually.
                let steamBootstrapLog = prefix.steamInstallDir
                    .appending(path: "logs/bootstrap_log.txt")
                    .path(percentEncoded: false)
                if let steamLog = try? String(contentsOfFile: steamBootstrapLog, encoding: .utf8), !steamLog.isEmpty {
                    log.error("[bootstrap] Steam bootstrap_log.txt (final):\n\(steamLog.suffix(2000))")
                } else {
                    log.error("[bootstrap] Steam bootstrap_log.txt not found — Steam may have exited before writing any logs")
                }
                throw SteamError.bootstrapFailed(
                    exitCode: -1,
                    detail: "Steam did not complete first-run update after \(maxLaunches) attempts"
                )
            }

            log.info("[bootstrap] attempt \(launchNum) ended without dll — will retry")
        }

        guard FileManager.default.fileExists(atPath: dllPath) else {
            isRunning = false
            throw SteamError.bootstrapFailed(exitCode: -1, detail: "steamui.dll missing after bootstrap loop")
        }

        log.info("[bootstrap] bootstrap succeeded — shutting down Steam")
        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        isRunning = false
        log.info("[bootstrap] Steam bootstrap complete ✓")
    }

    // MARK: - Steam IPC Commands

    /// Sends a command to the already-running Steam instance via IPC and waits for the
    /// forwarder process to exit, capturing its stderr and exit code.
    ///
    /// When Steam is alive, launching a second `steam.exe` with any arguments causes
    /// it to detect the running instance via Steam's socket, forward the command, and
    /// exit immediately — no second Steam window appears. This is the same mechanism
    /// used by `-applaunch`.
    ///
    /// We capture stderr and wait for exit so that failures (e.g. "Steam is not running",
    /// connection refused) are visible in logs rather than silently discarded.
    private func sendSteamCommand(_ args: [String], engine: WineEngine, prefix: WinePrefix) throws {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamExe] + args
        process.environment = engine.environment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier
        log.info("[sendSteamCommand] sent \(args.joined(separator: " ")) via IPC pid=\(pid)")

        // Register the short-lived IPC forwarder process with the suppressor so any
        // transient window it spawns is hidden immediately.
        windowSuppressor?.registerPID(pid)

        // Wait asynchronously so we don't block the main actor, then log the outcome.
        // The forwarder exits in < 1 second when Steam is running; log any errors.
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

    // MARK: - SteamCMD Authentication

    /// Authenticates SteamCMD by piping the user's password via stdin.
    ///
    /// Called during the onboarding credential auth flow — the password is available
    /// at that moment before being discarded. SteamCMD writes its own encrypted
    /// credential cache to config.vdf (key "7a611aa1") which is separate from
    /// the Steam client's ConnectCache JWT.
    ///
    /// After this runs once, subsequent SteamCMD calls use cached credentials
    /// and never need a password again (until the prefix is reset).
    ///
    /// Steam Guard: SteamCMD will request mobile app confirmation. The user
    /// gets one extra phone notification during onboarding.
    ///
    /// - Returns: `true` if SteamCMD authenticated successfully (exit 0).
    @discardableResult
    func authenticateSteamCMD(
        username: String,
        password: String,
        engine: WineEngine,
        prefix: WinePrefix
    ) async -> Bool {
        let steamcmdPath = prefix.steamInstallDir.appending(path: "steamcmd.exe").path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: steamcmdPath) else {
            log.warning("[authenticateSteamCMD] steamcmd.exe not found — skipping")
            return false
        }

        log.info("[authenticateSteamCMD] authenticating SteamCMD for user=\(username)")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamcmdPath, "+login", username, password, "+quit"]
        process.environment = engine.steamCMDEnvironment(for: prefix)

        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("[authenticateSteamCMD] failed to launch: \(error.localizedDescription)")
            return false
        }

        log.info("[authenticateSteamCMD] steamcmd pid=\(process.processIdentifier)")

        // Read output on a background thread
        let readHandle = combinedPipe.fileHandleForReading
        let outputThread = Thread {
            while true {
                let data = readHandle.availableData
                if data.isEmpty { break }
                if let chunk = String(data: data, encoding: .utf8) {
                    for line in chunk.components(separatedBy: .newlines) {
                        let l = line.trimmingCharacters(in: .whitespaces)
                        if l.isEmpty || l.contains("fixme:") || l.contains("err:") { continue }
                        log.info("[authenticateSteamCMD:output] \(l)")
                    }
                }
            }
        }
        outputThread.qualityOfService = .userInitiated
        outputThread.start()

        await Task.detached(priority: .utility) { process.waitUntilExit() }.value

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            log.info("[authenticateSteamCMD] SteamCMD authenticated ✓ (exit=0)")
            // Immediately back up the new credential cache outside the prefix.
            // This survives any subsequent prefix reset or wineserver kill so
            // future installs won't require Steam Guard re-confirmation.
            prefix.backupSteamCMDConfig()
            return true
        } else {
            log.warning("[authenticateSteamCMD] SteamCMD auth exited \(exitCode) — credential cache may not have been written")
            return false
        }
    }

    // MARK: - Game Installation via SteamCMD

    /// Downloads a game using SteamCMD — the only reliable headless install method
    /// in cases where the Steam client session is not active.
    ///
    /// ## Why SteamCMD (not steam.exe +app_update)
    ///
    /// Steam's `-silent` flag suppresses most UI, but the client may not fully authenticate.
    /// Every session shows `[Logged Off, 0, 0]` in connection_log.txt because the
    /// Steam Windows Service fails (GLE 126) and the CEF webhelper crash-loops on
    /// `chrome_elf.dll STATUS_BREAKPOINT` (missing `GetProcessMitigationPolicy` stub).
    /// Without authentication, `+app_update` via IPC is silently dropped — the ACF
    /// is never written and downloads never start.
    ///
    /// SteamCMD is a separate standalone binary that handles its own auth without
    /// CEF or the Steam Service. CLI-proven: `Logging in using cached credentials → OK`.
    ///
    /// ## Credential requirements
    ///
    /// The first SteamCMD login requires the user's password (done once via the setup
    /// sheet's `loginToSteamWithSteamCMD` flow). After that, SteamCMD writes an
    /// encrypted credential cache to config.vdf and subsequent logins are passwordless.
    ///
    /// ## Progress tracking
    ///
    /// SteamCMD creates the same `appmanifest_<appID>.acf` files in the steamapps
    /// directory as the full Steam client. The existing `isGameInstalled`,
    /// `isGameFullyInstalled`, and `gameDownloadProgress` polling works unchanged.
    func installWithSteamCMD(
        appID: Int,
        username: String,
        engine: WineEngine,
        prefix: WinePrefix,
        steamAuth: SteamAuthService? = nil,
        onProgress: @MainActor @Sendable @escaping (String) -> Void
    ) async throws {
        let steamcmdPath = prefix.steamInstallDir.appending(path: "steamcmd.exe").path(percentEncoded: false)

        // Self-healing: if steamcmd.exe is missing (prefix was reset, or first
        // install after a partial bootstrap), download it on the fly rather than
        // failing with a confusing "not found" error.
        if !FileManager.default.fileExists(atPath: steamcmdPath) {
            log.warning("[installWithSteamCMD] steamcmd.exe missing — downloading on the fly")
            await MainActor.run { onProgress("Installing game tools…") }
            do {
                let zipURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip")!
                let (data, _) = try await URLSession.shared.data(from: zipURL)
                let tempZip = FileManager.default.temporaryDirectory.appending(path: "steamcmd.zip")
                try data.write(to: tempZip)
                let unzip = Process()
                unzip.executableURL = URL(filePath: "/usr/bin/unzip")
                unzip.arguments = ["-o", tempZip.path(percentEncoded: false), "-d", prefix.steamInstallDir.path(percentEncoded: false)]
                unzip.standardOutput = FileHandle.nullDevice
                unzip.standardError = FileHandle.nullDevice
                try unzip.run()
                unzip.waitUntilExit()
                try? FileManager.default.removeItem(at: tempZip)
                log.info("[installWithSteamCMD] steamcmd.exe downloaded ✓")
            } catch {
                throw SteamError.installFailed("Failed to download SteamCMD: \(error.localizedDescription)")
            }
            guard FileManager.default.fileExists(atPath: steamcmdPath) else {
                throw SteamError.installFailed("steamcmd.exe still missing after download attempt.")
            }
        }

        log.info("[installWithSteamCMD] appID=\(appID) user=\(username)")
        onProgress("Starting SteamCMD download for appID \(appID)…")

        // Always restore the credential cache from backup before launching SteamCMD.
        // Checking for file existence is NOT enough — SteamCMD's self-update replaces
        // config.vdf with a fresh file containing no credentials (the file exists but
        // the credential section is empty). Always overwriting from backup guarantees
        // valid credentials are present regardless of what SteamCMD did to the file.
        log.info("[installWithSteamCMD] restoring SteamCMD credential cache from backup")
        prefix.restoreSteamCMDConfig()

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [
            steamcmdPath,
            "+login", username,
            "+app_update", "\(appID)", "validate",
            "+quit",
        ]
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardInput = FileHandle.nullDevice

        // SteamCMD writes ALL output (progress, errors, status) to STDOUT.
        // Wine fixme/err noise goes to STDERR. We merge both into one pipe so
        // we capture everything and can filter on the Swift side.
        let combinedPipe = Pipe()
        process.standardOutput = combinedPipe
        process.standardError = combinedPipe

        do {
            try process.run()
        } catch {
            throw SteamError.installFailed("Failed to launch steamcmd.exe: \(error.localizedDescription)")
        }

        log.info("[installWithSteamCMD] steamcmd pid=\(process.processIdentifier)")

        // Read combined output in a background thread (not async — availableData blocks).
        // Forward meaningful lines to the UI via onProgress on the MainActor.
        let readHandle = combinedPipe.fileHandleForReading
        let progressThread = Thread {
            while true {
                let data = readHandle.availableData
                if data.isEmpty { break } // EOF — process exited
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                for rawLine in chunk.components(separatedBy: .newlines) {
                    let l = rawLine.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { continue }
                    // Skip Wine fixme/err noise
                    if l.contains("fixme:") || l.contains("err:") || l.contains("mvk-info")
                        || l.contains("VK_") || l.contains("warn:") { continue }
                    // Log everything meaningful from SteamCMD
                    log.info("[installWithSteamCMD:output] \(l)")
                    // Forward to UI
                    DispatchQueue.main.async { onProgress(l) }
                }
            }
        }
        progressThread.qualityOfService = .userInitiated
        progressThread.start()

        await Task.detached(priority: .utility) { process.waitUntilExit() }.value

        let exitCode = process.terminationStatus

        if (exitCode == 7 || exitCode == 5), let auth = steamAuth, let password = auth.loadSteamPassword() {
            log.warning("[installWithSteamCMD] login failed (exit=\(exitCode)) — auto-recovering with Keychain password")
            await MainActor.run { onProgress("Re-authenticating SteamCMD — approve Steam Guard on your phone if prompted…") }

            let authOK = await authenticateSteamCMD(username: username, password: password, engine: engine, prefix: prefix)

            if authOK {
                log.info("[installWithSteamCMD] re-auth succeeded — retrying install")
                await MainActor.run { onProgress("Retrying download…") }
                try await installWithSteamCMD(appID: appID, username: username, engine: engine, prefix: prefix, steamAuth: steamAuth, onProgress: onProgress)
                return
            } else {
                log.error("[installWithSteamCMD] re-auth failed — Steam Guard may have timed out")
                throw SteamError.installFailed(
                    "SteamCMD login failed — Steam Guard confirmation may have timed out. "
                    + "Please try again and approve the Steam Guard notification on your phone."
                )
            }
        }

        if exitCode == 7 || exitCode == 5 {
            log.error("[installWithSteamCMD] login failed (exit=\(exitCode)) and no Keychain password available")
            throw SteamError.installFailed("Steam login expired. Please sign out and sign back in through Settings.")
        }

        if exitCode != 0 {
            log.error("[installWithSteamCMD] steamcmd exited \(exitCode)")
            throw SteamError.installFailed("SteamCMD exited with code \(exitCode)")
        }

        log.info("[installWithSteamCMD] appID=\(appID) install complete (exit=\(exitCode))")
        onProgress("SteamCMD download complete ✓")
    }

    /// Sends `+app_update <appID>` to the running Steam IPC as a fallback.
    /// This works when the Steam client is running in the background.
    /// Use `installWithSteamCMD` for reliable headless installs.
    func queueInstall(appID: Int, engine: WineEngine, prefix: WinePrefix) throws {
        log.info("[queueInstall] dispatching +app_update \(appID) via Steam IPC (fallback)")
        try sendSteamCommand(["+app_update", "\(appID)"], engine: engine, prefix: prefix)
        log.info("[queueInstall] +app_update dispatched for appID=\(appID)")
    }


    /// Brings the Steam window to the foreground.
    ///
    /// When a persistent Steam process is already running, sends `-activate` via IPC
    /// to surface its main window. If Steam is not running, starts it in visible mode.
    /// The suppressor is paused first so Steam's windows are not hidden.
    func showSteamUI(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[showSteamUI] showing Steam UI")
        // Pause suppression before doing anything — the polling timer runs every 0.5s and
        // will re-hide Steam windows if suppressionActive is still true.
        windowSuppressor?.allowSteamUITemporarily()

        if isSteamProcessAlive {
            // Persistent Steam is running — use IPC to surface its window.
            log.info("[showSteamUI] persistent Steam alive — sending -activate IPC")
            try? sendSteamCommand(["-activate"], engine: engine, prefix: prefix)
            return
        }

        // No running Steam — start it visibly so the user can see and interact with the UI.
        // Use -noreactlogin to suppress the React login dialog; the ConnectCache
        // session from onboarding auto-logs in without any user interaction.
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-noreactlogin"]
        log.info("[showSteamUI] no persistent Steam — starting: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        nonisolated(unsafe) let pipeSafe = errPipe
        Task.detached {
            let data = pipeSafe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let filtered = filterWineStderr(str)
                if !filtered.isEmpty {
                    log.debug("[showSteamUI] stderr: \(filtered.prefix(500))")
                }
            }
        }

        do {
            try process.run()
            let pid = process.processIdentifier
            log.info("[showSteamUI] Steam started pid=\(pid)")
            // Register with suppressor as a Steam process so its sub-windows are
            // tracked, but suppression is already paused so they won't be hidden.
            windowSuppressor?.registerPID(pid)
        } catch {
            log.error("[showSteamUI] failed to start Steam: \(error.localizedDescription)")
        }
    }

    /// Uninstalls a game by deleting its files directly on disk (no Steam IPC).
    ///
    /// Using Steam's `+app_uninstall` IPC command causes the running Steam instance
    /// to surface its main window, which is not desirable. Deleting the ACF manifest
    /// and game directory directly is silent, instant, and sufficient — Steam treats
    /// a missing ACF as "not installed" and does not auto-reinstall in silent mode.
    ///
    /// File I/O is dispatched on a background thread so the main actor is not blocked
    /// during large directory deletions.
    func uninstallGame(appID: Int, prefix: WinePrefix) async throws {
        log.info("[uninstallGame] deleting game files for appID=\(appID)")

        guard let acfURL = prefix.acfURL(for: appID) else {
            log.info("[uninstallGame] ACF not found in any library — game already uninstalled")
            return
        }

        let libraryRoot = acfURL.deletingLastPathComponent().deletingLastPathComponent()
        let installDirName = prefix.gameInstallDir(appID: appID)

        // Offload potentially large deletes to a background thread.
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default

            // Delete game directory first (large, slow).
            if let dirName = installDirName {
                let gameDir = libraryRoot.appending(path: "steamapps/common/\(dirName)")
                let gameDirPath = gameDir.path(percentEncoded: false)
                if fm.fileExists(atPath: gameDirPath) {
                    log.info("[uninstallGame] removing game dir: \(gameDirPath)")
                    try fm.removeItem(at: gameDir)
                    log.info("[uninstallGame] game dir removed ✓")
                }
            }

            // Delete the ACF manifest — this is what isGameInstalled checks.
            let acfPath = acfURL.path(percentEncoded: false)
            log.info("[uninstallGame] removing ACF: \(acfPath)")
            try fm.removeItem(at: acfURL)
            log.info("[uninstallGame] ACF removed ✓")
        }.value

        log.info("[uninstallGame] complete appID=\(appID)")
    }

    // MARK: - Game Launch

    /// Launches a game executable directly via Wine, bypassing steam.exe entirely.
    ///
    /// Used when: SteamCMD downloaded the game files and the game doesn't require
    /// Steam DRM validation. Most indie/Unity games work this way.
    @discardableResult
    func launchGameDirectly(
        appID: Int,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws -> Int32 {
        guard let installDir = prefix.gameInstallDir(appID: appID) else {
            throw SteamError.installFailed("Cannot find install directory for appID \(appID)")
        }

        let gamePath = prefix.steamInstallDir
            .appending(path: "steamapps/common/\(installDir)")
        let gamePathStr = gamePath.path(percentEncoded: false)

        // Find the main game executable — look for .exe files, prefer the one matching the game name
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: gamePathStr) else {
            throw SteamError.installFailed("Cannot list game directory: \(gamePathStr)")
        }

        let exeFiles = contents.filter { $0.hasSuffix(".exe") }
            .filter { !$0.lowercased().contains("crash") && !$0.lowercased().contains("redist") && !$0.lowercased().contains("unins") }

        guard let mainExe = exeFiles.first(where: { !$0.lowercased().contains("unity") }) ?? exeFiles.first else {
            throw SteamError.installFailed("No game executable found in \(gamePathStr)")
        }

        let exeFullPath = gamePath.appending(path: mainExe).path(percentEncoded: false)
        log.info("[launchGameDirectly] appID=\(appID) exe=\(exeFullPath)")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [exeFullPath]
        process.currentDirectoryURL = gamePath

        var env = engine.environment(for: prefix)

        let compat = GameCompatibilityDB.shared
        let gameExtraEnv = compat.extraEnv(for: appID)
        for (key, value) in gameExtraEnv {
            env[key] = value
        }
        if let gameOverrides = compat.dllOverrides(for: appID) {
            if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                env["WINEDLLOVERRIDES"] = existing + ";" + gameOverrides
            } else {
                env["WINEDLLOVERRIDES"] = gameOverrides
            }
        }

        if let profile = compat.profile(for: appID) {
            switch profile.dxmtMode {
            case .disabled:
                let disableOverride = "d3d11,dxgi=b"
                if let existing = env["WINEDLLOVERRIDES"], !existing.isEmpty {
                    env["WINEDLLOVERRIDES"] = existing + ";" + disableOverride
                } else {
                    env["WINEDLLOVERRIDES"] = disableOverride
                }
                log.info("[launchGameDirectly] dxmtMode=disabled — forcing Wine builtin d3d11")
            case .required:
                if engine.dxmtPath == nil {
                    log.warning("[launchGameDirectly] dxmtMode=required but DXMT not available")
                }
            case .auto:
                break
            }
            log.info("[launchGameDirectly] graphicsAPI=\(profile.graphicsAPI.rawValue) engine=\(profile.gameEngine.rawValue) status=\(profile.status.rawValue)")
        }

        process.environment = env
        log.info("[launchGameDirectly] WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        if !gameExtraEnv.isEmpty {
            log.info("[launchGameDirectly] game extraEnv: \(gameExtraEnv)")
        }

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            log.info("[launchGameDirectly] launched pid=\(process.processIdentifier)")
        } catch {
            log.error("[launchGameDirectly] failed: \(error.localizedDescription)")
            throw error
        }

        let pid = process.processIdentifier
        // Do NOT register the game PID with the window suppressor.
        // The suppressor is for hiding Steam/Wine helper windows — registering the
        // game exe here immediately hides the game window before suppression is
        // paused, making it invisible and impossible to bring back via the Dock.

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(40)
                for line in lines where !line.isEmpty {
                    log.info("[launchGameDirectly:stderr] \(line)")
                }
            }
            if !process.isRunning {
                log.info("[launchGameDirectly] exited code=\(process.terminationStatus)")
            }
        }

        return pid
    }

    /// Launches a game via `wine64 steam.exe -applaunch APPID`.
    ///
    /// Steam handles its own initialization, login, and game launch in a
    /// single process tree. The parent steam.exe stays alive as the Steam
    /// client — we do NOT wait for it to exit. Game exit is detected by
    /// GameProcess monitoring Wine processes.
    ///
    /// Steam is launched WITHOUT `-silent` so it can show its login window
    /// if the user hasn't authenticated yet. After first login, Steam
    /// remembers credentials and future launches auto-login.
    @discardableResult
    func launchGame(
        appID: Int,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws -> Int32 {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        // -nosteamcloudconfirmation: skips the "Steam Cloud sync conflict" dialog that
        // Steam shows on first launch of games with cloud saves. The dialog requires
        // user interaction; if suppressed without this flag the game never starts.
        // Cloud sync still runs — only the modal confirmation is bypassed.
        let args = [steamExe, "-silent", "-nosteamcloudconfirmation", "-applaunch", "\(appID)"]
        log.info("[launchGame] appID=\(appID) | wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args

        let env = engine.environment(for: prefix)
        process.environment = env
        log.info("[launchGame] WINEDLLOVERRIDES=\(env["WINEDLLOVERRIDES"] ?? "unset")")
        log.info("[launchGame] WINEDLLPATH=\(env["WINEDLLPATH"] ?? "unset")")
        log.info("[launchGame] WINEPREFIX=\(env["WINEPREFIX"] ?? "unset")")
        log.info("[launchGame] WINELOADER=\(env["WINELOADER"] ?? "unset")")
        log.debug("[launchGame] DYLD_FALLBACK_LIBRARY_PATH=\(env["DYLD_FALLBACK_LIBRARY_PATH"] ?? "unset")")
        log.debug("[launchGame] MTL_HUD_ENABLED=\(env["MTL_HUD_ENABLED"] ?? "unset")")

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        do {
            try process.run()
            log.info("[launchGame] launched pid=\(process.processIdentifier)")
        } catch {
            log.error("[launchGame] failed to launch: \(error.localizedDescription)")
            throw error
        }

        let pid = process.processIdentifier
        // Register the game launcher PID so any Steam "launching" splash window
        // is hidden immediately.
        windowSuppressor?.registerPID(pid)

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(100)
                for line in lines where !line.isEmpty {
                    log.info("[launchGame:stderr] \(line)")
                }
                if stderr.count > 5000 {
                    log.info("[launchGame:stderr] (truncated — \(stderr.count) chars raw, \(filtered.count) chars filtered)")
                }
            } else {
                log.debug("[launchGame:stderr] (empty — process pid=\(pid) produced no stderr)")
            }
            if !process.isRunning {
                log.info("[launchGame] process pid=\(pid) exited with code=\(process.terminationStatus)")
            }
        }

        isRunning = true
        log.info("[launchGame] Steam+game process tree started — monitoring handoff to GameProcess")
        return pid
    }

    // MARK: - Login Steam (non-silent, shows QR / login window)

    /// Launches Steam without `-silent` so the user can complete first-time login
    /// (QR code, username/password, etc.).
    ///
    /// Does NOT start the health monitor — the caller is responsible for killing
    /// this process once login is confirmed, then calling `startPersistent`.
    ///
    /// Returns the PID of the launched process so the caller can suppress and
    /// later kill it.
    @discardableResult
    func startSteamForLogin(engine: WineEngine, prefix: WinePrefix) throws -> pid_t {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-noreactlogin"]
        log.info("[startSteamForLogin] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        nonisolated(unsafe) let pipeSafe = errPipe
        Task.detached {
            let data = pipeSafe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                log.debug("[startSteamForLogin] stderr: \(str.prefix(1000))")
            }
        }

        try process.run()
        let pid = process.processIdentifier
        log.info("[startSteamForLogin] pid=\(pid)")
        return pid
    }

    // MARK: - Steam DRM Background Host

    /// Starts `steam.exe -silent` to provide the Steam IPC socket for games that
    /// use `steam_api64.dll` (Steam DRM). Without a running Steam client, those
    /// games call `SteamAPI_Init()`, get a failure, and exit silently.
    ///
    /// The process is NOT tracked in `persistentProcess` — it is a disposable
    /// background host. The caller is responsible for killing it via `killAll`
    /// after the game exits.
    ///
    /// Steam auto-logs in using the ConnectCache / loginusers.vdf session written
    /// during onboarding. The `SteamWindowSuppressor` hides any transient windows.
    func startSteamForDRM(
        engine: WineEngine,
        prefix: WinePrefix,
        windowSuppressor: SteamWindowSuppressor?
    ) throws {
        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        // -silent: start in tray-only mode (no main window)
        // -nofriendsui: suppress the friends overlay
        // -noreactlogin: skip the React-based login dialog if session is missing
        let args = [steamExe, "-silent", "-nofriendsui", "-noreactlogin"]
        log.info("[startSteamForDRM] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe
        nonisolated(unsafe) let pipeSafe = errPipe
        Task.detached {
            let data = pipeSafe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                let filtered = filterWineStderr(str)
                if !filtered.isEmpty {
                    log.debug("[startSteamForDRM] stderr: \(filtered.prefix(500))")
                }
            }
        }

        try process.run()
        let pid = process.processIdentifier
        log.info("[startSteamForDRM] pid=\(pid)")

        // Register with suppressor so any Steam UI windows are hidden immediately.
        windowSuppressor?.registerPID(pid)

        // Update TerminationCleanup context so wineserver -k works at app quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )
    }

    // MARK: - Interactive Login (advanced fallback)

    /// Opens a visible Steam window so the user can complete login interactively.
    ///
    /// This is an advanced fallback, only shown when the user explicitly clicks
    /// "Open Steam Window" from the SetupSheet. The native `SteamCredentialAuth`
    /// flow handles the first-time sign-in without any Wine UI.
    ///
    /// Before launching, writes `StartMinimized=0` to the Wine registry so Steam's
    /// login window actually appears rather than immediately minimising.
    func loginToSteamInteractive(engine: WineEngine, prefix: WinePrefix, suppressor: SteamWindowSuppressor?) async throws {
        log.info("[loginToSteamInteractive] starting interactive login flow")

        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        // Clear StartMinimized so the Steam login window is visible
        await configureSteamRegistryForInteractiveMode(engine: engine, prefix: prefix)

        suppressor?.stopSuppressingNewWindows()
        suppressor?.restoreAllObservedWindows()
        log.info("[loginToSteamInteractive] suppression paused — login window will be visible")

        let loginPID = try startSteamForLogin(engine: engine, prefix: prefix)
        log.info("[loginToSteamInteractive] login Steam launched pid=\(loginPID)")

        while !prefix.hasSteamLoginSession() {
            guard !Task.isCancelled else {
                log.info("[loginToSteamInteractive] cancelled — cleaning up")
                killAll(engine: engine, prefix: prefix)
                suppressor?.resumeSuppressing(pid: 0)
                return
            }
            try? await Task.sleep(for: .seconds(3))
        }

        log.info("[loginToSteamInteractive] login detected — transitioning to persistent Steam")

        killAll(engine: engine, prefix: prefix)
        try? await Task.sleep(for: .seconds(2))

        suppressor?.resumeSuppressing(pid: 0)
        try await startPersistent(engine: engine, prefix: prefix)
        if let pid = persistentProcessIdentifier {
            suppressor?.resumeSuppressing(pid: pid)
        }

        isSteamLoggedIn = true
        log.info("[loginToSteamInteractive] login flow complete ✓")
    }

    // MARK: - Persistent Steam

    /// Launches Steam in silent mode and keeps it running.
    ///
    /// Before starting, writes `StartMinimized=1` to the Wine registry so Steam
    /// prefers a minimized state — this is a defense-in-depth measure alongside
    /// the `SteamWindowSuppressor`.
    ///
    /// The process stays alive for the app's lifetime so that subsequent
    /// `steam.exe -applaunch` invocations use IPC to the running instance
    /// instead of cold-starting a new one.
    ///
    /// Used on-demand for DRM games (`startSteamForDRM`) and `showSteamUI`.
    /// Used on-demand for DRM games or showSteamUI.
    func startPersistent(engine: WineEngine, prefix: WinePrefix) async throws {
        guard persistentProcess == nil || !(persistentProcess?.isRunning ?? false) else {
            log.info("[startPersistent] Steam already running — skipping")
            return
        }

        // Write registry key before launching Steam. Runs on a background thread
        // to avoid blocking the main actor with waitUntilExit().
        await configureSteamRegistryForSilentMode(engine: engine, prefix: prefix)

        // Let the wineserver from reg-add drain so the next wine64 launch
        // doesn't collide with a shutting-down server.
        try? await Task.sleep(for: .seconds(2))

        let steamExe = prefix.steamExePath.path(percentEncoded: false)
        let args = [steamExe, "-silent", "-nofriendsui"]
        log.info("[startPersistent] launching: wine64 \(args.joined(separator: " "))")

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = args
        process.environment = engine.environment(for: prefix)

        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        persistentProcess = process
        persistentLaunchDate = Date()
        isRunning = true
        let pid = process.processIdentifier
        log.info("[startPersistent] pid=\(pid)")

        // Drain stderr in the background so crash reasons are visible in logs.
        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            if !stderr.isEmpty {
                let filtered = filterWineStderr(stderr)
                let lines = filtered.components(separatedBy: .newlines).prefix(80)
                for line in lines where !line.isEmpty {
                    log.info("[startPersistent:stderr] \(line)")
                }
                if stderr.count > 4000 {
                    log.info("[startPersistent:stderr] (truncated — \(stderr.count) chars raw, \(filtered.count) chars filtered)")
                }
            }
            if !process.isRunning {
                log.info("[startPersistent] process pid=\(pid) exited with code=\(process.terminationStatus)")
            }
        }

        // Register the PID directly with the suppressor so it can install an
        // AXObserver and hide windows immediately — before auto-discovery fires.
        windowSuppressor?.registerPID(pid)

        // Store paths for TerminationCleanup so wineserver -k can be called at quit.
        TerminationCleanup.context = TerminationCleanup.Context(
            wineserverPath: engine.wineserverURL.path(percentEncoded: false),
            winePrefix: prefix.path.path(percentEncoded: false),
            engineDirPath: WineEngine.engineDir.path(percentEncoded: false),
            libraryPath: engine.libraryPath
        )
    }

    /// Writes registry keys required for the silent persistent Steam process.
    ///
    /// Sets:
    ///   - `StartMinimized=1`  — Steam prefers tray-only state; defence-in-depth
    ///     alongside `SteamWindowSuppressor`.
    ///   - `WebProcessCmdLine=--no-sandbox --disable-gpu`  — Steam reads this registry
    ///     value and appends it to the webhelper's Chromium command line. Disabling the
    ///     GPU process prevents CEF from spawning a separate GPU child process, which
    ///     requires graphics primitives that may not be available under Wine.
    ///     `--no-sandbox` is required because Wine cannot emulate Chrome's sandbox.
    private func configureSteamRegistryForSilentMode(engine: WineEngine, prefix: WinePrefix) async {
        let wine64URL = engine.wine64URL
        let env = engine.environment(for: prefix)
        await Task.detached(priority: .userInitiated) {
            func run(_ args: [String]) {
                let p = Process()
                p.executableURL = wine64URL
                p.arguments = args
                p.environment = env
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                try? p.run()
                p.waitUntilExit()
                log.info("[configureSteam] reg exit=\(p.terminationStatus) args=\(args.suffix(from: 1).joined(separator: " "))")
            }

            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "StartMinimized", "/t", "REG_DWORD", "/d", "1", "/f"])

            run(["reg", "add", "HKCU\\Software\\Valve\\Steam",
                 "/v", "WebProcessCmdLine", "/t", "REG_SZ",
                 "/d", "--no-sandbox --disable-gpu", "/f"])
        }.value
    }

    /// Writes `StartMinimized=0` to the Wine registry so Steam's login window
    /// can appear during the interactive fallback login flow.
    private func configureSteamRegistryForInteractiveMode(engine: WineEngine, prefix: WinePrefix) async {
        let wine64URL = engine.wine64URL
        let env = engine.environment(for: prefix)
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = wine64URL
            process.arguments = [
                "reg", "add", "HKCU\\Software\\Valve\\Steam",
                "/v", "StartMinimized", "/t", "REG_DWORD", "/d", "0", "/f"
            ]
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            log.info("[configureSteam] StartMinimized=0 written (exit=\(process.terminationStatus))")
        }.value
    }

    /// Whether the persistent Steam process is still alive.
    var isSteamProcessAlive: Bool {
        persistentProcess?.isRunning ?? false
    }

    /// The macOS process identifier of the persistent Steam wine64 process.
    /// `nil` if no persistent process has been started or if it has exited.
    var persistentProcessIdentifier: pid_t? {
        guard persistentProcess?.isRunning == true else { return nil }
        return persistentProcess?.processIdentifier
    }

    // MARK: - Persistent Process Helpers

    /// Clears the persistent process reference after an intentional kill.
    /// Without this, `startPersistent` sees the dead process still referenced
    /// and skips the launch.
    func clearPersistentProcess() {
        persistentProcess = nil
        isRunning = false
        log.debug("[startPersistent] process reference cleared")
    }

    /// Polls until Steam is confirmed ready using multiple signals.
    ///
    /// Checks three indicators each poll cycle:
    ///   1. **wineserver** is running (Wine IPC layer operational)
    ///   2. **steam.exe** processes exist (Steam client is alive)
    ///   3. **steam.pid** file exists in the Steam install dir (Steam IPC ready)
    ///
    /// Additionally waits for Steam's `package/` directory to quiesce (stop
    /// growing). The persistent Steam process self-updates on first launch after
    /// bootstrap, writing ~150 MB of packages before applying them. Without this
    /// check, the library opens while the Steam updater dialog is still on screen.
    ///
    /// On subsequent launches where no update is needed, the package dir is
    /// already stable and this check adds no delay.
    ///
    /// - Parameter statusUpdate: Optional closure called on the main actor when
    ///   the status message should change (e.g. to "Steam is updating…").
    func waitUntilReady(
        prefix: WinePrefix,
        timeout: Duration = .seconds(180),
        statusUpdate: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let started = ContinuousClock.now
        var attempt = 0
        var consecutiveReady = 0
        let steamPidPath = prefix.steamInstallDir.appending(path: "steam.pid").path(percentEncoded: false)
        let pkgDirURL = prefix.steamInstallDir.appending(path: "package")

        // Package-dir quiescence state
        // Give Steam a 10-second head start so we don't falsely declare "stable"
        // before it has even begun downloading a self-update.
        let quiescenceHeadStart: Duration = .seconds(10)
        let quiescenceWindow: Duration = .seconds(20)
        var lastPackageSize: Int = -1
        var packageSizeStableAt: ContinuousClock.Instant? = nil
        var packageIsQuiescent = false
        var reportedUpdating = false

        log.info("[waitUntilReady] multi-signal + pkg-quiescence check (timeout=\(timeout))")
        log.info("[waitUntilReady] steam.pid path=\(steamPidPath)")

        while ContinuousClock.now - started < timeout {
            guard !Task.isCancelled else { return }
            attempt += 1

            let signals = await Task.detached { () -> (wineserver: Bool, steamProc: Bool, steamPid: Bool) in
                let wineserver: Bool = {
                    let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
                    t.arguments = ["-q", "wineserver"]
                    t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
                    try? t.run(); t.waitUntilExit()
                    return t.terminationStatus == 0
                }()

                let steamProc: Bool = {
                    let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
                    t.arguments = ["-f", "steam.exe"]
                    t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
                    try? t.run(); t.waitUntilExit()
                    return t.terminationStatus == 0
                }()

                let steamPid = FileManager.default.fileExists(atPath: steamPidPath)

                return (wineserver, steamProc, steamPid)
            }.value

            // --- Package directory quiescence ---
            // Only begin tracking after the head-start period so we don't declare
            // "stable" before a self-update has started downloading.
            let elapsed = ContinuousClock.now - started
            if elapsed >= quiescenceHeadStart {
                let currentPackageSize: Int = {
                    guard let children = try? FileManager.default.contentsOfDirectory(
                        at: pkgDirURL,
                        includingPropertiesForKeys: [.fileSizeKey],
                        options: .skipsHiddenFiles
                    ) else { return 0 }
                    return children.reduce(0) {
                        $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }()

                if currentPackageSize != lastPackageSize {
                    if lastPackageSize > 0 && currentPackageSize > lastPackageSize {
                        // Package dir is actively growing — Steam is downloading an update.
                        if !reportedUpdating {
                            reportedUpdating = true
                            log.info("[waitUntilReady] Steam is downloading an update (pkg=\(currentPackageSize)b)")
                            if let cb = statusUpdate {
                                await cb("Steam is updating…")
                            }
                        }
                    }
                    lastPackageSize = currentPackageSize
                    packageSizeStableAt = nil
                    packageIsQuiescent = false
                } else {
                    // Size unchanged this poll.
                    if packageSizeStableAt == nil {
                        packageSizeStableAt = ContinuousClock.now
                    }
                    if let stableAt = packageSizeStableAt,
                       ContinuousClock.now - stableAt >= quiescenceWindow {
                        if !packageIsQuiescent {
                            log.info("[waitUntilReady] package dir quiescent at \(currentPackageSize)b — no active update")
                        }
                        packageIsQuiescent = true
                    }
                }
            }

            let allReady = signals.wineserver && signals.steamProc
            // steam.pid: Steam writes this file when its IPC layer is ready on Windows.
            // Under Wine, steam.pid is never written (confirmed: always false across all
            // sessions). The strongReady branch below is kept for correctness with native
            // Windows Steam if that ever becomes relevant, but in practice allReady is
            // the only reachable path.
            let strongReady = allReady && signals.steamPid

            if allReady {
                consecutiveReady += 1
            } else {
                consecutiveReady = 0
            }

            if attempt % 5 == 0 || consecutiveReady > 0 {
                log.info("[waitUntilReady] attempt=\(attempt) | wineserver=\(signals.wineserver) steam.exe=\(signals.steamProc) steam.pid=\(signals.steamPid) | consecutive=\(consecutiveReady) | pkgStable=\(packageIsQuiescent)")
            }

            // Progressive warnings so the user and logs get visibility into stalls.
            let elapsedSec = Int(elapsed.components.seconds)
            if elapsedSec >= 60 && elapsedSec < 62 && !signals.steamProc {
                log.warning("[waitUntilReady] 60s elapsed — Steam processes still not detected")
                if let cb = statusUpdate {
                    await cb("Steam is taking longer than expected…")
                }
            }
            if elapsedSec >= 120 && elapsedSec < 122 && !signals.steamProc {
                log.error("[waitUntilReady] 120s elapsed — Steam may be stuck. Consider resetting the Wine environment.")
                if let cb = statusUpdate {
                    await cb("Steam is not responding — a reset may be needed")
                }
            }

            let requiredConsecutive = strongReady ? 3 : 4
            let processesReady = consecutiveReady >= requiredConsecutive

            let quiescenceGatePassed = elapsed < quiescenceHeadStart || packageIsQuiescent

            if processesReady && quiescenceGatePassed {
                let totalElapsed = ContinuousClock.now - started
                log.info("[waitUntilReady] Steam confirmed ready after \(attempt) polls (\(totalElapsed)) — wineserver=\(signals.wineserver) steam.exe=\(signals.steamProc) steam.pid=\(signals.steamPid)")
                isRunning = true
                return
            }

            try? await Task.sleep(for: .seconds(2))
        }

        log.error("[waitUntilReady] TIMEOUT — Steam not ready after \(timeout)")
        throw SteamError.steamNotReady
    }

    /// Gracefully shuts down the persistent Steam process.
    func stopPersistent(engine: WineEngine, prefix: WinePrefix) async {
        guard persistentProcess?.isRunning ?? false else {
            log.info("[stopPersistent] no persistent process running")
            persistentProcess = nil
            return
        }

        log.info("[stopPersistent] sending -shutdown")
        await stop(engine: engine, prefix: prefix)
        persistentProcess = nil
    }


    // MARK: - Process Control

    /// Stops the Steam client gracefully, then falls back to SIGTERM.
    func stop(engine: WineEngine, prefix: WinePrefix) async {
        log.info("[stop] sending -shutdown to Steam")
        let shutdownProcess = Process()
        shutdownProcess.executableURL = engine.wine64URL
        shutdownProcess.arguments = [prefix.steamExePath.path(percentEncoded: false), "-shutdown"]
        shutdownProcess.environment = engine.environment(for: prefix)

        let errPipe = Pipe()
        shutdownProcess.standardOutput = FileHandle.nullDevice
        shutdownProcess.standardError = errPipe

        do {
            // Use terminationHandler + continuation so the async task suspends
            // rather than blocking a cooperative thread pool thread.
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                shutdownProcess.terminationHandler = { _ in cont.resume() }
                do {
                    try shutdownProcess.run()
                } catch {
                    shutdownProcess.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[stop] shutdown exit=\(shutdownProcess.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[stop] shutdown stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[stop] failed to run -shutdown: \(error.localizedDescription)")
        }

        try? await Task.sleep(for: .seconds(3))
        isRunning = false
        log.info("[stop] Steam stopped")
    }

    /// Kills the Wine server for the prefix, terminating all Wine processes.
    func killAll(engine: WineEngine, prefix: WinePrefix) {
        log.info("[killAll] sending wineserver -k")
        let process = Process()
        process.executableURL = engine.wineserverURL
        process.arguments = ["-k"]
        process.environment = engine.environment(for: prefix)

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[killAll] wineserver -k exit=\(process.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[killAll] stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[killAll] failed to run wineserver -k: \(error.localizedDescription)")
        }

        isRunning = false
    }

    // MARK: - Errors

    enum SteamError: LocalizedError {
        case bootstrapFailed(exitCode: Int32, detail: String)
        case steamNotReady
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .bootstrapFailed(let code, let detail):
                return "Steam bootstrap failed (exit \(code)): \(detail)"
            case .steamNotReady:
                return "Steam could not start. Try resetting the Wine environment in Settings, or restart Meridian."
            case .installFailed(let detail):
                return "Install failed: \(detail)"
            }
        }
    }
}

// MARK: - Stderr filtering

/// Strips MoltenVK's verbose Vulkan extension dump from Wine stderr output.
///
/// Every Wine launch on macOS emits ~6200 chars of `[mvk-info]` + Vulkan extension
/// listings before any real output. The old 2000-char truncation silently discarded
/// every Wine error message that appeared after the MoltenVK dump. This filter
/// removes the noise so diagnostically useful lines are always captured.
private func filterWineStderr(_ raw: String) -> String {
    raw
        .components(separatedBy: .newlines)
        .filter { line in
            !line.hasPrefix("\tVK_")                           // Vulkan extension list
            && !line.hasPrefix("[mvk-info]")                   // MoltenVK info block
            && !line.contains("Vulkan extensions are supported") // count header line
            && !line.hasPrefix("\t[mvk-")                      // nested mvk blocks
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
