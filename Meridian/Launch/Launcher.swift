import Foundation
import AppKit
import Observation

private let log = MeridianLog(category: "Launcher")

// MARK: - Launcher

/// Orchestrates game installs and launches. Does NOT own steam.exe.
///
/// All game installs go through SteamSession.installGame (SteamCMD-based).
/// All game launches go through wine64 direct execution.
/// For DRM games, SteamSession must be .running (steam.exe already authenticated)
/// before the game is launched — no implicit Steam restarts here.
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

    private(set) var launchState: LaunchState = .idle
    private(set) var currentActivity: String?
    private(set) var downloadProgress: Double?
    private(set) var logs: [String] = []
    private(set) var activeAppID: Int?
    private(set) var processesConfirmed: Bool = false
    private(set) var runningSince: Date?

    private let gameProcess = GameProcess()
    private let prefix = WinePrefix.defaultPrefix
    private var launchTask: Task<Void, Never>?

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
        launchState = .idle
        currentActivity = nil
        downloadProgress = nil
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

        let steamID = steamAuth?.steamID ?? ""

        // Install if needed.
        if !prefix.isGameFullyInstalled(appID: game.id) {
            guard session.isReady else {
                fail("Steam is not ready. Please sign in before installing games.")
                return
            }
            guard !steamID.isEmpty else {
                fail("Not signed in to Steam.")
                return
            }

            let alreadyPartial = prefix.isGameInstalled(appID: game.id)
            launchState = .installing(appID: game.id)
            currentActivity = alreadyPartial
                ? "Resuming download for \(game.name)…"
                : "Preparing download for \(game.name)…"
            appendLog("Starting install for \(game.name)")

            do {
                try await session.installGame(
                    appID: game.id,
                    name: game.name,
                    installDir: game.name,
                    steamID64: steamID,
                    engine: engine,
                    onStatus: { [weak self] msg in
                        self?.currentActivity = msg
                        self?.appendLog(msg)
                    }
                )
            } catch is CancellationError {
                log.info("[pipeline] install cancelled")
                launchState = .idle
                currentActivity = nil
                return
            } catch {
                fail("Could not start install: \(error.localizedDescription)", error: error)
                return
            }

            // Poll ACF for download progress.
            launchState = .downloading(appID: game.id)
            do {
                try await pollDownloadProgress(game: game, library: library)
            } catch {
                if error is CancellationError {
                    log.info("[pipeline] download polling cancelled")
                } else {
                    log.warning("[pipeline] download polling ended: \(error.localizedDescription)")
                }
                launchState = .idle
                currentActivity = nil
                return
            }

            AppSettings.shared.markInstalled(appID: game.id)
            if let lib = library { await lib.refresh(steamID: steamID, apiKey: steamAuth?.apiKey ?? "") }
        }

        guard launchAfterInstall else {
            launchState = .idle
            currentActivity = nil
            return
        }

        // Launch.
        guard session.isReady else {
            fail("Steam is not ready. Please sign in before launching games.")
            return
        }

        launchState = .launching(appID: game.id)
        currentActivity = "Launching \(game.name)…"
        appendLog("Launching \(game.name)")

        // Write steam_appid.txt for DRM games so the game can find its own appID.
        let needsDRM = prefix.gameRequiresSteamAPI(appID: game.id)
        if needsDRM {
            prefix.writeSteamAppID(game.id)
            log.info("[pipeline] DRM detected for appID=\(game.id) — steam.exe already running from bootstrap")
        }

        // Pause window suppression so the game window appears naturally.
        steamWindow?.pauseForGame()

        let result: GameLaunchResult
        do {
            result = try await launchDirect(game: game, engine: engine, session: session)
        } catch {
            steamWindow?.resumeAfterGame(steamPID: 0)
            fail("Could not launch game: \(error.localizedDescription)", error: error)
            return
        }

        // Record launch.
        AppSettings.shared.recordLaunch(appID: game.id)
        runningSince = Date()
        launchState = .running(appID: game.id)
        currentActivity = nil
        appendLog("Game running")

        // Monitor until exit.
        gameProcess.startMonitoring(
            appID: game.id,
            launchedPID: result.pid,
            engine: engine,
            prefix: prefix
        )

        processesConfirmed = gameProcess.monitorPhase != .idle

        // Poll until GameProcess returns to idle (game exited).
        while gameProcess.monitorPhase != .idle {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { break }
        }

        steamWindow?.resumeAfterGame(steamPID: 0)
        launchState = .idle
        currentActivity = nil
        runningSince = nil
        activeAppID = nil
        appendLog("Game exited")
        log.info("[pipeline] game exited appID=\(game.id)")
    }

    // MARK: - Private: launch via wine64

    private func launchDirect(
        game: Game,
        engine: WineEngine,
        session: SteamSession
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

        var env = session.gameEnvironment(for: game.id, engine: engine)
        let compat = GameCompatibilityDB.shared
        let launchArgs = compat.profile(for: game.id)?.launchArgs ?? []

        let process = Process()
        process.executableURL = engine.wine64URL
        process.currentDirectoryURL = gamePath
        process.arguments = [exePath] + launchArgs
        process.environment = env

        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe

        try process.run()
        let pid = process.processIdentifier
        log.info("[launch] pid=\(pid)")

        Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            if let raw = String(data: data, encoding: .utf8), !raw.isEmpty {
                let lines = raw.components(separatedBy: .newlines).prefix(200)
                for line in lines where !line.isEmpty {
                    log.info("[game:stderr] \(line)")
                }
            }
        }

        return GameLaunchResult(pid: pid, process: process)
    }

    // MARK: - Private: download progress polling

    private func pollDownloadProgress(game: Game, library: SteamLibraryStore?) async throws {
        let checkInterval = Duration.milliseconds(500)
        let maxWaitForStart = Duration.seconds(60)
        let started = ContinuousClock.now

        while true {
            try Task.checkCancellation()

            if prefix.isGameFullyInstalled(appID: game.id) {
                currentActivity = "\(game.name) installed"
                appendLog("\(game.name) download complete")
                return
            }

            if let progressTuple = prefix.gameDownloadProgress(appID: game.id),
               progressTuple.total > 0 {
                let progress = Double(progressTuple.downloaded) / Double(progressTuple.total)
                downloadProgress = progress
                let pct = Int(progress * 100)
                currentActivity = "Downloading \(game.name)… \(pct)%"
            } else if ContinuousClock.now - started > maxWaitForStart {
                // If SteamCMD already finished (small game), check fully installed.
                if prefix.isGameInstalled(appID: game.id) {
                    currentActivity = "\(game.name) installed"
                    return
                }
                // SteamCMD process may have exited without ACF update — treat as done.
                log.warning("[poll] no download progress after \(maxWaitForStart) — treating as complete")
                return
            }

            try? await Task.sleep(for: checkInterval)
        }
    }

    // MARK: - Private: uninstall

    private func uninstallGame(game: Game, engine: WineEngine) async throws {
        log.info("[uninstall] appID=\(game.id)")
        let fm = FileManager.default

        let libraries = prefix.steamLibraryFolders.map { $0.path(percentEncoded: false) }
        var acfPath: String?

        for lib in libraries {
            let candidate = lib + "/appmanifest_\(game.id).acf"
            if fm.fileExists(atPath: candidate) {
                acfPath = candidate
                break
            }
        }

        if let acfPath {
            let installDir = prefix.gameInstallDir(appID: game.id) ?? game.name
            let gameDir = prefix.steamInstallDir
                .appending(path: "steamapps/common/\(installDir)")
                .path(percentEncoded: false)
            if fm.fileExists(atPath: gameDir) {
                try fm.removeItem(atPath: gameDir)
                log.info("[uninstall] removed game dir: \(gameDir)")
            }
            try fm.removeItem(atPath: acfPath)
            log.info("[uninstall] removed ACF: \(acfPath)")
        } else {
            log.info("[uninstall] ACF not found for appID=\(game.id) — nothing to remove")
        }
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

// MARK: - GameLaunchResult

struct GameLaunchResult: Sendable {
    let pid: Int32
    let process: Process
}
