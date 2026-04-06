import Foundation
import os.log

private let log = MeridianLog(category: "WinePrefix")

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

    /// The directory where Steam is installed inside this prefix.
    ///
    /// Valve's SteamSetup.exe historically installed to `Program Files (x86)\Steam`
    /// via WoW64 filesystem redirection (32-bit apps redirected from `Program Files`).
    /// With wine-staging 11.5 that redirection is no longer applied, so the installer
    /// writes to the native `Program Files\Steam` instead.
    ///
    /// This property detects the actual install path at runtime by checking which
    /// location contains a Steam executable. Falls back to the x86 path when Steam
    /// is not yet installed (used for pre-install writes like steam.cfg).
    var steamInstallDir: URL {
        let x64 = driveC.appending(path: "Program Files/Steam")
        let x86 = driveC.appending(path: "Program Files (x86)/Steam")
        // macOS APFS is case-insensitive, so this matches both "steam.exe" and "Steam.exe"
        if FileManager.default.fileExists(atPath: x64.appending(path: "steam.exe").path(percentEncoded: false)) {
            return x64
        }
        return x86
    }

    var steamExePath: URL {
        steamInstallDir.appending(path: "steam.exe")
    }

    /// The Windows path to steam.exe as seen inside Wine (C:\ drive).
    ///
    /// Derived from the actual install location detected by `steamInstallDir`. Must use
    /// a Windows-style path — explorer.exe does not translate Unix paths for child
    /// processes, so Steam would receive a macOS path as argv[0] and exit immediately.
    var steamExeWindowsPath: String {
        let isX86 = steamInstallDir.path(percentEncoded: false).contains("Program Files (x86)")
        if isX86 {
            return "C:\\Program Files (x86)\\Steam\\steam.exe"
        }
        return "C:\\Program Files\\Steam\\steam.exe"
    }

    var steamConfigDir: URL {
        steamInstallDir.appending(path: "config")
    }

    // MARK: - State Checks

    var exists: Bool {
        let regPath = path.appending(path: "system.reg").path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: regPath)
        log.debug("[exists] system.reg at \(regPath) → \(result)")
        if result {
            let prefixRoot = path.path(percentEncoded: false)
            let topLevel = (try? FileManager.default.contentsOfDirectory(atPath: prefixRoot)) ?? []
            log.debug("[exists] prefix root contents: \(topLevel.sorted().joined(separator: ", "))")
        }
        return result
    }

    var isSteamInstalled: Bool {
        let exePath = steamExePath.path(percentEncoded: false)
        let result = FileManager.default.fileExists(atPath: exePath)
        log.debug("[isSteamInstalled] steam.exe → \(result)")
        log.debug("[isSteamInstalled] steamui.dll → \(isSteamBootstrapped) (bootstrap complete=\(isSteamBootstrapped))")
        return result
    }

    /// Whether Steam's first-run client download has completed.
    ///
    /// `SteamSetup.exe /S` installs only the bootstrapper stub (steam.exe).
    /// The full client (including steamui.dll) is downloaded when steam.exe
    /// runs for the first time without `BootStrapperInhibitAll`. This property
    /// distinguishes "Steam stub installed" from "Steam fully bootstrapped".
    var isSteamBootstrapped: Bool {
        let dllPath = steamInstallDir.appending(path: "steamui.dll").path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: dllPath)
    }

    /// Returns `true` when the Wine prefix's Steam install has an authenticated user
    /// with `MostRecent "1"` recorded in `config/loginusers.vdf`.
    ///
    /// Steam writes this entry after a successful login and it persists across
    /// restarts. A missing or empty `loginusers.vdf` — or one with no
    /// `"MostRecent" "1"` block — means the user has never logged into the
    /// Windows Steam client inside this prefix.
    func hasSteamLoginSession() -> Bool {
        let vdfURL = steamConfigDir.appending(path: "loginusers.vdf")
        let vdfPath = vdfURL.path(percentEncoded: false)
        guard let content = try? String(contentsOfFile: vdfPath, encoding: .utf8) else {
            log.debug("[hasSteamLoginSession] loginusers.vdf not found at \(vdfPath)")
            return false
        }
        // Line-level check: "MostRecent" and "1" must appear on the SAME line.
        // The old global `contains("\"1\"")` check false-positived on RememberPassword "1".
        let hasMostRecent = content.components(separatedBy: .newlines).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.contains("\"MostRecent\"") && t.contains("\"1\"")
        }
        log.debug("[hasSteamLoginSession] loginusers.vdf found, hasMostRecent=\(hasMostRecent)")
        return hasMostRecent
    }

    // MARK: - Prefix Lifecycle

    /// Creates a new Wine prefix.
    ///
    /// If the engine archive includes a `prefix-template/` directory (produced by
    /// `release-engine.sh` running `wineboot --init` on the build machine), the
    /// prefix is created by **copying the template** — an instant file operation.
    /// The template is complete: DLLs, registry, and driver stubs are all baked in.
    /// Wine auto-detects the Mac display driver at runtime from winemac.so in the
    /// engine's WINEDLLPATH — no `wineboot --update` is needed on the user's machine.
    /// Instant template copy — zero Wine process overhead on first run.
    ///
    /// Falls back to `wineboot --init` if no template is found (backwards compatibility
    /// with older engine releases that predate the template packaging).
    func create(engine: WineEngine) async throws {
        let fm = FileManager.default
        let prefixPath = path.path(percentEncoded: false)
        log.info("[create] prefix path=\(prefixPath)")

        // Prefer the pre-built template if the engine ships one.
        let templateURL = WineEngine.engineDir.appending(path: "prefix-template")
        if fm.fileExists(atPath: templateURL.path(percentEncoded: false)) {
            log.info("[create] pre-built template found — copying (fast path)")
            do {
                // Ensure the parent directory (e.g. .../bottles/) exists before copying.
                // FileManager.copyItem does not create intermediate directories.
                try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: templateURL, to: path)
                // Recreate the dosdevices directory with the correct symlinks for this machine.
                // The template ships without dosdevices (they point to the build machine's paths).
                let dosdev = path.appending(path: "dosdevices")
                try? fm.removeItem(at: dosdev)
                try fm.createDirectory(at: dosdev, withIntermediateDirectories: true)
                // c: → ../drive_c (relative symlink, portable across machines)
                try fm.createSymbolicLink(
                    atPath: dosdev.appending(path: "c:").path(percentEncoded: false),
                    withDestinationPath: "../drive_c"
                )
                // z: → / maps the entire Unix filesystem as the Z: drive.
                // This is REQUIRED — without it Wine cannot resolve host-filesystem
                // paths (e.g. /var/folders/.../SteamSetup.exe) and crashes with SIGSEGV
                // on startup. Every standard Wine prefix has this mapping.
                try fm.createSymbolicLink(
                    atPath: dosdev.appending(path: "z:").path(percentEncoded: false),
                    withDestinationPath: "/"
                )
                // Populate syswow64 with 32-bit DLLs from the engine.
                //
                // Some Wine versions leave syswow64 empty after wineboot --init; others
                // do not create the directory at all. Either way we must
                // create it and fill it ourselves from the engine's i386-windows/ directory.
                // Without the 32-bit builtins, Wine's WoW64 layer cannot load 32-bit
                // Windows executables (like SteamSetup.exe) and crashes with
                // STATUS_DLL_NOT_FOUND (c0000135 / exit 53) when trying to find kernel32.dll.
                //
                // ALL PE file types must be copied — not just .dll. Critical drivers
                // like winemac.drv (Mac display driver) are .drv files. If they are
                // missing from syswow64, 32-bit processes cannot create windows and
                // exit with code 152 ("nodrv_CreateWindow").
                let i386Src = WineEngine.engineDir.appending(path: "wine/lib/wine/i386-windows")
                let syswow64 = path.appending(path: "drive_c/windows/syswow64")
                if fm.fileExists(atPath: i386Src.path(percentEncoded: false)) {
                    try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
                    let i386Files = (try? fm.contentsOfDirectory(atPath: i386Src.path(percentEncoded: false))) ?? []
                    var wow64Copied = 0
                    for file in i386Files where Self.isWoW64FileType(file) {
                        let dest = syswow64.appending(path: file)
                        guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
                        try? fm.copyItem(at: i386Src.appending(path: file), to: dest)
                        wow64Copied += 1
                    }
                    log.info("[create] populated syswow64 with \(wow64Copied) 32-bit files for WoW64")
                } else {
                    log.warning("[create] i386-windows not found in engine — WoW64 (32-bit apps) may fail")
                }

                let dllCount = (try? fm.contentsOfDirectory(atPath: path.appending(path: "drive_c/windows/system32").path(percentEncoded: false)))?.filter { $0.hasSuffix(".dll") }.count ?? 0
                log.info("[create] prefix created from template ✓ | DLLs in system32=\(dllCount)")
                // No wineboot --update here. The template built by release-engine.sh is
                // complete (DLLs, registry, driver stubs). Wine auto-detects the Mac
                // display driver at runtime from winemac.so in the engine's WINEDLLPATH.
            } catch {
                log.error("[create] template copy failed: \(error.localizedDescription) — falling back to wineboot --init")
                try? fm.removeItem(at: path)
                // Recreate the prefix directory so wineboot can chdir into WINEPREFIX.
                try fm.createDirectory(at: path, withIntermediateDirectories: true)
                try await createViaWineboot(engine: engine, fm: fm)
            }
        } else {
            log.warning("[create] no prefix template in engine — falling back to wineboot --init (slow, may take minutes)")
            try fm.createDirectory(at: path, withIntermediateDirectories: true)
            try await createViaWineboot(engine: engine, fm: fm)
        }
    }

    private func createViaWineboot(engine: WineEngine, fm: FileManager) async throws {
        let process = try await engine.run(args: ["wineboot", "--init"], prefix: self)
        guard process.terminationStatus == 0 else {
            log.error("[create] wineboot --init failed with exit \(process.terminationStatus)")
            throw PrefixError.createFailed(exitCode: process.terminationStatus)
        }
        log.info("[create] prefix created via wineboot --init ✓")
    }

    /// Resets the prefix system files to the new engine's pre-built template, preserving
    /// Steam user configuration (login session, library paths).
    ///
    /// This replaces the slow `wineboot --update` path for engine upgrades. The template
    /// already has all the correct DLLs for the new Wine version, so no Wine process
    /// needs to run during the reset. The operation is a file copy — instant and atomic.
    ///
    /// Files preserved across the reset (saved before, restored after):
    ///   - `drive_c/Program Files/Steam/config/loginusers.vdf` (or `Program Files (x86)/Steam` on older installs)
    ///   - `drive_c/Program Files/Steam/config/config.vdf`
    func resetToEngineTemplate(engine: WineEngine) async throws {
        let fm = FileManager.default
        let templateURL = WineEngine.engineDir.appending(path: "prefix-template")

        guard fm.fileExists(atPath: templateURL.path(percentEncoded: false)) else {
            // No template available — fall back to wineboot --update
            log.warning("[resetToTemplate] no template found — falling back to wineboot --update")
            try await refreshSystemDLLs(engine: engine, engineTag: engine.engineVersion ?? "unknown")
            return
        }

        log.info("[resetToTemplate] saving Steam config before prefix reset")

        // Also write a disk-based backup of the SteamCMD credential cache
        // as a safety net in case the in-memory restore below fails.
        backupSteamCMDConfig()

        // Save important Steam config files so login session survives the reset.
        // Capture the full URL for each file so the restore step can write back to
        // the exact same path in the new prefix (prefix URL doesn't change).
        let configFilesToPreserve: [URL] = [
            steamInstallDir.appending(path: "config/loginusers.vdf"),
            steamInstallDir.appending(path: "config/config.vdf"),
        ]
        let savedConfigs: [(dest: URL, data: Data)] = configFilesToPreserve.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (dest: url, data: data)
        }
        log.info("[resetToTemplate] saved \(savedConfigs.count) Steam config file(s)")

        // Remove the existing prefix and copy the new template
        log.info("[resetToTemplate] removing existing prefix")
        try fm.removeItem(at: path)

        log.info("[resetToTemplate] copying new engine template")
        try fm.copyItem(at: templateURL, to: path)

        // Recreate dosdevices with correct machine-local symlinks.
        // The template ships without dosdevices (they point to the build machine's paths).
        // Both c: and z: are required — z: maps the entire Unix filesystem so Wine can
        // resolve host paths (e.g. for SteamSetup.exe passed as an absolute Unix path).
        let dosdev = path.appending(path: "dosdevices")
        try? fm.removeItem(at: dosdev)
        try fm.createDirectory(at: dosdev, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: dosdev.appending(path: "c:").path(percentEncoded: false),
            withDestinationPath: "../drive_c"
        )
        try fm.createSymbolicLink(
            atPath: dosdev.appending(path: "z:").path(percentEncoded: false),
            withDestinationPath: "/"
        )

        // Populate syswow64 with all 32-bit PE files from the engine.
        // Wine 8.x left syswow64 empty; Wine 11.x does not create it at all.
        // Always create the directory and populate it from i386-windows/ so that
        // 32-bit executables (SteamSetup.exe) can find kernel32.dll via WoW64.
        let i386Src  = WineEngine.engineDir.appending(path: "wine/lib/wine/i386-windows")
        let syswow64 = path.appending(path: "drive_c/windows/syswow64")
        if fm.fileExists(atPath: i386Src.path(percentEncoded: false)) {
            try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            let i386Files = (try? fm.contentsOfDirectory(atPath: i386Src.path(percentEncoded: false))) ?? []
            var wow64Copied = 0
            for file in i386Files where Self.isWoW64FileType(file) {
                let dest = syswow64.appending(path: file)
                guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
                try? fm.copyItem(at: i386Src.appending(path: file), to: dest)
                wow64Copied += 1
            }
            log.info("[resetToTemplate] populated syswow64 with \(wow64Copied) 32-bit files for WoW64")
        } else {
            log.warning("[resetToTemplate] i386-windows not found in engine — WoW64 (32-bit apps) may fail")
        }

        // Restore saved Steam config files to their original paths.
        // Writing back to the captured URL is correct because the prefix URL hasn't changed —
        // only its contents were replaced by the template copy above.
        for (dest, data) in savedConfigs {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest)
        }
        log.info("[resetToTemplate] restored \(savedConfigs.count) Steam config file(s)")

        log.info("[resetToTemplate] prefix reset to new engine template ✓")
    }

    /// Refreshes system DLL symlinks in an existing prefix after a Wine engine upgrade.
    ///
    /// Runs `wineboot --update`, which reads `wine/share/wine/wine.inf` from the engine
    /// package and refreshes all `C:\windows\system32\` DLL entries and registry keys
    /// without touching installed apps or user data.
    ///
    /// **Engine requirement:** The engine tarball must contain `wine/share/wine/wine.inf`.
    /// `release-engine.sh` is responsible for including this file. The app does not work
    /// around its absence — if `wineboot --update` fails, the caller receives a clear error.
    func refreshSystemDLLs(engine: WineEngine, engineTag: String) async throws {
        log.info("[refreshSystemDLLs] running wineboot --update for engine \(engineTag)")
        let process = try await engine.run(args: ["wineboot", "--update"], prefix: self)
        guard process.terminationStatus == 0 else {
            log.error("[refreshSystemDLLs] wineboot --update failed exit=\(process.terminationStatus) — check engine contains wine/share/wine/wine.inf")
            throw PrefixError.updateFailed(exitCode: process.terminationStatus)
        }
        log.info("[refreshSystemDLLs] DLL symlinks refreshed ✓")
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

        do {
            try FileManager.default.removeItem(at: tempFile)
        } catch {
            log.warning("[installSteam] failed to clean up SteamSetup.exe: \(error.localizedDescription)")
        }

        let steamExists = isSteamInstalled
        log.info("[installSteam] installer exit=\(process.terminationStatus) | steam.exe present=\(steamExists)")

        guard process.terminationStatus == 0 || steamExists else {
            log.error("[installSteam] FAILED: exit=\(process.terminationStatus) and steam.exe not found at \(steamExePath.path(percentEncoded: false))")
            throw PrefixError.steamInstallFailed(exitCode: process.terminationStatus)
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

    // MARK: - Session File Writing (native auth)

    /// Writes `config/loginusers.vdf` for `steamID` so the Wine Steam client
    /// recognises an authenticated user and auto-selects it on next start.
    ///
    /// Called after a successful native IAuthenticationService login, immediately
    /// before (re)starting the persistent Steam process.
    func writeLoginUsers(steamID: String, accountName: String, personaName: String) throws {
        let fm = FileManager.default
        let configDir = steamConfigDir
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let vdf = """
        "users"
        {
        \t"\(steamID)"
        \t{
        \t\t"AccountName"\t\t"\(accountName)"
        \t\t"PersonaName"\t\t"\(personaName)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"\(timestamp)"
        \t}
        }
        """

        let dest = configDir.appending(path: "loginusers.vdf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
        log.info("[writeLoginUsers] written steamID=\(steamID) → \(dest.path(percentEncoded: false))")
    }

    /// Merges `ConnectCache` and `Accounts` into `config/config.vdf`.
    ///
    /// SteamCMD stores its encrypted credential cache (auth tokens, server
    /// timing info, WebSocket preferences) in the same `config/config.vdf` file
    /// under `InstallConfigStore > Software > Valve > Steam`. If we overwrite
    /// the file we destroy those credentials, forcing Steam Guard re-confirmation
    /// on every subsequent SteamCMD launch.
    ///
    /// Instead we MERGE:
    /// - If a `ConnectCache` block already exists, inject/update just the
    ///   steamID key-value entry inside it, leaving `7a611aa1` and other
    ///   SteamCMD-specific entries untouched.
    /// - If no `ConnectCache` block exists, append one inside the `Steam` section.
    /// - Same for `Accounts` — update the entry for this account, preserve others.
    /// - If no config.vdf exists yet, write the minimal VDF as before.
    func writeConnectCache(steamID: String, refreshToken: String, accountName: String) throws {
        let fm = FileManager.default
        let configDir = steamConfigDir
        try fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        let dest = configDir.appending(path: "config.vdf")

        let jwtEntry         = "\t\t\t\t\t\"\(steamID)\"\t\t\"\(refreshToken)\""
        let usernameJwtEntry = "\t\t\t\t\t\"\(accountName)\"\t\t\"\(refreshToken)\""
        let accountEntry     = "\t\t\t\t\t\"\(accountName)\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"SteamID\"\t\t\"\(steamID)\"\n\t\t\t\t\t}"

        // Try to merge into an existing file that has a Steam section.
        if let existing = try? String(contentsOf: dest, encoding: .utf8),
           existing.contains("\"Steam\"") {

            var updated = existing

            // Update or insert the steamID JWT entry inside the ConnectCache block.
            // steam.exe reads ConnectCache by SteamID for auto-login.
            updated = upsertVDFKeyInSection(in: updated,
                                            sectionKey: "\"ConnectCache\"",
                                            newKeyLine: jwtEntry,
                                            matchPrefix: "\"\(steamID)\"")

            // Update or insert the username JWT entry inside the ConnectCache block.
            // SteamCMD (+login USERNAME) reads ConnectCache by account name.
            updated = upsertVDFKeyInSection(in: updated,
                                            sectionKey: "\"ConnectCache\"",
                                            newKeyLine: usernameJwtEntry,
                                            matchPrefix: "\"\(accountName)\"")

            // Update or insert the Accounts entry.
            updated = upsertVDFKeyInSection(in: updated,
                                            sectionKey: "\"Accounts\"",
                                            newKeyLine: accountEntry,
                                            matchPrefix: "\"\(accountName)\"")

            try updated.write(to: dest, atomically: true, encoding: .utf8)
            log.info("[writeConnectCache] merged into existing config.vdf steamID=\(steamID)")
            return
        }

        // No existing file (or no Steam section) — write a minimal VDF.
        let connectCacheBlock = "\t\t\t\t\"ConnectCache\"\n\t\t\t\t{\n\(jwtEntry)\n\(usernameJwtEntry)\n\t\t\t\t}"
        let accountsBlock     = "\t\t\t\t\"Accounts\"\n\t\t\t\t{\n\(accountEntry)\n\t\t\t\t}"
        let vdf = "\"InstallConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\(connectCacheBlock)\n\(accountsBlock)\n\t\t\t}\n\t\t}\n\t}\n}"

        try vdf.write(to: dest, atomically: true, encoding: .utf8)
        log.info("[writeConnectCache] written new config.vdf steamID=\(steamID) → \(dest.path(percentEncoded: false))")
    }

    /// Finds the named VDF section by key, then updates or inserts a key-value
    /// line inside its brace block. If the section doesn't exist, appends it
    /// before the closing brace of the parent `"Steam"` section.
    ///
    /// - `matchPrefix`: the beginning of an existing line to replace (e.g. `"\"steamID\""`)
    /// - `newKeyLine`:  the replacement or new line to insert
    private func upsertVDFKeyInSection(in text: String, sectionKey: String,
                                       newKeyLine: String, matchPrefix: String) -> String {
        guard let keyRange = text.range(of: sectionKey) else {
            // Section not found — append a new section before Steam's closing brace.
            return insertBeforeSteamClose(in: text,
                                          text: "\(sectionKey)\n\t\t\t\t{\n\(newKeyLine)\n\t\t\t\t}")
        }

        // Find the opening brace of this section's value block.
        var searchStart = keyRange.upperBound
        while searchStart < text.endIndex && text[searchStart].isWhitespace {
            searchStart = text.index(after: searchStart)
        }
        guard searchStart < text.endIndex, text[searchStart] == "{" else { return text }

        // Walk to the closing brace, collecting the block range.
        var depth = 0
        var idx = searchStart
        while idx < text.endIndex {
            switch text[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    // `blockOpenIdx...idx` is the `{ ... }` range for this section.
                    let blockRange = searchStart...idx
                    var block = String(text[blockRange])

                    // Look for an existing line that starts with matchPrefix inside the block.
                    let lines = block.components(separatedBy: "\n")
                    if let existingIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(matchPrefix) }) {
                        var newLines = lines
                        // Determine the end of this entry. If the value is a { ... } block
                        // (multi-line entry), we must remove ALL those lines too, not just the
                        // key line. Replacing only the key line leaves the old block in the
                        // file, producing duplicate braces and corrupt VDF.
                        //
                        // Root cause of sign-in loop (v0.9.2): accountEntry is a multi-line
                        // string. When upserted by replacing only the key line the old
                        // { SteamID ... } block was left behind, causing SteamCMD to report
                        // "KeyValues Error: got } in key in file InstallConfigStore" and hang.
                        var endIdx = existingIdx
                        let lookAhead = existingIdx + 1
                        if lookAhead < newLines.count,
                           newLines[lookAhead].trimmingCharacters(in: .whitespaces) == "{" {
                            // Scan forward to the matching closing brace.
                            var depth = 0
                            var scanLine = lookAhead
                            while scanLine < newLines.count {
                                for ch in newLines[scanLine] {
                                    if ch == "{" { depth += 1 }
                                    else if ch == "}" {
                                        depth -= 1
                                        if depth == 0 { endIdx = scanLine }
                                    }
                                }
                                if depth == 0 { break }
                                scanLine += 1
                            }
                        }
                        newLines.replaceSubrange(existingIdx...endIdx, with: [newKeyLine])
                        block = newLines.joined(separator: "\n")
                    } else {
                        // Insert the new line before the closing `}`.
                        let closingBrace = block.lastIndex(of: "}")!
                        block.insert(contentsOf: "\n" + newKeyLine, at: closingBrace)
                    }

                    // Reconstruct the full text with the updated block.
                    let prefixText = text[text.startIndex..<searchStart]
                    let suffixText = text[text.index(after: idx)...]
                    return prefixText + block + suffixText
                }
            default: break
            }
            idx = text.index(after: idx)
        }
        return text
    }

    /// Inserts `text` just before the closing brace of the innermost `"Steam"` section.
    private func insertBeforeSteamClose(in vdf: String, text: String) -> String {
        guard let steamKeyRange = vdf.range(of: "\"Steam\"") else { return vdf }
        var searchStart = steamKeyRange.upperBound
        while searchStart < vdf.endIndex && vdf[searchStart].isWhitespace {
            searchStart = vdf.index(after: searchStart)
        }
        guard searchStart < vdf.endIndex, vdf[searchStart] == "{" else { return vdf }

        var depth = 0
        var idx = searchStart
        while idx < vdf.endIndex {
            switch vdf[idx] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    var result = vdf
                    result.insert(contentsOf: "\n" + text + "\n\t\t\t", at: idx)
                    return result
                }
            default: break
            }
            idx = vdf.index(after: idx)
        }
        return vdf
    }

    // MARK: - Webhelper Configuration

    /// Writes `steam.cfg` in the Steam install directory to disable the CEF sandbox.
    ///
    /// Two flags are written:
    ///
    /// `SteamNoSandbox=1` — instructs Steam to spawn the webhelper with `--no-sandbox
    /// --no-zygote`, bypassing Chromium's sandbox which fails under Wine due to missing
    /// kernel security primitives (job objects, token impersonation). Without this, the
    /// webhelper crashes on every launch and Steam cannot render any UI.
    ///
    /// `BootStrapperInhibitAll=enable` — prevents Steam's bootstrapper from checking for
    /// and downloading client updates every time it launches. Without this, every SteamCMD
    /// batch call starts with a multi-second update check, adding unnecessary latency to
    /// game installs. This flag is only written once Steam has been fully bootstrapped
    /// (steamui.dll present), so it never blocks the initial Steam client download.
    ///
    /// Safe to call repeatedly — no-op when the file already contains both settings.
    func ensureSteamCFG() throws {
        let fm = FileManager.default
        let cfgURL = steamInstallDir.appending(path: "steam.cfg")

        let alreadyBootstrapped = isSteamBootstrapped

        var required = ["SteamNoSandbox=1"]
        if alreadyBootstrapped {
            required.append("BootStrapperInhibitAll=enable")
        }

        let desiredContent = required.joined(separator: "\n") + "\n"

        // Check both that all required settings are present AND that no stale
        // settings remain (e.g. BootStrapperInhibitAll before bootstrap completes).
        if let existing = try? String(contentsOf: cfgURL, encoding: .utf8),
           existing == desiredContent {
            log.debug("[ensureSteamCFG] steam.cfg already configured — skipping")
            return
        }

        try fm.createDirectory(at: steamInstallDir, withIntermediateDirectories: true)

        try desiredContent.write(to: cfgURL, atomically: true, encoding: .utf8)
        log.info("[ensureSteamCFG] steam.cfg written: \(required.joined(separator: ", ")) → \(cfgURL.path(percentEncoded: false))")
    }

    /// Removes `BootStrapperInhibitAll=enable` from `steam.cfg` if present.
    ///
    /// Called defensively before the bootstrap loop to ensure a stale flag from
    /// a previous failed session does not prevent Steam from downloading its
    /// client update.
    func stripBootStrapperInhibit() {
        let cfgURL = steamInstallDir.appending(path: "steam.cfg")
        guard let content = try? String(contentsOf: cfgURL, encoding: .utf8),
              content.contains("BootStrapperInhibitAll") else { return }
        let cleaned = content
            .components(separatedBy: .newlines)
            .filter { !$0.contains("BootStrapperInhibitAll") }
            .joined(separator: "\n")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = trimmed.isEmpty ? "" : trimmed + "\n"
        try? final.write(to: cfgURL, atomically: true, encoding: .utf8)
        log.info("[stripBootStrapperInhibit] removed BootStrapperInhibitAll from steam.cfg")
    }

    // MARK: - Library Setup

    /// Ensures the default Steam library exists on disk and is registered in
    /// `libraryfolders.vdf` so install IPC can proceed without showing
    /// an "Install Game" dialog asking where to put files.
    ///
    /// Steam creates this file only after a user first logs in interactively.
    /// Our bootstrap runs Steam anonymously, so the directory and VDF file are
    /// absent until this method is called. Without them, Steam renders an
    /// install-location picker that our window suppressor hides — making every
    /// install appear to hang indefinitely.
    ///
    /// Safe to call repeatedly: it is a no-op when the directory and file already
    /// contain a valid default-library entry.
    func ensureDefaultLibrary() throws {
        let fm = FileManager.default
        let steamappsDir = steamInstallDir.appending(path: "steamapps")
        let vdfURL = steamappsDir.appending(path: "libraryfolders.vdf")

        // Create steamapps/ if absent.
        if !fm.fileExists(atPath: steamappsDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: steamappsDir, withIntermediateDirectories: true)
            log.info("[ensureDefaultLibrary] created steamapps/ at \(steamappsDir.path(percentEncoded: false))")
        }

        // Determine the Windows path matching the actual Steam install location.
        // The installer writes to Program Files\Steam (64-bit path) under wine-staging 11.5
        // and to Program Files (x86)\Steam (32-bit path) under older Wine builds.
        let isX86Install = steamInstallDir.path(percentEncoded: false).contains("Program Files (x86)")
        let defaultWinPath = isX86Install
            ? "C:\\\\Program Files (x86)\\\\Steam"
            : "C:\\\\Program Files\\\\Steam"

        // Skip write if the VDF already mentions the correct default path.
        if let existing = try? String(contentsOf: vdfURL, encoding: .utf8),
           existing.contains(defaultWinPath) {
            log.debug("[ensureDefaultLibrary] libraryfolders.vdf already configured — skipping")
            return
        }

        // Write a minimal libraryfolders.vdf that declares the default library.
        // Steam reads this on startup and uses it for all installs; with exactly
        // one library configured it auto-selects it without showing a dialog.
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"\(defaultWinPath)"
        \t\t"label"\t\t""
        \t\t"contentid"\t\t"0"
        \t\t"totalsize"\t\t"0"
        \t\t"update_clean_bytes_tally"\t\t"0"
        \t\t"time_last_update_corruption"\t\t"0"
        \t\t"apps"
        \t\t{
        \t\t}
        \t}
        }
        """

        try vdf.write(to: vdfURL, atomically: true, encoding: .utf8)
        log.info("[ensureDefaultLibrary] libraryfolders.vdf written → \(vdfURL.path(percentEncoded: false))")
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

            // Accept both: "path" "<winpath>" (new nested format) and "1" "<winpath>" (legacy)
            // Legacy format: "1" "C:\\some\\path" — numeric key, value is a Windows/Unix path
            // New format: nested section with "path" key, plus "apps" { "appID" "sizeBytes" }
            //
            // Guard: reject pure-numeric values — those are app sizes (e.g. "39590283"),
            // not paths. A real path always contains a path separator or a drive letter.
            let isPathKey = key == "path"
            let isNumericNonZero = key != "0" && key.allSatisfy(\.isNumber)
            guard isPathKey || isNumericNonZero else { continue }
            guard value.contains("\\") || value.contains("/") || (value.count >= 3 && value[value.index(value.startIndex, offsetBy: 1)] == ":") else { continue }

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

    /// Returns true only when the ACF exists AND `StateFlags` equals `"4"` (fully installed).
    ///
    /// Steam creates the ACF as soon as the user confirms the install dialog
    /// (`StateFlags` ≈ 1026 while queued/downloading). `StateFlags "4"` is written
    /// only when every depot has been staged and verified — i.e. the game is playable.
    /// Use this instead of `isGameInstalled` when you must not launch a partial download.
    func isGameFullyInstalled(appID: Int) -> Bool {
        guard let manifest = acfURL(for: appID),
              let contents = try? String(contentsOfFile: manifest.path(percentEncoded: false), encoding: .utf8)
        else { return false }
        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line), key == "StateFlags" else { continue }
            let fullyInstalled = value == "4"
            log.debug("[isGameFullyInstalled] appID=\(appID) StateFlags=\(value) → \(fullyInstalled)")
            return fullyInstalled
        }
        return false
    }

    /// Reads download progress from the ACF manifest.
    /// Returns (bytesDownloaded, bytesToDownload, stateFlags) or nil if the ACF is missing.
    func gameDownloadProgress(appID: Int) -> (downloaded: Int64, total: Int64, stateFlags: String)? {
        guard let manifest = acfURL(for: appID),
              let contents = try? String(contentsOfFile: manifest.path(percentEncoded: false), encoding: .utf8)
        else { return nil }

        var bytesDownloaded: Int64 = 0
        var bytesToDownload: Int64 = 0
        var stateFlags = ""

        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line) else { continue }
            switch key {
            case "BytesDownloaded": bytesDownloaded = Int64(value) ?? 0
            case "BytesToDownload": bytesToDownload = Int64(value) ?? 0
            case "StateFlags": stateFlags = value
            default: break
            }
        }

        return (bytesDownloaded, bytesToDownload, stateFlags)
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

    /// Returns true when the game's install directory contains `steam_api64.dll`
    /// or `steam_api.dll` at the top level, indicating it uses Steam DRM.
    ///
    /// Games with Steam DRM call `SteamAPI_Init()` at startup, which connects
    /// to a running Steam client via IPC. Without a live Steam client the
    /// game initialises silently and exits within a few seconds. The fix is
    /// to start `steam.exe -silent` before launching these games.
    ///
    /// Checks only the top-level game directory — subdirectory copies of the
    /// DLL (e.g. in redistributable packages) are intentionally ignored.
    func gameRequiresSteamAPI(appID: Int) -> Bool {
        guard let installDirName = gameInstallDir(appID: appID) else { return false }
        let fm = FileManager.default
        for library in steamLibraryFolders {
            let gameDir = library.appending(path: "steamapps/common/\(installDirName)")
            let gameDirPath = gameDir.path(percentEncoded: false)
            guard fm.fileExists(atPath: gameDirPath) else { continue }
            let steamAPI64 = gameDir.appending(path: "steam_api64.dll").path(percentEncoded: false)
            let steamAPI32 = gameDir.appending(path: "steam_api.dll").path(percentEncoded: false)
            let result = fm.fileExists(atPath: steamAPI64) || fm.fileExists(atPath: steamAPI32)
            log.debug("[gameRequiresSteamAPI] appID=\(appID) → \(result)")
            return result
        }
        log.debug("[gameRequiresSteamAPI] appID=\(appID) → false (game dir not found)")
        return false
    }

    /// Writes `steam_appid.txt` into the game's install directory.
    ///
    /// `steam_api64.dll` reads this file at startup to determine the application
    /// ID when it cannot retrieve it from the Steam client shortcut. Writing it
    /// before launch allows the DLL to complete its initialisation even before
    /// the Steam client IPC socket is fully ready.
    ///
    /// The file contains just the numeric appID (no newline required). Safe to
    /// call repeatedly — the file is overwritten each time.
    func writeSteamAppID(_ appID: Int) {
        guard let installDirName = gameInstallDir(appID: appID) else {
            log.warning("[writeSteamAppID] cannot find install dir for appID=\(appID)")
            return
        }
        let fm = FileManager.default
        for library in steamLibraryFolders {
            let gameDir = library.appending(path: "steamapps/common/\(installDirName)")
            guard fm.fileExists(atPath: gameDir.path(percentEncoded: false)) else { continue }
            let file = gameDir.appending(path: "steam_appid.txt")
            do {
                try "\(appID)".write(to: file, atomically: true, encoding: .utf8)
                log.info("[writeSteamAppID] wrote steam_appid.txt (\(appID)) to \(gameDir.lastPathComponent)")
            } catch {
                log.warning("[writeSteamAppID] failed: \(error.localizedDescription)")
            }
            return
        }
        log.warning("[writeSteamAppID] game dir not found for appID=\(appID)")
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
    ///
    /// Backs up SteamCMD's credential cache (`config.vdf`) before wiping.
    /// The encrypted auth token in that file survives prefix resets, so game
    /// installs won't require Steam Guard re-confirmation. Call
    /// `restoreSteamCMDConfig()` after the prefix is recreated and SteamCMD
    /// is re-installed.
    func reset() {
        let prefixPath = path.path(percentEncoded: false)
        log.info("[reset] removing prefix at \(prefixPath)")

        guard FileManager.default.fileExists(atPath: prefixPath) else {
            log.info("[reset] prefix does not exist — nothing to remove")
            return
        }

        backupSteamCMDConfig()

        do {
            try FileManager.default.removeItem(at: path)
            log.info("[reset] prefix removed")
        } catch {
            log.error("[reset] failed to remove prefix: \(error.localizedDescription)")
        }
    }

    // MARK: - SteamCMD Credential Cache Backup

    private static var steamcmdConfigBackupURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "com.meridian.app/steamcmd-config-backup.vdf")
    }

    /// Copies SteamCMD's `config/config.vdf` to a safe location outside the
    /// prefix. This file contains an encrypted credential token that lets
    /// SteamCMD log in without a password or Steam Guard confirmation.
    func backupSteamCMDConfig() {
        let configVDF = steamInstallDir.appending(path: "config/config.vdf")
        let backup = Self.steamcmdConfigBackupURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: configVDF.path(percentEncoded: false)) else {
            log.info("[backupSteamCMD] no config.vdf to backup")
            return
        }
        do {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: configVDF, to: backup)
            log.info("[backupSteamCMD] config.vdf backed up ✓")
        } catch {
            log.warning("[backupSteamCMD] backup failed: \(error.localizedDescription)")
        }
    }

    /// Restores a previously backed-up SteamCMD `config.vdf` into the prefix.
    /// Call after the prefix is recreated and SteamCMD is installed.
    func restoreSteamCMDConfig() {
        let backup = Self.steamcmdConfigBackupURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else {
            log.info("[restoreSteamCMD] no backup to restore")
            return
        }
        let configDir = steamInstallDir.appending(path: "config")
        let configVDF = configDir.appending(path: "config.vdf")
        do {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: configVDF)
            try fm.copyItem(at: backup, to: configVDF)
            log.info("[restoreSteamCMD] config.vdf restored from backup ✓")
        } catch {
            log.warning("[restoreSteamCMD] restore failed: \(error.localizedDescription)")
        }
    }

    // MARK: - WoW64 File Type Filter

    /// Windows PE file extensions that must be copied into `syswow64` for 32-bit
    /// process support under Wine's WoW64 layer.
    ///
    /// The previous filter only included `.dll`, which missed critical files:
    /// - `.drv` — display drivers (winemac.drv, winspool.drv) — without these,
    ///   32-bit processes cannot create windows (exit 152, "nodrv_CreateWindow")
    /// - `.exe` — system executables (explorer.exe)
    /// - `.sys`, `.cpl`, `.ocx`, `.acm`, `.ax` — various PE modules
    private static let wow64Extensions: Set<String> = [
        "dll", "drv", "exe", "sys", "cpl", "ocx", "acm", "ax", "com",
    ]

    /// Returns true if the filename has an extension that should be copied
    /// from `i386-windows/` into the prefix's `syswow64/` directory.
    static func isWoW64FileType(_ filename: String) -> Bool {
        guard let dot = filename.lastIndex(of: ".") else { return false }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return wow64Extensions.contains(ext)
    }

    // MARK: - Errors

    enum PrefixError: LocalizedError {
        case createFailed(exitCode: Int32)
        case updateFailed(exitCode: Int32)
        case steamDownloadFailed(statusCode: Int)
        case steamInstallFailed(exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "Failed to create Wine prefix (wineboot exit \(code))."
            case .updateFailed(let code):
                return "Failed to refresh Wine DLL symlinks (wineboot --update exit \(code)). Try resetting the Wine environment in Settings."
            case .steamDownloadFailed(let code):
                return "Failed to download SteamSetup.exe (HTTP \(code))."
            case .steamInstallFailed(let code):
                return "Failed to install Steam (installer exit \(code))."
            }
        }
    }
}
