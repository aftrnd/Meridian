import Foundation
import Observation

private let log = MeridianLog(category: "SteamCMDService")

/// Manages SteamCMD game downloads for Meridian.
///
/// ## Architecture: Batch Mode Only
///
/// SteamCMD interactive mode (no args, reading commands from a stdin pipe) is
/// incompatible with Wine — when stdin is a non-TTY pipe, SteamCMD exits
/// immediately with no output. CLI-verified March 2026.
///
/// Batch mode works correctly and reliably:
///
///   wine64 steamcmd.exe +login USERNAME +app_update APPID validate +quit
///   → completes in ~7s after warm-up
///
/// ## SteamCMD Self-Update
///
/// SteamCMD downloads a ~300MB self-update the very first time it runs after a
/// fresh install. Subsequent runs just verify the installation (~2s) and proceed.
/// `warmUp()` is called during bootstrap (on the splash screen) so this delay
/// happens once at startup, not when the user clicks Install.
///
/// ## Credential Caching
///
/// SteamCMD caches credentials in the WINEPREFIX config.vdf after the first
/// interactive login (done during onboarding). Subsequent batch calls use
/// `+login USERNAME` (no password) — SteamCMD auto-authenticates from cache.
///
/// ## Single Instance Constraint
///
/// SteamCMD uses file locks on its config directory. Running two batch instances
/// concurrently against the same WINEPREFIX deadlocks. `installGame` enforces
/// mutual exclusion via its `.busy` state check.
@Observable
@MainActor
final class SteamCMDService {

    // MARK: - State

    enum State: Equatable {
        case idle
        case ready
        case busy(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    var isReady: Bool { state == .ready }

    private var savedEngine: WineEngine?
    private var savedPrefix: WinePrefix?
    private var savedUsername: String = ""

    /// The currently running batch process (if any).
    private var activeProcess: Process?

    // MARK: - Configure

    /// Saves credentials and marks the service ready.
    ///
    /// No Wine process is launched. The service is immediately available for
    /// `installGame()` calls. This is called once at bootstrap step 7.
    func start(
        username: String,
        engine: WineEngine,
        prefix: WinePrefix
    ) async throws {
        savedEngine = engine
        savedPrefix = prefix
        savedUsername = username
        state = .ready
        log.info("[start] SteamCMD configured for user=\(username) (batch mode)")
    }

    // MARK: - Warm-Up

    /// Warms up SteamCMD during bootstrap: runs `steamcmd.exe +login USERNAME +quit`.
    ///
    /// This triggers SteamCMD's self-update (first run only, ~300MB) and caches
    /// the login session so subsequent game installs start downloading immediately.
    /// After the first run, this takes ~7 seconds and runs silently at every launch.
    ///
    /// Non-throwing — warm-up failure (network down, expired credentials) is logged
    /// as a warning but does not fail bootstrap. Game installs will retry warm-up
    /// on demand via `installGame`.
    func warmUp(
        onProgress: @MainActor @Sendable @escaping (String) -> Void
    ) async {
        guard let engine = savedEngine, let prefix = savedPrefix, !savedUsername.isEmpty else {
            log.warning("[warmUp] not configured — skipping")
            return
        }

        let steamcmdPath = prefix.steamInstallDir
            .appending(path: "steamcmd.exe")
            .path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: steamcmdPath) else {
            log.warning("[warmUp] steamcmd.exe not found — skipping")
            return
        }

        state = .busy("Warming up")
        log.info("[warmUp] running +login \(savedUsername) +quit")

        prefix.restoreSteamCMDConfig()

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamcmdPath, "+login", savedUsername, "+quit"]
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        activeProcess = process

        do {
            try process.run()
        } catch {
            activeProcess = nil
            state = .ready
            log.warning("[warmUp] failed to launch: \(error.localizedDescription)")
            return
        }

        let fd  = stdoutPipe.fileHandleForReading.fileDescriptor
        let buffer = LineBuffer()

