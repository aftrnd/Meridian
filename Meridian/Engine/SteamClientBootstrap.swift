import Foundation
import CryptoKit

private let log = MeridianLog(category: "SteamClientBootstrap")

/// Downloads and installs the Steam client packages using native macOS networking,
/// bypassing steam.exe's 32-bit bootstrapper whose statically-linked OpenSSL
/// cannot complete TLS handshakes under WoW64 on macOS 26.
///
/// Steam's CDN serves a VDF manifest listing ~23 zip packages (~469 MB total).
/// Each package extracts directly into the Steam install directory. After extraction,
/// `steamui.dll` is present and Steam is fully bootstrapped.
struct SteamClientBootstrap {

    static let manifestURL = URL(string: "https://cdn.steamstatic.com/client/steam_client_win32")!
    static let cdnBase = "https://cdn.steamstatic.com/client/"

    // MARK: - Manifest Parsing

    struct Package {
        let name: String
        let file: String
        let size: Int
        let sha256: String
    }

    /// Parses the Steam client manifest VDF into a list of downloadable packages.
    static func parseManifest(_ text: String) -> [Package] {
        var packages: [Package] = []
        let lines = text.components(separatedBy: .newlines)

        var currentName: String?
        var currentFile: String?
        var currentSize: Int?
        var currentSHA: String?
        var inBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inBlock, trimmed.hasPrefix("\""), !trimmed.contains("\t") {
                let name = trimmed.replacingOccurrences(of: "\"", with: "")
                if !name.isEmpty, name != "win32" {
                    currentName = name
                }
                continue
            }

            if trimmed == "{" {
                if currentName != nil { inBlock = true }
                continue
            }

            if trimmed == "}" {
                if inBlock, let name = currentName, let file = currentFile,
                   let size = currentSize, let sha = currentSHA {
                    packages.append(Package(name: name, file: file, size: size, sha256: sha))
                }
                inBlock = false
                currentName = nil
                currentFile = nil
                currentSize = nil
                currentSHA = nil
                continue
            }

            if inBlock, let kv = vdfKeyValue(trimmed) {
                switch kv.key {
                case "file": currentFile = kv.value
                case "size": currentSize = Int(kv.value)
                case "sha2": currentSHA = kv.value
                default: break
                }
            }
        }

