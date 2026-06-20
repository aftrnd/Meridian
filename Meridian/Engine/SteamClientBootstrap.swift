import Foundation
import CryptoKit

private let log = MeridianLog(category: "SteamClientBootstrap")

/// Downloads and installs the Steam client packages using native macOS networking.
///
/// Steam's CDN serves a VDF manifest listing ~20 zip packages (~470 MB total).
/// Each package extracts directly into the Steam install directory. After extraction,
/// `steamui.dll` is present and Steam is fully bootstrapped.
///
/// **Why the WIN64 manifest (CLI-verified 2026-06-18):** Meridian's engine is
/// 64-bit Wine. The previous code fetched the `steam_client_win32` manifest, whose
/// `steam_win32_steamrow` package contains a **32-bit** `steam.exe` (PE32, 4.7 MB).
/// That 32-bit bootstrapper reports Windows 8 (6.2.9200) and its in-Wine HTTPS
/// stack fails every client-update fetch with `http error 0`, so `steam.exe -silent`
/// could never reach `[Logged On,` and exited 255 in a wipe→retry loop. The
/// `steam_client_win64` manifest's `steam_win64_steamrow` package contains the
/// **64-bit** `steam.exe` (PE32+, 5.8 MB) which reports Windows 10, requests the
/// correct `steam_client_win64` manifest, and downloads/authenticates correctly
/// — byte-identical to a working CrossOver bottle's steam.exe. Both 32- and
/// 64-bit binaries declare the Win10 manifest GUID, so this is NOT a manifest /
/// version-clamp issue: it is purely the bootstrapper binary's bitness/networking.
struct SteamClientBootstrap {

