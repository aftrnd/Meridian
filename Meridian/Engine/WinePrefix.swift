import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "WinePrefix")

/// Manages a Wine prefix (bottle) on disk.
///
/// A prefix is the isolated Windows environment that Wine uses. It contains:
///   - drive_c/        — the virtual C:\ drive
///   - system.reg      — HKEY_LOCAL_MACHINE registry
///   - user.reg        — HKEY_CURRENT_USER registry
///   - dosdevices/     — drive letter symlinks
///
/// Meridian uses a single shared prefix for Steam and all games:
///   ~/Library/Application Support/com.meridian.app/bottles/steam/
///
/// This is the correct approach because Steam manages game installations
/// within its own library folders. Per-game prefixes would each need their
/// own Steam install, wasting disk space.
struct WinePrefix: Sendable {

    let path: URL

    static let defaultPrefix: WinePrefix = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appending(path: "com.meridian.app/bottles/steam", directoryHint: .isDirectory)
        return WinePrefix(path: dir)
    }()

    // MARK: - Computed Paths

    var driveC: URL {
        path.appending(path: "drive_c")
    }

    var steamInstallDir: URL {
        driveC.appending(path: "Program Files (x86)/Steam")
    }

    var steamExePath: URL {
        steamInstallDir.appending(path: "steam.exe")
    }

    var steamConfigDir: URL {
        steamInstallDir.appending(path: "config")
    }

    // MARK: - State Checks

    var exists: Bool {
        let regPath = path.appending(path: "system.reg").path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: regPath)
        log.debug("[exists] system.reg at \(regPath) → \(result)")
        return result
    }

    var isSteamInstalled: Bool {
        let exePath = steamExePath.path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: exePath)
        log.debug("[isSteamInstalled] \(exePath) → \(result)")
        return result
    }

    // MARK: - Prefix Lifecycle

    /// Initializes a new Wine prefix by running `wineboot`.
    func create(engine: WineEngine) async throws {
        let fm = FileManager.default
        log.info("[create] prefix path=\(path.path(percentEncoded: false))")

        do {
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
            log.info("[create] directory created")
        } catch {
            log.error("[create] failed to create directory: \(error.localizedDescription)")
            throw error
        }

        let process = try await engine.run(args: ["wineboot", "--init"], prefix: self)

        guard process.terminationStatus == 0 else {
            log.error("[create] wineboot --init failed with exit \(process.terminationStatus)")
            throw PrefixError.createFailed(exitCode: process.terminationStatus)
        }

        log.info("[create] prefix created ✓ | system.reg exists=\(fm.fileExists(atPath: path.appending(path: "system.reg").path(percentEncoded: false)))")
    }

    /// Downloads SteamSetup.exe from Valve and installs it into the prefix.
    func installSteam(engine: WineEngine) async throws {
        let setupURL = URL(string: "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe")!
        let tempFile = FileManager.default.temporaryDirectory.appending(path: "SteamSetup.exe")

        log.info("[installSteam] downloading from \(setupURL.absoluteString)")

        let (data, response) = try await URLSession.shared.data(from: setupURL)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        log.info("[installSteam] HTTP \(statusCode) | size=\(data.count) bytes")

        guard statusCode == 200 else {
            log.error("[installSteam] download failed: HTTP \(statusCode)")
            throw PrefixError.steamDownloadFailed(statusCode: statusCode)
        }

        do {
            try data.write(to: tempFile)
            log.info("[installSteam] saved SteamSetup.exe to \(tempFile.path(percentEncoded: false))")
        } catch {
            log.error("[installSteam] failed to write SteamSetup.exe: \(error.localizedDescription)")
            throw error
        }

        log.info("[installSteam] running SteamSetup.exe /S in Wine")
        let process = try await engine.run(
            args: [tempFile.path(percentEncoded: false), "/S"],
            prefix: self
        )

        try? FileManager.default.removeItem(at: tempFile)

        let exitCode = process.terminationStatus
        log.info("[installSteam] installer exited with code \(exitCode)")

        // Windows silent installers (/S) commonly return exit code 1 even on success.
        // SteamSetup.exe also spawns a child process that completes the actual file
        // extraction after the parent exits — so steam.exe may not exist yet when
        // the Wine process returns. Poll until it appears (up to 90 seconds).
        if !isSteamInstalled {
            log.info("[installSteam] steam.exe not yet present — waiting for child installer (up to 90s)")
            var elapsed = 0
            while elapsed < 90 {
                try await Task.sleep(for: .seconds(2))
                elapsed += 2
                if isSteamInstalled {
                    log.info("[installSteam] steam.exe appeared after ~\(elapsed)s ✓")
                    break
                }
                log.debug("[installSteam] waiting… \(elapsed)s elapsed")
            }
        }

        guard isSteamInstalled else {
            log.error("[installSteam] FAILED: steam.exe not found after 90s | exit=\(exitCode) | path=\(steamExePath.path(percentEncoded: false))")
            throw PrefixError.steamInstallFailed(exitCode: exitCode)
        }

        log.info("[installSteam] Steam install complete ✓")
    }

    /// Copies Steam session files from the macOS Steam install into this prefix
    /// to enable auto-login without credentials.
    func copySessionFiles(from macSteamDir: URL) -> Bool {
        let fm = FileManager.default
        let files: [(src: String, dst: String)] = [
            ("config/loginusers.vdf", "config/loginusers.vdf"),
            ("config/config.vdf",     "config/config.vdf"),
            ("registry.vdf",          "registry.vdf"),
        ]

        let steamDir = steamInstallDir
        log.info("[copySession] from=\(macSteamDir.path(percentEncoded: false)) → \(steamDir.path(percentEncoded: false))")

        do {
            try fm.createDirectory(at: steamDir.appending(path: "config"), withIntermediateDirectories: true)
        } catch {
            log.error("[copySession] failed to create config dir: \(error.localizedDescription)")
            return false
        }

        var copiedCount = 0
        var failedCount = 0

        for (src, dst) in files {
            let source = macSteamDir.appending(path: src)
            let destination = steamDir.appending(path: dst)
            guard fm.fileExists(atPath: source.path(percentEncoded: false)) else {
                log.debug("[copySession] skip \(src) — not found")
                continue
            }

            do {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: source, to: destination)
                copiedCount += 1
                log.info("[copySession] copied \(src)")
            } catch {
                failedCount += 1
                log.error("[copySession] FAILED to copy \(src): \(error.localizedDescription)")
            }
        }

        // Copy ssfn machine auth tokens
        var ssfnCount = 0
        if let children = try? fm.contentsOfDirectory(at: macSteamDir, includingPropertiesForKeys: nil) {
            for token in children where token.lastPathComponent.hasPrefix("ssfn") {
                let destination = steamDir.appending(path: token.lastPathComponent)
                do {
                    try? fm.removeItem(at: destination)
                    try fm.copyItem(at: token, to: destination)
                    ssfnCount += 1
                    log.info("[copySession] copied \(token.lastPathComponent)")
                } catch {
                    failedCount += 1
                    log.error("[copySession] FAILED to copy \(token.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }

        log.info("[copySession] done: copied=\(copiedCount) ssfn=\(ssfnCount) failed=\(failedCount)")
        return copiedCount > 0 || ssfnCount > 0
    }

    // MARK: - Steam Library Folders

    /// All Steam library folders configured in this prefix, including the default one.
    ///
    /// Parses `steamapps/libraryfolders.vdf` (both the legacy numeric-key format
    /// and the current nested `"path"` format) to discover any additional libraries
    /// the user may have configured inside Steam. Falls back to just the default
    /// `steamInstallDir` if the file is absent or unreadable.
    var steamLibraryFolders: [URL] {
        var libraries: [URL] = [steamInstallDir]

        let vdfURL = steamInstallDir.appending(path: "steamapps/libraryfolders.vdf")
        guard let contents = try? String(contentsOfFile: vdfURL.path(percentEncoded: false), encoding: .utf8) else {
            return libraries
        }

        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = vdfKeyValue(from: line), !value.isEmpty else { continue }

            // Accept both: "path" "<winpath>" (new) and "1" "<winpath>" (legacy numeric key)
            let isPathKey = key == "path"
            let isNumericNonZero = key != "0" && key.allSatisfy(\.isNumber)
            guard isPathKey || isNumericNonZero else { continue }

            // Value is a Windows path (e.g. "C:\\Program Files (x86)\\Steam") or
            // a Unix path on some configurations. Convert to a macOS URL.
            if let url = windowsPathToURL(value) {
                let canonical = url.standardizedFileURL.path(percentEncoded: false)
                let defaultCanonical = steamInstallDir.standardizedFileURL.path(percentEncoded: false)
                if canonical != defaultCanonical {
                    libraries.append(url)
                    log.info("[steamLibraryFolders] additional library: \(url.path(percentEncoded: false))")
                }
            }
        }

        return libraries
    }

    /// Returns the URL to the appmanifest ACF file for `appID`, searching every
    /// Steam library folder. Returns `nil` if the game is not installed anywhere.
    func acfURL(for appID: Int) -> URL? {
        let fm = FileManager.default
        for library in steamLibraryFolders {
            let candidate = library.appending(path: "steamapps/appmanifest_\(appID).acf")
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) {
                return candidate
            }
        }
        return nil
    }

    /// Checks whether a specific Steam game is installed by looking for its
    /// appmanifest ACF file across all configured Steam library folders.
    func isGameInstalled(appID: Int) -> Bool {
        let result = acfURL(for: appID) != nil
        log.debug("[isGameInstalled] appID=\(appID) → \(result)")
        return result
    }

    /// Reads the Steam appmanifest for a game and returns the `installdir` value.
    ///
    /// Searches all Steam library folders. The installdir is the folder name under
    /// `steamapps/common/` where the game is installed (e.g. "Animal Well"). This
    /// is used as a `pgrep -f` pattern to detect whether the game process is running.
    func gameInstallDir(appID: Int) -> String? {
        guard let manifest = acfURL(for: appID) else {
            log.warning("[gameInstallDir] ACF not found for appID=\(appID)")
            return nil
        }
        let manifestPath = manifest.path(percentEncoded: false)

        guard let contents = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
            log.warning("[gameInstallDir] cannot read manifest at \(manifestPath)")
            return nil
        }

        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line), key == "installdir", !value.isEmpty else { continue }
            log.info("[gameInstallDir] appID=\(appID) → \"\(value)\"")
            return value
        }

        log.warning("[gameInstallDir] 'installdir' not found in manifest for appID=\(appID)")
        return nil
    }

    // MARK: - VDF / Path Helpers

    /// Parses a single VDF line of the form `"key"\t"value"` and returns the pair.
    private func vdfKeyValue(from line: String) -> (key: String, value: String)? {
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

    /// Converts a Windows-style path from a VDF file to a macOS URL inside this prefix.
    ///
    /// - `C:\Program Files (x86)\Steam` → `prefix/drive_c/Program Files (x86)/Steam`
    /// - Other drives → resolved via `prefix/dosdevices/<letter>:` symlinks
    private func windowsPathToURL(_ windowsPath: String) -> URL? {
        let normalized = windowsPath
            .replacingOccurrences(of: "\\\\", with: "/")
            .replacingOccurrences(of: "\\", with: "/")

        guard normalized.count >= 3 else { return nil }
        let driveIdx = normalized.index(normalized.startIndex, offsetBy: 1)
        guard normalized[driveIdx] == ":" else {
            // Already a Unix path (some Steam configs store Unix paths directly)
            return URL(filePath: windowsPath)
        }

        let driveLetter = String(normalized.prefix(1)).lowercased()
        let afterDrive = normalized.index(normalized.startIndex, offsetBy: min(3, normalized.count))
        let remainingPath = String(normalized[afterDrive...])

        if driveLetter == "c" {
            return driveC.appending(path: remainingPath)
        }

        // Resolve the drive letter via dosdevices symlink
        let linkPath = path.appending(path: "dosdevices/\(driveLetter):").path(percentEncoded: false)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return nil
        }
        return URL(filePath: target).appending(path: remainingPath)
    }

    /// Deletes only the Steam install directory inside the prefix, leaving the
    /// Wine registry and wineboot state intact. Called automatically on retry
    /// after a failed Steam install or bootstrap so the next attempt starts
    /// from a verified-clean state rather than a partial directory.
    func resetSteamInstall() {
        let installPath = steamInstallDir.path(percentEncoded: false)
        log.info("[resetSteamInstall] removing \(installPath)")

        guard FileManager.default.fileExists(atPath: installPath) else {
            log.info("[resetSteamInstall] Steam dir does not exist — nothing to remove")
            return
        }

        do {
            try FileManager.default.removeItem(at: steamInstallDir)
            log.info("[resetSteamInstall] Steam install dir removed ✓")
        } catch {
            log.error("[resetSteamInstall] failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the entire prefix directory. Use when the prefix is corrupted
    /// or Steam install is in a bad state. A fresh prefix will be created
    /// on the next launch.
    func reset() {
        let prefixPath = path.path(percentEncoded: false)
        log.info("[reset] removing prefix at \(prefixPath)")

        guard FileManager.default.fileExists(atPath: prefixPath) else {
            log.info("[reset] prefix does not exist — nothing to remove")
            return
        }

        do {
            try FileManager.default.removeItem(at: path)
            log.info("[reset] prefix removed")
        } catch {
            log.error("[reset] failed to remove prefix: \(error.localizedDescription)")
        }
    }

    // MARK: - Errors

    enum PrefixError: LocalizedError {
        case createFailed(exitCode: Int32)
        case steamDownloadFailed(statusCode: Int)
        case steamInstallFailed(exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "Failed to create Wine prefix (wineboot exit \(code))."
            case .steamDownloadFailed(let code):
                return "Failed to download SteamSetup.exe (HTTP \(code))."
            case .steamInstallFailed(let code):
                return "Failed to install Steam (installer exit \(code))."
            }
        }
    }
}
