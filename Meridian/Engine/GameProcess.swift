import Foundation
import AppKit
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

    /// Set while Steam is busy before it starts the game: waiting on the
    /// player (an EULA), running the game's install scripts, or syncing
    /// behind another game's cloud upload (Pattern 68). The startup
    /// timeout counts from when this clears, and nothing counts as the game
    /// meanwhile: the install scripts run from the game's folder
    /// (`SteamService.exe /installscript …\<game>\…`,
    /// `…\<game>\Redists\directx\DXSETUP.exe`) and match its pattern.
    /// Fallout: New Vegas, Oct 14 2026: confirmed "running" 6 s into Steam's
    /// DirectX setup; the player saw nothing, pressed Stop and killed it.
    var startupHeld = false

    private var monitorTask: Task<Void, Never>?
    private var onLog: ((String) -> Void)?

    /// Baseline Wine process count captured before the game launches.
    /// Only used for fallback mode (when gamePattern is nil).
    private var baselineHostCount: Int = 0

    /// PIDs that existed at baseline (fallback mode only).
    private var baselinePIDs: Set<Int32> = []

    /// Every game process seen this session, and the ones that appeared after
    /// confirmation and wait to show a window before being activated.
    private var gamePIDs: Set<Int32> = []
    private var awaitingWindow: [Int32: ContinuousClock.Instant] = [:]

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
        self.startupHeld = false
        self.logs = []
        self.onLog = onLog
        self.baselineHostCount = 0
        self.baselinePIDs = []
        self.gamePIDs = []
        self.awaitingWindow = [:]

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

    /// Stops monitoring WITHOUT killing any processes. Used when a launch is
    /// cancelled/stopped while Steam owns the process tree (Online mode) —
    /// killing wineserver there would take the persistent Steam session down
    /// with it. Also stops the monitor's `onLog` callbacks, which otherwise
    /// keep overwriting the UI's activity text with "Waiting for game to
    /// start…" after the user already cancelled (Bug D,
    /// HANDOFF-2026-07-02-v4).
    func cancelMonitoring() {
        guard monitorTask != nil || monitorPhase != .idle else { return }
        log.info("[cancelMonitoring] appID=\(appID) — monitor stopped, processes left alone")
        monitorTask?.cancel()
        monitorTask = nil
        onLog = nil
        monitorPhase = .idle
        launchedPID = 0
    }

    /// Kills only the game's own processes (`pkill -9 -f <pattern>`), leaving
    /// wineserver — and any persistent Steam session sharing it — alive.
    ///
    /// Used when stopping a game while Steam runs in the background: a full
    /// `wineserver -k` takes steam.exe + steamwebhelper down with it, and
    /// CEF treats the next Steam boot as crash recovery, surfacing webhelper
    /// windows (user-reported Jul 3 2026). The pattern is the game's ACF
    /// installdir name, which appears in the Wine process's command line
    /// even after argv[0] rewrite (engine-research-findings.mdc Pattern 2).
    func killGameProcesses(pattern: String) async {
        let currentAppID = self.appID
        log.info("[killGameProcesses] appID=\(currentAppID) pattern=\"\(pattern)\" — wineserver + Steam left alive")
        monitorTask?.cancel()
        monitorTask = nil
        onLog = nil
        monitorPhase = .idle
        launchedPID = 0
        await Task.detached {
            Self.killProcesses(matching: pattern)
        }.value
        log.info("[killGameProcesses] done")
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

        var startupBegan = ContinuousClock.now
        var pollCount = 0
        var pidExited = false
        var consecutiveDetected = 0
        var detectedPIDs: Set<Int32> = []

        while !Task.isCancelled {
            if startupHeld { startupBegan = .now }
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
                if gameDetected { detectedPIDs = result.pids }

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
                if gameDetected { detectedPIDs = newPIDs }
            }

            if gameDetected, !startupHeld {
                consecutiveDetected += 1
            } else {
                consecutiveDetected = 0
            }

            if consecutiveDetected >= 2 {
                monitorPhase = .running
                log.info("[monitor:startup] game CONFIRMED after \(pollCount) polls (\(elapsed)) via \(detectionMethod)")
                appendLog("Game confirmed running (via \(detectionMethod))")
                onLog?("Game is running")
                gamePIDs = detectedPIDs
                activateGameApplication(pids: detectedPIDs)
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
                log.info("[monitor:startup] poll=\(pollCount) | \(secs)s | \(detectionMethod) | wineserver=\(wineserverAlive) | held=\(startupHeld) | consecutive=\(consecutiveDetected)")
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
                await activateNewGameProcesses(result)
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

    /// Brings the game's Wine process to the front once it is confirmed.
    ///
    /// winemac defers display-mode changes while its NSApplication is not
    /// active and applies them on `applicationDidBecomeActive`. With
    /// `CaptureDisplaysForFullscreen` a cold launch therefore asked for
    /// 2560×1440, found the mode, and drew a quarter-size frame in the corner
    /// of the captured 5K display until the user minimised/reopened the game
    /// (user-observed 2026-09-17, `+display` trace: "match mode 10" with no
    /// switch). Wine creates its NSApplication a little after the process
    /// appears, so retry for a few seconds until activation sticks.
    private func activateGameApplication(pids: Set<Int32>) {
        guard !pids.isEmpty else { return }
        Task { @MainActor in
            for attempt in 0..<12 {
                for pid in pids {
                    guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
                    if app.isActive { return }
                    if app.activate(from: .current, options: []) {
                        log.info("[monitor] activated game app pid=\(pid) (attempt \(attempt + 1))")
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            // macOS activation is cooperative: from Meridian it may need
            // Meridian to be the active app. Say who was, for the next trace.
            let front = NSWorkspace.shared.frontmostApplication
            log.warning("[monitor] game app pids=\(pids.sorted()) not active after 6 s; frontmost=\(front?.localizedName ?? "none") pid=\(front?.processIdentifier ?? 0)")
        }
    }

    /// Activates game processes that start after the game was confirmed: the
    /// game a launcher starts (FalloutNVLauncher.exe → FalloutNV.exe) or the
    /// real exe behind a bootstrap. Nobody activated them (Oct 14 2026:
    /// Meridian activated only New Vegas's launcher, pid 20174), and winemac
    /// applies a game's display-mode switch only once it is active (see
    /// above). Its quarter-size frame needs Wine patch 0006 as well: a switch
    /// applied late leaves winemac's Retina cache stale (Pattern 54). Each new
    /// process is activated once it shows a window, so helpers without one
    /// (crash handlers) never take focus; one that shows none within a minute
    /// is left alone.
    private func activateNewGameProcesses(_ result: ProcessCheckResult) async {
        let current = result.pids
        for pid in current.subtracting(gamePIDs) {
            awaitingWindow[pid] = .now
            log.info("[monitor:running] new game process pid=\(pid); activating it once it shows a window")
        }
        gamePIDs.formUnion(current)
        guard !awaitingWindow.isEmpty else { return }

        let waiting = Set(awaitingWindow.keys)
        let withWindow = await Task.detached { Self.pidsWithOnScreenWindow(among: waiting) }.value
        for (pid, since) in awaitingWindow {
            if withWindow.contains(pid) {
                awaitingWindow[pid] = nil
                activateGameApplication(pids: [pid])
            } else if !current.contains(pid) || ContinuousClock.now - since > .seconds(60) {
                awaitingWindow[pid] = nil
            }
        }
    }

    /// Which of `pids` own an on-screen window. Owner PID and bounds need no
    /// Screen Recording permission (window titles would).
    private nonisolated static func pidsWithOnScreenWindow(among pids: Set<Int32>) -> Set<Int32> {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var owners: Set<Int32> = []
        for window in windows {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 1, rect.height > 1 else { continue }
            owners.insert(pid)
        }
        return owners
    }

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
        let lines = gameProcessLines(in: output, ourPID: ProcessInfo.processInfo.processIdentifier)
        return ProcessCheckResult(count: lines.count, lines: lines)
    }

    /// The `pgrep -l -f` lines (`<pid> <command line>`) that are game
    /// processes: not Meridian, not pgrep, and not the redistributables
    /// Steam's install scripts run from inside the game's folder
    /// (`<game>\_CommonRedist\vcredist\…\VC_redist.x64.exe`, The Baby in
    /// Yellow, Oct 12 2026). Those match the game's pattern but are not the
    /// game: counted, an installer could confirm the game "running", and its
    /// exit end the session.
    nonisolated static func gameProcessLines(in output: String, ourPID: Int32) -> [String] {
        output
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .filter { line in
                let pid = line.split(separator: " ").first.map(String.init) ?? ""
                return pid != String(ourPID)
            }
            .filter { !$0.lowercased().contains("pgrep") }
            .filter { !$0.localizedCaseInsensitiveContains("_CommonRedist") }
    }

    /// Force-kills all processes whose command line matches the pattern.
    /// pkill never matches its own process, and Meridian's command line
    /// does not contain game installdir names, so this is self-safe.
    private nonisolated static func killProcesses(matching pattern: String) {
        let t = Process()
        t.executableURL = URL(filePath: "/usr/bin/pkill")
        t.arguments = ["-9", "-f", pattern]
        t.standardOutput = FileHandle.nullDevice
        t.standardError = FileHandle.nullDevice
        try? t.run()
        t.waitUntilExit()
        // pkill exit 0 = killed something, 1 = no match (already gone) —
        // both are success for a stop request.
        log.info("[killProcesses] pkill -9 -f \"\(pattern)\" exit=\(t.terminationStatus)")
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
