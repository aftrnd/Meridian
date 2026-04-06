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

    /// Optional closure that provides the Keychain password for SteamCMD re-authentication.
    /// Set from MeridianApp at launch so expired credential caches can be auto-recovered.
    var passwordProvider: (() -> String?)?

    /// Prevents the re-authentication retry path from calling itself recursively.
    private var isRetrying: Bool = false

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
        prefix.stripBootStrapperInhibit()

        let process = Process()
        // PTY wrapper so SteamCMD self-update progress flushes in real-time.
        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", engine.wine64URL.path(percentEncoded: false),
                             steamcmdPath, "+login", savedUsername, "+quit"]
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
            try? prefix.ensureSteamCFG()
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
                    let clean = Self.stripAnsiEscapes(trimmed)
                    guard !clean.isEmpty else { continue }
                    log.info("[warmUp:out] \(clean)")
                    if Self.shouldShowLine(clean) {
                        await MainActor.run { onProgress(clean) }
                    }
                }
                break
            }

            let lines = await buffer.takeAll()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let clean = Self.stripAnsiEscapes(trimmed)
                guard !clean.isEmpty else { continue }
                log.info("[warmUp:out] \(clean)")
                if Self.shouldShowLine(clean) {
                    await MainActor.run { onProgress(clean) }
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        stderrTask.cancel()
        activeProcess = nil

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            log.info("[warmUp] complete ✓ (exit=0)")
            // Only backup when login succeeded — never overwrite a good credential
            // cache with a post-self-update file that has no credentials.
            prefix.backupSteamCMDConfig()
        } else {
            log.warning("[warmUp] exited with code \(exitCode) — preserving existing credential backup")
        }
        try? prefix.ensureSteamCFG()
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
        prefix.stripBootStrapperInhibit()

        let process = Process()
        // Wrap wine64 in a PTY using macOS `script -q /dev/null`.
        // SteamCMD buffers stdout in pipe mode (C stdlib full buffering when
        // stdout is not a TTY). Inside a PTY, SteamCMD sees a terminal and
        // switches to line buffering, flushing each progress line immediately.
        // Without this, all "Update state" lines arrive only at process exit.
        // This is a known Valve bug (open since 2014, unresolved as of 2026).
        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = [
            "-q", "/dev/null",
            engine.wine64URL.path(percentEncoded: false),
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
                    let clean = Self.stripAnsiEscapes(trimmed)
                    guard !clean.isEmpty else { continue }
                    log.info("[installGame:out] \(clean)")
                    if clean.contains("Success! App") { succeeded = true }
                    if clean.hasPrefix("ERROR!") || clean.contains("Login Failure") {
                        lastError = clean
                    }
                    let filtered = Self.shouldShowLine(clean)
                    if filtered { await MainActor.run { onProgress(clean) } }
                }
                break
            }

            let lines = await buffer.takeAll()
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let clean = Self.stripAnsiEscapes(trimmed)
                guard !clean.isEmpty else { continue }
                log.info("[installGame:out] \(clean)")

                if clean.contains("Success! App") { succeeded = true }
                if clean.hasPrefix("ERROR!") || clean.contains("Login Failure") {
                    lastError = clean
                }

                if Self.shouldShowLine(clean) {
                    await MainActor.run { onProgress(clean) }
                }
            }

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                // Task cancelled — terminate download cleanly rather than waiting for exit
                if process.isRunning { process.terminate() }
                activeProcess = nil
                try? prefix.ensureSteamCFG()
                state = .ready
                throw CancellationError()
            }
        }

        stderrTask.cancel()
        activeProcess = nil
        try? prefix.ensureSteamCFG()

        let exitCode = process.terminationStatus
        log.info("[installGame] appID=\(appID) exit=\(exitCode) succeeded=\(succeeded)")

        if let err = lastError {
            state = .ready
            throw ServiceError.installFailed(err)
        }

        // Login failure (exit=5 invalid password, exit=7 expired token) — try once
        // to re-authenticate using the Keychain password, then retry the install.
        if !succeeded && (exitCode == 5 || exitCode == 7) && !isRetrying {
            if let provider = passwordProvider, let password = provider() {
                log.warning("[installGame] login failed (exit=\(exitCode)) — re-authenticating with Keychain password")
                await MainActor.run { onProgress("Verifying your account — approve the Steam Guard notification on your phone…") }
                let authOK = await reauthenticate(password: password, engine: engine, prefix: prefix)
                if authOK {
                    log.info("[installGame] re-auth succeeded — retrying install")
                    await MainActor.run { onProgress("Account verified — starting download…") }
                    isRetrying = true
                    defer { isRetrying = false }
                    try await installGame(appID: appID, onProgress: onProgress)
                    return
                } else {
                    log.error("[installGame] re-auth failed — Steam Guard may have timed out")
                    state = .ready
                    throw ServiceError.installFailed(
                        "SteamCMD login failed — Steam Guard confirmation may have expired. "
                        + "Please try again and approve the notification on your phone."
                    )
                }
            } else {
                log.error("[installGame] login failed (exit=\(exitCode)) and no Keychain password available")
                state = .ready
                throw ServiceError.installFailed("Steam login expired. Sign out and sign back in through Settings.")
            }
        }

        if !succeeded && exitCode != 0 {
            state = .ready
            throw ServiceError.installFailed("SteamCMD exited \(exitCode) without success confirmation")
        }

        state = .ready
        log.info("[installGame] appID=\(appID) complete ✓")
        await MainActor.run { onProgress("Download complete ✓") }
    }

    // MARK: - Re-authentication

    /// Runs `steamcmd.exe +login USERNAME PASSWORD +quit` to rebuild the credential cache.
    ///
    /// Called when an install fails with exit=5/7 (login failure). SteamCMD's self-update
    /// can wipe its own credential cache from config.vdf, requiring a fresh password login
    /// to re-establish it.
    ///
    /// - Returns: `true` if SteamCMD accepted the credentials (exit=0).
    private func reauthenticate(password: String, engine: WineEngine, prefix: WinePrefix) async -> Bool {
        guard !savedUsername.isEmpty else { return false }

        let steamcmdPath = prefix.steamInstallDir
            .appending(path: "steamcmd.exe")
            .path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: steamcmdPath) else { return false }

        log.info("[reauthenticate] running +login \(savedUsername) <password> +quit")
        prefix.restoreSteamCMDConfig()
        prefix.stripBootStrapperInhibit()

        let process = Process()
        process.executableURL = engine.wine64URL
        process.arguments = [steamcmdPath, "+login", savedUsername, password, "+quit"]
        process.environment = engine.steamCMDEnvironment(for: prefix)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            log.error("[reauthenticate] failed to launch: \(error.localizedDescription)")
            return false
        }

        await Task.detached(priority: .utility) { process.waitUntilExit() }.value

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            prefix.backupSteamCMDConfig()
            try? prefix.ensureSteamCFG()
            log.info("[reauthenticate] succeeded ✓")
            return true
        } else {
            log.warning("[reauthenticate] failed exit=\(exitCode)")
            return false
        }
    }

    // MARK: - Shutdown
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

    /// Strips ANSI/VT100 escape sequences and bare control characters from PTY output.
    ///
    /// The `script -q /dev/null` PTY wrapper causes SteamCMD to emit cursor control
    /// sequences (`\u{1B}[?25l`, `\u{1B}[?25h`, etc.) on every line. These must be
    /// stripped before filtering or displaying lines.
    private static func stripAnsiEscapes(_ s: String) -> String {
        // Remove ESC [ ... <letter> sequences (cursor, color, erase)
        let pattern = "\u{1B}\\[[0-9;?]*[A-Za-z]"
        var result = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        // Remove bare ESC and non-printable control chars (keep tab)
        result = result.unicodeScalars
            .filter { $0.value >= 0x20 || $0.value == 0x09 }
            .map { Character($0) }
            .reduce(into: "") { $0.append($1) }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Returns true if this line should be forwarded to the UI progress callback.
    private static func shouldShowLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        // Wine fixme/err/warn noise
        if line.hasPrefix("wineserver:") || line.hasPrefix("wine:") { return false }
        if line.contains(":fixme:") || line.contains(":err:") || line.contains(":warn:") { return false }
        if line.hasPrefix("CWork") || line.hasPrefix("Redirecting stderr") { return false }
        if line.hasPrefix("Logging directory") { return false }
        if line.hasPrefix("Unloading Steam") || line.hasPrefix("Loading Steam") { return false }
        // MoltenVK Vulkan extension dump (153 lines per Wine launch)
        if line.hasPrefix("VK_") { return false }
        if line.hasPrefix("[mvk-") { return false }
        if line.contains("Vulkan extensions are supported") { return false }
        if line.contains("Vulkan extensions enabled") { return false }
        // GPU device info block emitted by MoltenVK
        if line.hasPrefix("model:") || line.hasPrefix("type:") { return false }
        if line.hasPrefix("vendorID:") || line.hasPrefix("deviceID:") { return false }
        if line.hasPrefix("pipelineCacheUUID:") { return false }
        if line.hasPrefix("GPU memory") || line.hasPrefix("Metal Shading Language") { return false }
        if line.hasPrefix("supports the following") || line.hasPrefix("GPU Family") { return false }
        if line.hasPrefix("Read-Write Texture") { return false }
        // SteamCMD session header noise
        if line.hasPrefix("-- type") || line.hasPrefix("Steam Console Client") { return false }
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
///
/// PTY output (from `script` wrapper) uses `\r\n` or bare `\r` (carriage return) instead of
/// `\n` alone — SteamCMD overwrites its progress bar in-place using `\r`. We normalise all
/// three line endings so each progress update becomes a separate line.
private actor LineBuffer {
    private var pending = ""

    func append(_ str: String) {
        // Normalise \r\n → \n, then bare \r → \n so takeAll() only needs to split on \n.
        let normalised = str
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r",   with: "\n")
        pending += normalised
    }

    func takeAll() -> [String] {
        guard !pending.isEmpty else { return [] }
        let lines = pending.components(separatedBy: "\n")
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