        return packages
    }

    private static func vdfKeyValue(_ line: String) -> (key: String, value: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let keyEnd = s.firstIndex(of: "\"") else { return nil }
        let key = String(s[s.startIndex..<keyEnd])
        s = String(s[s.index(after: keyEnd)...]).trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let valueEnd = s.firstIndex(of: "\"") else { return nil }
        let value = String(s[s.startIndex..<valueEnd])
        return (key, value)
    }

    // MARK: - Download & Extract

    /// Downloads and extracts all Steam client packages into the given directory.
    ///
    /// - Parameters:
    ///   - installDir: The Steam install directory (e.g. `prefix/drive_c/Program Files/Steam/`)
    ///   - progress: Called with (bytesDownloaded, totalBytes) for UI progress tracking
    /// - Throws: If manifest download, any package download, SHA verification, or extraction fails
    static func downloadAndInstall(
        to installDir: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        log.info("[downloadAndInstall] fetching manifest from \(manifestURL.absoluteString)")
        let (manifestData, manifestResponse) = try await URLSession.shared.data(from: manifestURL)
        let httpStatus = (manifestResponse as? HTTPURLResponse)?.statusCode ?? -1
        guard httpStatus == 200 else {
            log.error("[downloadAndInstall] manifest download failed: HTTP \(httpStatus)")
            throw BootstrapError.manifestDownloadFailed(statusCode: httpStatus)
        }
        guard let manifestText = String(data: manifestData, encoding: .utf8) else {
            log.error("[downloadAndInstall] manifest is not valid UTF-8")
            throw BootstrapError.manifestParseFailed
        }
        log.info("[downloadAndInstall] manifest downloaded: \(manifestData.count) bytes")

        let packages = parseManifest(manifestText)
        guard !packages.isEmpty else {
            log.error("[downloadAndInstall] manifest parsed but no packages found")
            throw BootstrapError.manifestParseFailed
        }

        let totalBytes = Int64(packages.reduce(0) { $0 + $1.size })
        log.info("[downloadAndInstall] \(packages.count) packages, \(totalBytes / 1_048_576) MB total")

        let fm = FileManager.default
        let packageDir = installDir.appending(path: "package")
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)

        var downloadedBytes: Int64 = 0

        for (index, pkg) in packages.enumerated() {
            try Task.checkCancellation()

            let url = URL(string: cdnBase + pkg.file)!
            log.info("[downloadAndInstall] [\(index + 1)/\(packages.count)] \(pkg.name) (\(pkg.size / 1024)KB)")

            let localFile = packageDir.appending(path: pkg.file)

            if fm.fileExists(atPath: localFile.path(percentEncoded: false)),
               let attrs = try? fm.attributesOfItem(atPath: localFile.path(percentEncoded: false)),
               let fileSize = attrs[.size] as? Int, fileSize == pkg.size,
               verifySHA256(file: localFile, expected: pkg.sha256) {
                log.info("[downloadAndInstall]   cached — SHA OK, skipping download")
                downloadedBytes += Int64(pkg.size)
                progress(downloadedBytes, totalBytes)
                continue
            }

            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                log.error("[downloadAndInstall] \(pkg.name) download failed: HTTP \(status)")
                throw BootstrapError.packageDownloadFailed(name: pkg.name, statusCode: status)
            }
            guard data.count == pkg.size else {
                log.error("[downloadAndInstall] \(pkg.name) size mismatch: expected \(pkg.size), got \(data.count)")
                throw BootstrapError.packageSizeMismatch(name: pkg.name, expected: pkg.size, actual: data.count)
            }

            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == pkg.sha256 else {
                log.error("[downloadAndInstall] \(pkg.name) SHA mismatch: expected \(pkg.sha256), got \(sha)")
                throw BootstrapError.packageHashMismatch(name: pkg.name)
            }

            try data.write(to: localFile)

            downloadedBytes += Int64(pkg.size)
            progress(downloadedBytes, totalBytes)
        }

        log.info("[downloadAndInstall] all packages downloaded — extracting")

        for (index, pkg) in packages.enumerated() {
            try Task.checkCancellation()

            let localFile = packageDir.appending(path: pkg.file)
            guard fm.fileExists(atPath: localFile.path(percentEncoded: false)) else {
                log.error("[downloadAndInstall] missing package file: \(pkg.file)")
                throw BootstrapError.packageMissing(name: pkg.name)
            }

            log.info("[downloadAndInstall] extracting [\(index + 1)/\(packages.count)] \(pkg.name)")
            try extractZip(localFile, to: installDir)
        }

        let steamuiPath = installDir.appending(path: "steamui.dll").path(percentEncoded: false)
        let altPath = installDir.appending(path: "SteamUI.dll").path(percentEncoded: false)
        guard fm.fileExists(atPath: steamuiPath) || fm.fileExists(atPath: altPath) else {
            log.error("[downloadAndInstall] steamui.dll not found after extraction")
            throw BootstrapError.steamuiMissing
        }

        log.info("[downloadAndInstall] Steam client bootstrap complete ✓")

        writeInstalledManifest(packages: packages, to: packageDir)
    }

    // MARK: - SHA Verification

    private static func verifySHA256(file: URL, expected: String) -> Bool {
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return hash == expected
    }

    // MARK: - Zip Extraction

    private static func extractZip(_ zipFile: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-xk", zipFile.path(percentEncoded: false), destination.path(percentEncoded: false)]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            log.error("[extractZip] ditto failed (\(process.terminationStatus)): \(errStr)")
            throw BootstrapError.extractionFailed(file: zipFile.lastPathComponent, exitCode: process.terminationStatus)
        }
    }

    // MARK: - Installed Manifest

    /// Writes a simple installed manifest so Steam's bootstrapper recognizes the client as installed.
    private static func writeInstalledManifest(packages: [Package], to packageDir: URL) {
        var lines: [String] = []
        for pkg in packages {
            lines.append("\(pkg.file)\t\(pkg.size)")
        }
        let content = lines.joined(separator: "\n") + "\n"
        let manifestPath = packageDir.appending(path: "steam_client_win32.installed")
        try? content.write(to: manifestPath, atomically: true, encoding: .utf8)
        log.info("[writeInstalledManifest] wrote \(manifestPath.lastPathComponent)")
    }

    // MARK: - Errors

    enum BootstrapError: LocalizedError {
        case manifestDownloadFailed(statusCode: Int)
        case manifestParseFailed
        case packageDownloadFailed(name: String, statusCode: Int)
        case packageSizeMismatch(name: String, expected: Int, actual: Int)
        case packageHashMismatch(name: String)
        case packageMissing(name: String)
        case extractionFailed(file: String, exitCode: Int32)
        case steamuiMissing

        var errorDescription: String? {
            switch self {
            case .manifestDownloadFailed(let code):
                return "Failed to download Steam manifest (HTTP \(code))"
            case .manifestParseFailed:
                return "Failed to parse Steam client manifest"
            case .packageDownloadFailed(let name, let code):
                return "Failed to download \(name) (HTTP \(code))"
            case .packageSizeMismatch(let name, let expected, let actual):
                return "\(name) size mismatch: expected \(expected), got \(actual)"
            case .packageHashMismatch(let name):
                return "\(name) SHA-256 verification failed"
            case .packageMissing(let name):
                return "Package file missing: \(name)"
            case .extractionFailed(let file, let code):
                return "Failed to extract \(file) (exit \(code))"
            case .steamuiMissing:
                return "steamui.dll not found after extracting all packages"
            }
        }
    }
}