        let readerTask = Task.detached {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &bytes, bytes.count)
                if n <= 0 { break }
                if let str = String(bytes: bytes[0..<n], encoding: .utf8) {
                    await buffer.append(str)
                }
            }
        }

        let stderrTask = Task.detached {
            let errFd = stderrPipe.fileHandleForReading.fileDescriptor
            var buf = [UInt8](repeating: 0, count: 4096)
            while true { if read(errFd, &buf, buf.count) <= 0 { break } }
        }

        // 5 minute timeout — covers the first-ever self-update (~300MB)
        let deadline = ContinuousClock.now + .seconds(300)

        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                await readerTask.value
                let remaining = await buffer.takeAll()
                for line in remaining {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    log.info("[warmUp:out] \(trimmed)")
                    if Self.shouldShowLine(trimmed) {
                        await MainActor.run { onProgress(trimmed) }
                    }
                }
                break
            }

            let lines = await buffer.takeAll()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                log.info("[warmUp:out] \(trimmed)")
                if Self.shouldShowLine(trimmed) {
                    await MainActor.run { onProgress(trimmed) }
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        stderrTask.cancel()
        activeProcess = nil

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            log.info("[warmUp] complete ✓ (exit=0)")
        } else {
            log.warning("[warmUp] exited with code \(exitCode) — credentials may be stale, install will retry")
        }

        // Back up fresh config in case self-update rewrote it
        prefix.backupSteamCMDConfig()
        state = .ready
    }

    // MARK: - Install

    /// Downloads and installs a game using SteamCMD batch mode.
    ///
    /// Spawns: `wine64 steamcmd.exe +login USERNAME +app_update APPID validate +quit`
    ///
    /// Progress lines are forwarded to `onProgress` as they arrive.
    /// Returns when the install completes or throws on failure.
    func installGame(
        appID: Int,
        onProgress: @MainActor @Sendable @escaping (String) -> Void
    ) async throws {
        guard let engine = savedEngine, let prefix = savedPrefix, !savedUsername.isEmpty else {
            throw ServiceError.notConfigured
        }

        // Enforce single-instance constraint
        if case .busy = state {
            throw ServiceError.alreadyBusy
        }

        let steamcmdPath = prefix.steamInstallDir
            .appending(path: "steamcmd.exe")
            .path(percentEncoded: false)

        guard FileManager.default.fileExists(atPath: steamcmdPath) else {
            state = .failed("steamcmd.exe not found")
            throw ServiceError.steamcmdNotFound
        }

        state = .busy("Installing appID \(appID)")
        log.info("[installGame] launching batch: +login \(savedUsername) +app_update \(appID) validate +quit")
        await MainActor.run { onProgress("Connecting to Steam…") }

        // Restore credential cache before every run — SteamCMD's self-update
        // can overwrite config.vdf with a blank file.
        prefix.restoreSteamCMDConfig()

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [
            steamcmdPath,
            "+login", savedUsername,
            "+app_update", "\(appID)", "validate",
            "+quit",
        ]
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        activeProcess = process

        do {
            try process.run()
        } catch {
            activeProcess = nil
            state = .failed("Failed to launch steamcmd: \(error.localizedDescription)")
            throw error
        }

        // Stream stdout line by line on a background thread.
        // Use POSIX read() — availableData returns 0 on an open pipe with no data,
        // causing premature loop exit before SteamCMD has finished writing.
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        let buffer = LineBuffer()

        let readerTask = Task.detached {
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(fd, &bytes, bytes.count)
                if n <= 0 { break }
                if let str = String(bytes: bytes[0..<n], encoding: .utf8) {
                    await buffer.append(str)
                }
            }
        }

        // Drain stderr silently (prevents Wine from blocking if its stderr pipe fills)
        let stderrTask = Task.detached {
            let errFd = stderrPipe.fileHandleForReading.fileDescriptor
            var buf = [UInt8](repeating: 0, count: 4096)
            while true { if read(errFd, &buf, buf.count) <= 0 { break } }
        }

        // Poll for output lines and check for completion/errors
        let deadline = ContinuousClock.now + .seconds(7200) // 2h max
        var succeeded = false
        var lastError: String? = nil

        while ContinuousClock.now < deadline {
            guard process.isRunning else {
                // Process exited — drain remaining buffered lines
                await readerTask.value
                let remaining = await buffer.takeAll()
                for line in remaining {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { continue }
                    log.info("[installGame:out] \(trimmed)")
                    if trimmed.contains("Success! App") { succeeded = true }
                    if trimmed.hasPrefix("ERROR!") || trimmed.contains("Login Failure") {
                        lastError = trimmed
                    }
                    let filtered = Self.shouldShowLine(trimmed)
                    if filtered { await MainActor.run { onProgress(trimmed) } }
                }
                break
            }

            let lines = await buffer.takeAll()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                log.info("[installGame:out] \(trimmed)")

                if trimmed.contains("Success! App") { succeeded = true }
                if trimmed.hasPrefix("ERROR!") || trimmed.contains("Login Failure") {
                    lastError = trimmed
                }

                if Self.shouldShowLine(trimmed) {
                    await MainActor.run { onProgress(trimmed) }
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        stderrTask.cancel()
        activeProcess = nil

        let exitCode = process.terminationStatus
        log.info("[installGame] appID=\(appID) exit=\(exitCode) succeeded=\(succeeded)")

        if let err = lastError {
            state = .ready
            throw ServiceError.installFailed(err)
        }

        if !succeeded && exitCode != 0 {
            state = .ready
            throw ServiceError.installFailed("SteamCMD exited \(exitCode) without success confirmation")
        }

        state = .ready
        log.info("[installGame] appID=\(appID) complete ✓")
        await MainActor.run { onProgress("Download complete ✓") }
    }

    // MARK: - Shutdown

    /// Terminates any in-progress batch install. Called at app termination.
    nonisolated func shutdown() {
        MainActor.assumeIsolated {
            if let proc = activeProcess, proc.isRunning {
                log.info("[shutdown] terminating active SteamCMD process pid=\(proc.processIdentifier)")
                proc.terminate()
                activeProcess = nil
            }
            state = .idle
        }
    }

    var isAlive: Bool { activeProcess?.isRunning ?? false }

    // MARK: - Output Filtering

    /// Returns true if this line should be forwarded to the UI progress callback.
    private static func shouldShowLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        // Filter Wine/internal noise
        if line.hasPrefix("wineserver:") || line.hasPrefix("wine:") { return false }
        if line.contains(":fixme:") || line.contains(":err:") || line.contains(":warn:") { return false }
        if line.hasPrefix("CWork") || line.hasPrefix("Redirecting stderr") { return false }
        // Keep Logging directory and [----] lines — [----] is SteamCMD self-update progress
        // which can take 3+ minutes on first run. Filtering it makes the UI appear frozen.
        if line.hasPrefix("Logging directory") { return false }
        if line.hasPrefix("Unloading Steam") || line.hasPrefix("Loading Steam") { return false }
        return true
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case notConfigured
        case steamcmdNotFound
        case alreadyBusy
        case installFailed(String)
        case installTimeout

        var errorDescription: String? {
            switch self {
            case .notConfigured:    return "SteamCMD not configured — sign in through Settings first"
            case .steamcmdNotFound: return "steamcmd.exe not found in prefix"
            case .alreadyBusy:      return "A download is already in progress"
            case .installFailed(let d): return "SteamCMD install failed: \(d)"
            case .installTimeout:   return "SteamCMD install timed out (2 hours)"
            }
        }
    }
}

// MARK: - Thread-Safe Line Buffer

/// Accumulates text from the SteamCMD reader task; split into lines and read by the main loop.
private actor LineBuffer {
    private var pending = ""

    func append(_ str: String) {
        pending += str
    }

    func takeAll() -> [String] {
        guard !pending.isEmpty else { return [] }
        let lines = pending.components(separatedBy: .newlines)
        // Keep any incomplete final fragment (no trailing newline yet)
        if pending.hasSuffix("\n") {
            pending = ""
            return lines.filter { !$0.isEmpty }
        } else {
            pending = lines.last ?? ""
            return Array(lines.dropLast()).filter { !$0.isEmpty }
        }
    }
}
