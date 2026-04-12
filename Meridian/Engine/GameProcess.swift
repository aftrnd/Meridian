import Foundation
import Observation

private let log = MeridianLog(category: "GameProcess")

/// Monitors a game launched through Wine/Steam.
///
/// After `steam.exe -applaunch`, the game runs as a Wine subprocess.
/// We detect game startup and exit by searching for the game's own process.
///
/// Uses two-phase monitoring with **game-specific process detection**:
///   - Parses the Steam appmanifest to get the game's `installdir` name
///     (e.g. "Animal Well"). Wine on macOS exposes Windows-style paths in
///     process listings, so `pgrep -f "Animal Well"` matches the game process.
///   - **Phase 1 (Startup):** Waits up to 120s for `pgrep -f "<game>"` to
///     find a match, confirming the game binary has been spawned.
///   - **Phase 2 (Running):** Polls `pgrep -f "<game>"` every 3s. When it
///     returns no matches for 2 consecutive polls, the game has exited.
///
/// This is immune to both lingering Wine helper processes (they don't contain
/// the game name) and transient launcher PID churn (we match by name, not PID).
///
/// When the game pattern is unavailable (ACF missing), falls back to
/// continuously-refreshed PID-set tracking above a captured baseline.
@Observable
@MainActor
final class GameProcess {

    // MARK: - Monitor Phase

    enum MonitorPhase: Equatable {
        case idle
        case startup
        case running
        case exited
        case timedOut
        case failed(String)
    }

    private(set) var monitorPhase: MonitorPhase = .idle
    private(set) var appID: Int = 0
    private(set) var logs: [String] = []

    /// PID of the launched Wine process. Used to check if the session is still alive.
    private(set) var launchedPID: Int32 = 0

    var isRunning: Bool {
        switch monitorPhase {
        case .startup, .running: return true
        default: return false
        }
    }

    var confirmedRunning: Bool { monitorPhase == .running }

    private var monitorTask: Task<Void, Never>?
    private var onLog: ((String) -> Void)?

    /// Baseline Wine process count captured before the game launches.
    /// Only used for fallback mode (when gamePattern is nil).
    private var baselineHostCount: Int = 0

    /// PIDs that existed at baseline (fallback mode only).
    private var baselinePIDs: Set<Int32> = []

    /// The pgrep search pattern derived from the Wine engine binary path.
    private var wineSearchPattern: String = "wine"

    private static let startupTimeout: Duration = .seconds(120)
    private static let pollInterval: Duration = .seconds(3)
    private static let consecutiveEmptyForExit = 2

    // MARK: - Public API

    /// Begins monitoring after steam.exe -applaunch dispatch.
    ///
    /// - Parameters:
    ///   - gamePattern: The game's installdir name from the ACF manifest (e.g. "Animal Well").
    ///     Used as a `pgrep -f` pattern to detect the game-specific process.
    ///     If nil, falls back to generic Wine process counting.
    ///   - onLog: Optional closure called on the main actor whenever
    ///     a user-facing status line is ready.
    func startMonitoring(
        appID: Int,
        launchedPID: Int32,
        engine: WineEngine,
        prefix: WinePrefix,
        gamePattern: String? = nil,
        onLog: ((String) -> Void)? = nil
    ) {
        log.info("[startMonitoring] appID=\(appID) pid=\(launchedPID) gamePattern=\(gamePattern ?? "nil")")
        self.appID = appID
        self.launchedPID = launchedPID
        self.monitorPhase = .startup
        self.logs = []
        self.onLog = onLog
        self.baselineHostCount = 0
        self.baselinePIDs = []

        let wineBinDir = engine.wine64URL.deletingLastPathComponent().path(percentEncoded: false)
        self.wineSearchPattern = wineBinDir
        log.info("[startMonitoring] wine search pattern: \(wineBinDir)")

        monitorTask?.cancel()
        let winePattern = self.wineSearchPattern
        monitorTask = Task { [weak self] in
            await self?.monitorLoop(
                appID: appID,
                launchedPID: launchedPID,
                prefix: prefix,
                winePattern: winePattern,
                gamePattern: gamePattern
            )
        }
    }

