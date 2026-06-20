import Foundation

private let log = MeridianLog(category: "DepotDownloader")

/// Headless owned-game installer driving Meridian's patched DepotDownloader fork.
///
/// DepotDownloader is a native macOS (arm64) binary — NOT a Wine process — that
/// authenticates with Meridian's OAuth `refresh_token` and downloads depot files
/// straight from Steam's CDN into `steamapps/common/<installDir>/`. No `steam.exe`,
/// no Steam UI, no windows or sounds.
///
/// This sidesteps the Pattern 6 wall: the same client-platform `refresh_token`
/// that Wine's `steam.exe` rejects with `Invalid Password` is accepted by
/// SteamKit2's logon path that DepotDownloader uses.
///
/// Proven invocation contract (see `Scripts/depotdownloader/README.md`):
/// ```
/// DepotDownloader -app <id> -os windows -osarch 64 \
///     -username <name> -refreshtoken <jwt> -json -dir <installDir>
/// ```
/// Exit codes: 0 ok · 1 usage · 3 REFRESH_TOKEN_INVALID · 130 SIGTERM (resume-safe).
enum DepotDownloaderInstall {

    // MARK: - NDJSON events

    /// One parsed line of the fork's `-json` stdout stream. Human-readable `%`
    /// progress lines (which do NOT start with `{`) parse to `nil` and are
    /// ignored by the caller.
    enum Event: Equatable {
        case phase(phase: String, detail: String)
        case progress(bytesDone: Int64, bytesTotal: Int64, pct: Double)
        case done(bytesDownloaded: Int64)
        case error(message: String)
    }

    /// Pure parser for a single stdout line. Returns `nil` for any line that is
    /// not a recognised Meridian-JSON object (including human `%` progress lines).
    ///
    /// Mirrored verbatim in `MeridianTests/DepotDownloaderInstallTests.swift` —
    /// keep the two in sync (testing-standards mirror contract).
    static func parse(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        switch type {
        case "phase":
            let phase = (obj["phase"] as? String) ?? ""
            let detail = (obj["detail"] as? String) ?? ""
            return .phase(phase: phase, detail: detail)
        case "progress":
            let done = intValue(obj["bytesDone"])
            let total = intValue(obj["bytesTotal"])
            let pct = doubleValue(obj["pct"])
            return .progress(bytesDone: done, bytesTotal: total, pct: pct)
        case "done":
            return .done(bytesDownloaded: intValue(obj["bytesDownloaded"]))
        case "error":
            return .error(message: (obj["message"] as? String) ?? "unknown error")
        default:
            return nil
        }
    }

    private static func intValue(_ any: Any?) -> Int64 {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? Double { return Int64(n) }
        if let s = any as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func doubleValue(_ any: Any?) -> Double {
        if let n = any as? Double { return n }
        if let n = any as? Int { return Double(n) }
        if let s = any as? String, let n = Double(s) { return n }
        return 0
    }

    // MARK: - Errors

    enum DDError: LocalizedError, Equatable {
        case launchFailed(String)
        /// Exit 3 — Valve rejected the refresh token. The user must re-authenticate.
        case refreshTokenInvalid
        /// Any other non-zero, non-cancel exit.
        case failed(exitCode: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .launchFailed(let m):
                return "Could not start the game installer: \(m)"
            case .refreshTokenInvalid:
                return "Your Steam session has expired. Please sign out and sign in again."
            case .failed(_, let m) where !m.isEmpty:
                return "Install failed: \(m)"
            case .failed(let code, _):
                return "Install failed (exit \(code))."
            }
        }
    }

    // MARK: - Run

