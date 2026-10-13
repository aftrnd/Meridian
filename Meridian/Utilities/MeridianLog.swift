import Foundation
import os.log

// MARK: - LogFileWriter

/// Thread-safe singleton that appends formatted, timestamped log lines to
/// `~/Library/Application Support/com.meridian.app/logs/meridian.log`.
///
/// At first access, the writer:
///   1. Creates `logs/` if absent.
///   2. Renames any existing `meridian.log` → `meridian-previous.log` (one generation).
///   3. Opens a fresh `meridian.log` for appending.
///   4. Writes a startup header with app version, OS, and environment info.
///
/// All file I/O runs on a dedicated serial queue so log calls from any thread
/// or actor are safe and never block the caller.
final class LogFileWriter: @unchecked Sendable {

    static let shared = LogFileWriter()

    // MARK: - Paths

    static let logsDir: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appending(path: "com.meridian.app/logs", directoryHint: .isDirectory)
    }()

    static var currentLogURL: URL {
        logsDir.appending(path: "meridian.log")
    }

    static var previousLogURL: URL {
        logsDir.appending(path: "meridian-previous.log")
    }

    // MARK: - Private

    private let queue = DispatchQueue(label: "com.meridian.app.log-writer", qos: .utility)
    private var fileHandle: FileHandle?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        f.timeZone = .current
        return f
    }()

    private init() {
        queue.async { [weak self] in self?.setup() }
    }

    private func setup() {
        let fm = FileManager.default
        let dir = Self.logsDir

        // 1. Ensure logs/ directory exists
        if !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let current = Self.currentLogURL
        let previous = Self.previousLogURL

        // 2. Rotate: current → previous (overwrite)
        if fm.fileExists(atPath: current.path(percentEncoded: false)) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }

        // 3. Create fresh log file
        fileHandle = Self.openLogFile()

        // 4. Write startup header
        writeHeader()
    }

    /// Opens `meridian.log` for appending, recreating it (and `logs/`) when
    /// it is gone.
    private static func openLogFile() -> FileHandle? {
        let fm = FileManager.default
        let path = currentLogURL.path(percentEncoded: false)
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: currentLogURL)
        _ = try? handle?.seekToEnd()
        return handle
    }

    private func writeHeader() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            var sysinfo = utsname()
            uname(&sysinfo)
            return withUnsafePointer(to: &sysinfo.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
            }
        }()
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first?.path(percentEncoded: false) ?? "?"

        let stamp = formatter.string(from: Date())
        let lines = [
            "================================================================================",
            "Meridian v\(version) (Build \(build))  —  started \(stamp)",
            "macOS \(osVersion) | \(arch)",
            "Application Support: \(appSupport)/com.meridian.app/",
            "Log: \(Self.currentLogURL.path(percentEncoded: false))",
            "================================================================================",
            "",
        ]
        for line in lines { appendRaw(line) }
    }

    // MARK: - Public

    func write(_ message: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let stamp = self.formatter.string(from: Date())
            self.appendRaw("\(stamp)  \(message)")
        }
    }

    /// Write a pre-formed line without a timestamp (used for the header).
    ///
    /// Uses the throwing `write(contentsOf:)`. The legacy `write(_:)` raises an
    /// Objective-C exception on any I/O error (disk full, file descriptor
    /// gone), which Swift cannot catch: one failed log line aborted the app
    /// right after "Verifying Wine environment…" (crash report, Oct 12 2026).
    /// A failed write reopens the file once; if that fails too, the line is
    /// dropped (the unified log still has it, along with the error).
    private func appendRaw(_ line: String) {
        let data = Data((line + "\n").utf8)
        do {
            try fileHandle?.write(contentsOf: data)
        } catch {
            Self.writeFailureLog.error("meridian.log write failed: \(error.localizedDescription, privacy: .public)")
            fileHandle = Self.openLogFile()
            try? fileHandle?.write(contentsOf: data)
        }
        // Synchronous flush on every write so the file is crash-safe.
        try? fileHandle?.synchronize()
    }

    private static let writeFailureLog = Logger(subsystem: "com.meridian.app", category: "LogFileWriter")
}

// MARK: - MeridianLog

/// Drop-in replacement for `os.Logger` that simultaneously writes to:
///   - The macOS unified log (via `os.Logger`, visible in Xcode console)
///   - The on-disk log file managed by `LogFileWriter`
///
/// Usage:
/// ```swift
/// private let log = MeridianLog(category: "WineSteamManager")
/// log.info("[startPersistent] pid=\(pid)")
/// log.error("[download] failed: \(error)")
/// ```
struct MeridianLog: Sendable {

    private let osLog: Logger
    private let category: String

    init(category: String) {
        self.osLog    = Logger(subsystem: "com.meridian.app", category: category)
        self.category = category
    }

    func info(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        LogFileWriter.shared.write("[INFO]  [\(category)] \(message)")
    }

    func debug(_ message: String) {
        osLog.debug("\(message, privacy: .public)")
        LogFileWriter.shared.write("[DEBUG] [\(category)] \(message)")
    }

    func warning(_ message: String) {
        osLog.warning("\(message, privacy: .public)")
        LogFileWriter.shared.write("[WARN]  [\(category)] \(message)")
    }

    func error(_ message: String) {
        osLog.error("\(message, privacy: .public)")
        LogFileWriter.shared.write("[ERROR] [\(category)] \(message)")
    }

    // Compatibility shim: some call sites use log.log(level:) via the OSLogType API.
    // Provide a minimal bridge so we don't have to touch every such call.
    func log(level: OSLogType, _ message: String) {
        switch level {
        case .debug:   debug(message)
        case .info:    info(message)
        case .error:   error(message)
        case .fault:   error(message)
        default:       info(message)
        }
    }
}