    /// Stops the game by killing the Wine server for the prefix.
    func stopGame(engine: WineEngine, prefix: WinePrefix) async {
        let currentAppID = self.appID
        log.info("[stopGame] appID=\(currentAppID) — sending wineserver -k")
        monitorTask?.cancel()
        monitorTask = nil
        monitorPhase = .idle
        launchedPID = 0

        let wineserverPath = engine.wineserverURL.path(percentEncoded: false)
        let prefixPath = prefix.path.path(percentEncoded: false)
        await Task.detached {
            Self.killWineServer(wineserverPath: wineserverPath, prefixPath: prefixPath)
        }.value
        log.info("[stopGame] game stopped (wineserver -k complete)")
    }

    func appendLog(_ line: String) {
        logs.append(line)
        log.info("[game] \(line)")
    }

    // MARK: - Two-Phase Monitor Loop

    private func monitorLoop(
        appID: Int,
        launchedPID: Int32,
        prefix: WinePrefix,
        winePattern: String,
        gamePattern: String?
    ) async {
        log.info("[monitor] started for appID=\(appID) pid=\(launchedPID)")
        if let gp = gamePattern {
            log.info("[monitor] game-specific pattern: \"\(gp)\"")
        } else {
            log.info("[monitor] no game pattern — using fallback (PID-set baseline)")
        }

        // Brief grace so the transient -applaunch IPC process can exit
        // before we capture the baseline.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }

        // Capture baseline for fallback mode
        let baseline = await Task.detached {
            Self.countProcesses(matching: winePattern)
        }.value
        baselineHostCount = baseline.count
        baselinePIDs = baseline.pids
        log.info("[monitor] baseline: \(baseline.count) processes, pids=\(self.baselinePIDs.sorted())")
        for line in baseline.lines {
            log.debug("[monitor]   baseline: \(line.prefix(200))")
        }

        // ── Phase 1: Startup ──────────────────────────────────────────────
        let startupOK = await startupPhase(
            appID: appID, launchedPID: launchedPID, prefix: prefix,
            winePattern: winePattern, gamePattern: gamePattern
        )
        guard startupOK, !Task.isCancelled else { return }

        // ── Phase 2: Running ──────────────────────────────────────────────
        await runningPhase(
            appID: appID, winePattern: winePattern, gamePattern: gamePattern
        )
    }

    // MARK: - Phase 1: Startup

