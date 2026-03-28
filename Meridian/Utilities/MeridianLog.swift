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
        fm.createFile(atPath: current.path(percentEncoded: false), contents: nil)
        fileHandle = try? FileHandle(forWritingTo: current)
        fileHandle?.seekToEndOfFile()

        // 4. Write startup header
        writeHeader()
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
    private func appendRaw(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        fileHandle?.write(data)
        // Synchronous flush on every write so the file is crash-safe.
        try? fileHandle?.synchronize()
    }
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