    // cdn.akamai.steamstatic.com is tried first — confirmed working with ATS on macOS 26.
    // cdn.steamstatic.com is the fallback (now also in NSExceptionDomains).
    static let manifestURLs: [URL] = [
        URL(string: "https://cdn.akamai.steamstatic.com/client/steam_client_win64")!,
        URL(string: "https://cdn.steamstatic.com/client/steam_client_win64")!,
    ]
    // SteamCMD has its own manifest. The bootstrapper stub (steamcmd.exe) ships without
    // steamconsole.dll and other required DLLs — they come from these packages, not from
    // the Steam client packages above. We download and extract them alongside the Steam
    // client to give steamcmd.exe everything it needs to start.
    static let steamCMDManifestURLs: [URL] = [
        URL(string: "https://cdn.akamai.steamstatic.com/client/steam_cmd_win32")!,
        URL(string: "https://cdn.steamstatic.com/client/steam_cmd_win32")!,
    ]
    static let cdnBases = [
        "https://cdn.akamai.steamstatic.com/client/",
        "https://cdn.steamstatic.com/client/",
    ]

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
                // Skip the outer realm wrapper ("win32"/"win64") — it is not a
                // downloadable package, just the top-level VDF key.
                if !name.isEmpty, name != "win32", name != "win64" {
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
        // Try manifest URLs in preference order; remember which CDN base succeeded.
        var manifestText: String?
        var activeCDNBase = cdnBases[0]
        var lastError: Error = BootstrapError.manifestDownloadFailed(statusCode: -1)
        for (index, url) in manifestURLs.enumerated() {
            log.info("[downloadAndInstall] fetching manifest from \(url.absoluteString)")
            do {
                let (manifestData, manifestResponse) = try await URLSession.shared.data(from: url)
                let httpStatus = (manifestResponse as? HTTPURLResponse)?.statusCode ?? -1
                guard httpStatus == 200 else {
                    log.warning("[downloadAndInstall] manifest HTTP \(httpStatus) from \(url.host ?? url.absoluteString) — trying next")
                    lastError = BootstrapError.manifestDownloadFailed(statusCode: httpStatus)
                    continue
                }
                guard let text = String(data: manifestData, encoding: .utf8) else {
                    log.warning("[downloadAndInstall] manifest not valid UTF-8 from \(url.host ?? url.absoluteString) — trying next")
                    lastError = BootstrapError.manifestParseFailed
                    continue
                }
                manifestText = text
                activeCDNBase = cdnBases[index]
                log.info("[downloadAndInstall] manifest downloaded from \(url.host ?? url.absoluteString): \(manifestData.count) bytes")
                break
            } catch {
                log.warning("[downloadAndInstall] manifest fetch failed from \(url.host ?? url.absoluteString): \(error.localizedDescription) — trying next")
                lastError = error
            }
        }
        guard let manifestText else {
            log.error("[downloadAndInstall] all manifest URLs failed — last error: \(lastError.localizedDescription)")
            throw lastError
        }

        // The win64 manifest's `steam_win64` block nests TWO bootstrapper
        // sub-packages: `steamrow` (global, the 64-bit steam.exe we want) and
        // `steamchina` (the China-realm steam.exe). Both declare
        // IsBootstrapperPackage and both ship a `steam.exe`. If the China
        // package extracts after the global one it OVERWRITES steam.exe with the
        // China build. Exclude any region-specific bootstrapper so the global
        // 64-bit steam.exe is the one that lands on disk.
        let packages = parseManifest(manifestText).filter {
            !$0.file.lowercased().contains("china")
        }
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

            let url = URL(string: activeCDNBase + pkg.file)!
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
        // Steam packages have two quirks that defeat standard tools:
        // 1. A 20-byte proprietary Valve header is prepended before the ZIP data.
        //    ditto -xk requires PK magic at byte 0 and fails.
        //    unzip / Python zipfile find the end-of-central-directory from the tail —
        //    handling the header transparently.
        // 2. ZIP entry paths use Windows backslash separators (e.g. "bin\cef\file").
        //    unzip on macOS/Unix treats backslash as a valid filename character, so it
        //    creates files with literal backslashes in their names rather than nested dirs.
        //    Python zipfile with explicit replacement converts paths correctly.
        let script = """
import zipfile, sys
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(src) as z:
    for info in z.infolist():
        info.filename = info.filename.replace('\\\\', '/')
        z.extract(info, dst)
"""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script, zipFile.path(percentEncoded: false), destination.path(percentEncoded: false)]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.availableData
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            log.error("[extractZip] python3 zipfile extract failed (\(process.terminationStatus)): \(errStr)")
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
        let manifestPath = packageDir.appending(path: "steam_client_win64.installed")
        try? content.write(to: manifestPath, atomically: true, encoding: .utf8)
        log.info("[writeInstalledManifest] wrote \(manifestPath.lastPathComponent)")
    }

    // MARK: - SteamCMD Package Download

    /// Downloads and extracts the SteamCMD packages (steam_cmd_win32 manifest) into installDir.
    ///
    /// The bootstrapper stub (steamcmd.exe from SteamSetup.exe) ships without steamconsole.dll
    /// and other required DLLs. These come from the steam_cmd_win32 manifest — a separate set
    /// of packages distinct from the Steam client. Without them, steamcmd crashes at startup
    /// with "Fatal Error: Failed to load steamconsole.dll" before it can self-update.
    ///
    /// The IsBootstrapperPackage entry (steamcmd_win32) is skipped — it's the same 2013 stub
    /// already installed by SteamSetup.exe.
    ///
    /// NOTE: As of the current architecture Meridian installs games via Steam IPC (steam.exe
    /// `+app_update`), not SteamCMD, so this is not wired into the bootstrap pipeline. It is
    /// retained verbatim from the proven original because it is self-contained and may be
    /// needed again if a SteamCMD path is reintroduced.
    static func downloadAndInstallSteamCMD(
        to installDir: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        var manifestText: String?
        var activeCDNBase = cdnBases[0]
        var lastError: Error = BootstrapError.manifestDownloadFailed(statusCode: -1)

        for (index, url) in steamCMDManifestURLs.enumerated() {
            log.info("[downloadAndInstallSteamCMD] fetching manifest from \(url.absoluteString)")
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status == 200, let text = String(data: data, encoding: .utf8) else {
                    lastError = BootstrapError.manifestDownloadFailed(statusCode: status)
                    continue
                }
                manifestText = text
                activeCDNBase = cdnBases[index]
                log.info("[downloadAndInstallSteamCMD] manifest from \(url.host ?? ""): \(data.count) bytes")
                break
            } catch {
                log.warning("[downloadAndInstallSteamCMD] \(url.host ?? ""): \(error.localizedDescription)")
                lastError = error
            }
        }
        guard let manifestText else { throw lastError }

        // Parse all packages — download all except the site server web UI (14MB of HTML/JS
        // for steamcmd's server management mode, irrelevant for game installs) and the
        // error reporter (crash reporting, not needed in our environment).
        // The bootstrapper package (steamcmd_win32) IS included — it contains the updated
        // steamcmd.exe (4.2MB) that replaces the 2013 stub from SteamSetup.exe.
        let allPkgs = parseManifest(manifestText)
        let packages = allPkgs.filter {
            !$0.name.contains("siteserverui") && !$0.name.contains("errorreporter")
        }

        guard !packages.isEmpty else {
            log.error("[downloadAndInstallSteamCMD] no packages found in manifest")
            throw BootstrapError.manifestParseFailed
        }

        let totalBytes = Int64(packages.reduce(0) { $0 + $1.size })
        log.info("[downloadAndInstallSteamCMD] \(packages.count) packages, \(totalBytes / 1_048_576) MB total")

        let fm = FileManager.default
        let packageDir = installDir.appending(path: "package")
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true)

        var downloadedBytes: Int64 = 0
        for (index, pkg) in packages.enumerated() {
            try Task.checkCancellation()
            let url = URL(string: activeCDNBase + pkg.file)!
            let localFile = packageDir.appending(path: pkg.file)

            if fm.fileExists(atPath: localFile.path(percentEncoded: false)),
               let attrs = try? fm.attributesOfItem(atPath: localFile.path(percentEncoded: false)),
               let sz = attrs[.size] as? Int, sz == pkg.size,
               verifySHA256(file: localFile, expected: pkg.sha256) {
                log.info("[downloadAndInstallSteamCMD] [\(index+1)/\(packages.count)] \(pkg.name) cached ✓")
                downloadedBytes += Int64(pkg.size)
                progress(downloadedBytes, totalBytes)
                continue
            }

            log.info("[downloadAndInstallSteamCMD] [\(index+1)/\(packages.count)] downloading \(pkg.name) (\(pkg.size / 1024)KB)")
            let (data, response) = try await URLSession.shared.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { throw BootstrapError.packageDownloadFailed(name: pkg.name, statusCode: status) }
            guard data.count == pkg.size else { throw BootstrapError.packageSizeMismatch(name: pkg.name, expected: pkg.size, actual: data.count) }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha == pkg.sha256 else { throw BootstrapError.packageHashMismatch(name: pkg.name) }
            try data.write(to: localFile)
            downloadedBytes += Int64(pkg.size)
            progress(downloadedBytes, totalBytes)
        }

        log.info("[downloadAndInstallSteamCMD] extracting SteamCMD packages")
        for pkg in packages {
            try Task.checkCancellation()
            let localFile = packageDir.appending(path: pkg.file)
            log.info("[downloadAndInstallSteamCMD] extracting \(pkg.name)")
            try extractZip(localFile, to: installDir)
        }

        let consolePath = installDir.appending(path: "steamconsole.dll").path(percentEncoded: false)
        let cmdPath = installDir.appending(path: "steamcmd.exe").path(percentEncoded: false)
        if fm.fileExists(atPath: consolePath) && fm.fileExists(atPath: cmdPath) {
            // Verify the new steamcmd.exe is larger than the 2013 stub (1.6MB)
            let size = (try? fm.attributesOfItem(atPath: cmdPath))?[.size] as? Int ?? 0
            if size > 2_000_000 {
                log.info("[downloadAndInstallSteamCMD] SteamCMD packages installed ✓ (steamcmd.exe=\(size/1024)KB, steamconsole.dll present)")
            } else {
                log.warning("[downloadAndInstallSteamCMD] steamcmd.exe appears to be old stub (\(size/1024)KB) — steamcmd_win32 package may not have extracted correctly")
            }
        } else {
            log.warning("[downloadAndInstallSteamCMD] steamconsole.dll or steamcmd.exe absent after extraction — SteamCMD may fail")
        }
    }

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