    /// Polls for up to `startupTimeout` waiting for the game process.
    /// Returns `true` if game was found, `false` on timeout/cancel/failure.
    private func startupPhase(
        appID: Int,
        launchedPID: Int32,
        prefix: WinePrefix,
        winePattern: String,
        gamePattern: String?
    ) async -> Bool {
        onLog?("Waiting for Steam to start the game…")
        log.info("[monitor:startup] phase=startup | timeout=\(Self.startupTimeout) | gamePattern=\(gamePattern ?? "fallback")")

        let startupBegan = ContinuousClock.now
        var pollCount = 0
        var pidExited = false
        var consecutiveDetected = 0

        while !Task.isCancelled {
            let elapsed = ContinuousClock.now - startupBegan
            if elapsed >= Self.startupTimeout {
                log.error("[monitor:startup] TIMEOUT — no game processes after \(Self.startupTimeout)")
                onLog?("Timed out waiting for game to start")
                appendLog("Startup timeout — no game processes appeared within \(Int(Self.startupTimeout.components.seconds))s")
                monitorPhase = .timedOut
                self.launchedPID = 0
                return false
            }

            pollCount += 1

            if !pidExited {
                let pidAlive = await Task.detached {
                    Self.isProcessAlive(pid: launchedPID)
                }.value
                if !pidAlive {
                    pidExited = true
                    log.info("[monitor:startup] launched PID \(launchedPID) exited (expected)")
                }
            }

            let gameDetected: Bool
            var detectionMethod = "unknown"

            if let gp = gamePattern {
                // Primary: game-specific pgrep
                let result = await Task.detached {
                    Self.countProcesses(matching: gp)
                }.value
                gameDetected = result.count > 0
                detectionMethod = "game-specific(\(result.count))"

                if pollCount <= 3 || result.count > 0 {
                    for line in result.lines {
                        log.debug("[monitor:startup]   game-match: \(line.prefix(200))")
                    }
                }
            } else {
                // Fallback: engine-path delta above baseline
                let result = await Task.detached {
                    Self.countProcesses(matching: winePattern)
                }.value
                let newPIDs = result.pids.subtracting(self.baselinePIDs)
                gameDetected = !newPIDs.isEmpty
                detectionMethod = "fallback-delta(new=\(newPIDs.count))"
            }

            if gameDetected {
                consecutiveDetected += 1
            } else {
                consecutiveDetected = 0
            }

            if consecutiveDetected >= 2 {
                monitorPhase = .running
                log.info("[monitor:startup] game CONFIRMED after \(pollCount) polls (\(elapsed)) via \(detectionMethod)")
                appendLog("Game confirmed running (via \(detectionMethod))")
                onLog?("Game is running")
                return true
            }

            // Check wineserver health
            let wineserverAlive = await Task.detached {
                Self.isWineserverRunning()
            }.value
            if !wineserverAlive && pidExited {
                log.error("[monitor:startup] wineserver died and launched PID exited — environment lost")
                onLog?("Wine environment stopped unexpectedly")
                appendLog("Failed — Wine environment stopped before game started")
                monitorPhase = .failed("Wine environment stopped before the game could start")
                self.launchedPID = 0
                return false
            }

            if pollCount % 3 == 0 || consecutiveDetected > 0 {
                let secs = Int(elapsed.components.seconds)
                log.info("[monitor:startup] poll=\(pollCount) | \(secs)s | \(detectionMethod) | wineserver=\(wineserverAlive) | consecutive=\(consecutiveDetected)")
            }
            if pollCount % 5 == 0 {
                onLog?("Waiting for game to start… (\(Int(elapsed.components.seconds))s)")
            }

            try? await Task.sleep(for: Self.pollInterval)
        }

        log.info("[monitor:startup] cancelled (appID=\(appID))")
        return false
    }

    // MARK: - Phase 2: Running