    /// Downloads `appID` into `installDir` (a full path, typically
    /// `steamapps/common/<name>/`). Streams progress via the callbacks, which
    /// are invoked on the main actor.
    ///
    /// - Throws: `CancellationError` if the task is cancelled (the fork is sent
    ///   SIGTERM and exits 130, leaving a resume-safe `.DepotDownloader/` state);
    ///   `DDError.refreshTokenInvalid` on exit 3; `DDError.failed` otherwise.
    /// - Returns: total bytes downloaded (from the `done` event, 0 if absent).
    @discardableResult
    static func run(
        binary: URL,
        appID: Int,
        installDir: URL,
        username: String,
        refreshToken: String,
        onPhase: @MainActor @escaping (_ phase: String, _ detail: String) -> Void,
        onProgress: @MainActor @escaping (_ bytesDone: Int64, _ bytesTotal: Int64, _ pct: Double) -> Void
    ) async throws -> Int64 {

        let fm = FileManager.default
        try fm.createDirectory(at: installDir, withIntermediateDirectories: true)

        let dirPath = installDir.path(percentEncoded: false)

        let process = Process()
        process.executableURL = binary
        // -os windows -osarch 64 is REQUIRED: DepotDownloader defaults to the
        // host OS (macOS) otherwise and would fetch the wrong (or no) depots.
        process.arguments = [
            "-app", "\(appID)",
            "-os", "windows",
            "-osarch", "64",
            "-username", username,
            "-refreshtoken", refreshToken,
            "-json",
            "-dir", dirPath,
        ]
        // Resume state (`.DepotDownloader/depot.config`) lands in the install dir.
        process.currentDirectoryURL = installDir
        // Inherit the parent environment (PATH/HOME). No Wine env — this is a
        // native macOS binary, not a Wine process.

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        log.info("[run] appID=\(appID) → \(dirPath)")

        // Drain stderr concurrently into a bounded ring buffer. If we only read
        // stdout, a full stderr pipe (64 KB) would block the process's stderr
        // writes, which would in turn stall stdout → deadlock. Keep the last
        // ~40 lines for diagnostics.
        let errCollector = LineRing(capacity: 40)
        let errHandle = errPipe.fileHandleForReading
        let errTask = Task.detached {
            for try await line in errHandle.bytes.lines {
                await errCollector.append(line)
            }
        }

        var doneBytes: Int64 = 0
        var jsonError: String?

        do {
            try process.run()
        } catch {
            errTask.cancel()
            throw DDError.launchFailed(error.localizedDescription)
        }

        let outHandle = outPipe.fileHandleForReading

        // Read stdout INCREMENTALLY via readabilityHandler, NOT
        // `FileHandle.bytes.lines`. CLI-verified 2026-06-19: the fork streams
        // NDJSON line-by-line to a pipe in real time (a bash `while read`
        // reader sees each `phase`/`progress` line as it is written), but
        // `FileHandle.bytes.lines` does not yield those lines until the pipe
        // reaches EOF (process exit). The symptom was a download that ran and
        // completed correctly on disk while the UI sat at "Resuming download…"
        // with zero progress, then dumped every buffered event at once the
        // instant the process was terminated. readabilityHandler fires as data
        // becomes readable, so progress reaches the UI live.
        await withTaskCancellationHandler {
            for await line in Self.lineStream(from: outHandle) {
                guard let event = parse(line) else { continue }
                switch event {
                case .phase(let phase, let detail):
                    log.info("[run] phase=\(phase)\(detail.isEmpty ? "" : " detail=\(detail)")")
                    await onPhase(phase, detail)
                case .progress(let d, let t, let p):
                    await onProgress(d, t, p)
                case .done(let b):
                    doneBytes = b
                    log.info("[run] done bytesDownloaded=\(b)")
                case .error(let m):
                    jsonError = m
                    log.error("[run] fork reported error: \(m)")
                }
            }
        } onCancel: {
            // SIGTERM → the fork's signal handler exits 130 deterministically,
            // leaving a resume-safe partial download.
            process.terminate()
        }

        process.waitUntilExit()
        _ = try? await errTask.value
        let code = process.terminationStatus
        let errTail = await errCollector.joined()

        // A cancelled task wins regardless of the reported exit code.
        if Task.isCancelled {
            log.info("[run] cancelled (exit=\(code)) — partial download is resume-safe")
            throw CancellationError()
        }

        outHandle.readabilityHandler = nil

        switch code {
        case 0:
            log.info("[run] ✓ install complete appID=\(appID) bytes=\(doneBytes)")
            return doneBytes
        case 3:
            log.error("[run] REFRESH_TOKEN_INVALID appID=\(appID)")
            throw DDError.refreshTokenInvalid
        default:
            let message = jsonError ?? errTail
            log.error("[run] failed appID=\(appID) exit=\(code) message=\(message)")
            throw DDError.failed(exitCode: code, message: message)
        }
    }

    /// Streams newline-delimited lines from a pipe's read handle in REAL TIME.
    ///
    /// Uses `readabilityHandler` (fires on a background dispatch source the
    /// moment bytes are readable) rather than `FileHandle.bytes.lines`, which
    /// buffers a subprocess pipe until EOF and so delivers nothing until the
    /// process exits (CLI-verified 2026-06-19 — the cause of the silent
    /// no-progress install). Partial lines are held in `buffer` across reads;
    /// on EOF (empty `availableData`) any trailing partial line is flushed and
    /// the stream finishes. The handler reads only when the dispatch source
    /// signals readable, so it never blocks the way a bare `availableData`
    /// loop can on a still-open pipe (engine-research-findings.mdc Pattern 1).
    private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
        // The buffer lives in a reference box mutated ONLY from the serial
        // readability dispatch queue, so concurrent access is impossible —
        // hence the `@unchecked Sendable`. A captured local `var` would be
        // rejected by StrictConcurrency in the `@Sendable` readabilityHandler.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        return AsyncStream { continuation in
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    if !box.data.isEmpty, let trailing = String(data: box.data, encoding: .utf8) {
                        continuation.yield(trailing)
                    }
                    fh.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                box.data.append(chunk)
                while let nl = box.data.firstIndex(of: 0x0A) {
                    let lineData = box.data[box.data.startIndex..<nl]
                    if let line = String(data: lineData, encoding: .utf8) {
                        continuation.yield(line)
                    }
                    box.data.removeSubrange(box.data.startIndex...nl)
                }
            }
            // No onTermination handler: `run()` nils the readabilityHandler
            // after the consume loop, and cancellation routes through the
            // task's onCancel (which terminates the process → pipe EOF → the
            // handler finishes the stream and detaches itself above). Capturing
            // `handle` here would be a StrictConcurrency violation (FileHandle
            // is non-Sendable, onTermination is @Sendable).
        }
    }
}

/// Tiny fixed-capacity line buffer for capturing the tail of a process's stderr.
private actor LineRing {
    private var lines: [String] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    func append(_ line: String) {
        lines.append(line)
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
    }

    func joined() -> String { lines.joined(separator: "\n") }
}