    /// Polls until the game process disappears.
    ///
    /// With a game pattern: checks `pgrep -f "<gamePattern>"` each poll.
    /// Without (fallback): checks if any PIDs above baseline still exist,
    /// with a 15-second grace period when the set first becomes empty.
    private func runningPhase(
        appID: Int,
        winePattern: String,
        gamePattern: String?
    ) async {
        log.info("[monitor:running] phase=running — watching for exit via \(gamePattern != nil ? "game-specific" : "fallback") detection")

        var pollCount = 0
        var consecutiveGone = 0
        var gracePeriodStart: ContinuousClock.Instant?

        while !Task.isCancelled {
            pollCount += 1

            let gameGone: Bool

            if let gp = gamePattern {
                let result = await Task.detached {
                    Self.countProcesses(matching: gp)
                }.value
                gameGone = result.count == 0

                if pollCount <= 3 || pollCount % 10 == 0 || gameGone {
                    log.info("[monitor:running] poll=\(pollCount) | game-specific=\(result.count) | gone=\(gameGone)")
                }
                if !gameGone, pollCount <= 3 {
                    for line in result.lines {
                        log.debug("[monitor:running]   game-match: \(line.prefix(200))")
                    }
                }
            } else {
                // Fallback: continuously-refreshed PID-set above baseline
                let result = await Task.detached {
                    Self.countProcesses(matching: winePattern)
                }.value
                let newPIDs = result.pids.subtracting(self.baselinePIDs)

                if newPIDs.isEmpty {
                    if gracePeriodStart == nil {
                        gracePeriodStart = .now
                        log.info("[monitor:running] poll=\(pollCount) | fallback: no new PIDs — starting 15s grace period")
                    }
                    let graceElapsed = ContinuousClock.now - gracePeriodStart!
                    gameGone = graceElapsed >= .seconds(15)
                    log.info("[monitor:running] poll=\(pollCount) | fallback: new=\(newPIDs.count) grace=\(Int(graceElapsed.components.seconds))s")
                } else {
                    gracePeriodStart = nil
                    gameGone = false
                    if pollCount <= 3 || pollCount % 10 == 0 {
                        log.info("[monitor:running] poll=\(pollCount) | fallback: new=\(newPIDs.sorted())")
                    }
                }
            }

            if gameGone {
                consecutiveGone += 1
                log.info("[monitor:running] poll=\(pollCount) | gone consecutive=\(consecutiveGone)/\(Self.consecutiveEmptyForExit)")

                if consecutiveGone >= Self.consecutiveEmptyForExit {
                    log.info("[monitor:running] game exited (no game process for \(Self.consecutiveEmptyForExit) consecutive polls)")
                    appendLog("Game exited")
                    onLog?("Game has exited")
                    break
                }
            } else {
                consecutiveGone = 0
                if pollCount % 15 == 0 {
                    onLog?("Still running")
                }
            }

            try? await Task.sleep(for: Self.pollInterval)
        }

        if Task.isCancelled {
            log.info("[monitor:running] cancelled (appID=\(appID))")
        }

        monitorPhase = .exited
        self.launchedPID = 0
        log.info("[monitor] ended for appID=\(appID)")
    }

    // MARK: - Process Helpers

    private nonisolated static func isProcessAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private nonisolated static func isWineserverRunning() -> Bool {
        let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
        t.arguments = ["-q", "wineserver"]
        t.standardOutput = FileHandle.nullDevice; t.standardError = FileHandle.nullDevice
        try? t.run(); t.waitUntilExit()
        return t.terminationStatus == 0
    }

    // MARK: - Process Detection

    struct ProcessCheckResult: Sendable {
        let count: Int
        let lines: [String]

        var pids: Set<Int32> {
            Set(lines.compactMap { line in
                line.split(separator: " ").first.flatMap { Int32($0) }
            })
        }
    }

    /// Counts processes whose command line matches the given pattern.
    ///
    /// Uses `pgrep -l -f <pattern>` to search the full command line of
    /// all running processes. Excludes our own PID and the pgrep process.
    private nonisolated static func countProcesses(matching pattern: String) -> ProcessCheckResult {
        let t = Process(); t.executableURL = URL(filePath: "/usr/bin/pgrep")
        t.arguments = ["-l", "-f", pattern]
        let pipe = Pipe()
        t.standardOutput = pipe; t.standardError = FileHandle.nullDevice
        try? t.run(); t.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ourPID = String(ProcessInfo.processInfo.processIdentifier)

        let lines = output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .filter { line in
                let pid = line.split(separator: " ").first.map(String.init) ?? ""
                return pid != ourPID
            }
            .filter { !$0.lowercased().contains("pgrep") }

        return ProcessCheckResult(count: lines.count, lines: lines)
    }

    /// Kills the Wine server for the prefix.
    private nonisolated static func killWineServer(wineserverPath: String, prefixPath: String) {
        let process = Process()
        process.executableURL = URL(filePath: wineserverPath)
        process.arguments = ["-k"]
        process.environment = ["WINEPREFIX": prefixPath]

        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            log.info("[killWineServer] exit=\(process.terminationStatus)")
            if !stderr.isEmpty {
                log.debug("[killWineServer] stderr: \(stderr.prefix(500))")
            }
        } catch {
            log.error("[killWineServer] failed: \(error.localizedDescription)")
        }
    }
}
