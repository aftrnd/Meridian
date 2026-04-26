import Foundation

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

    /// `drive_c/users/crossover/AppData/Local/Steam` — where Steam's client writes
    /// its persistent auth token (the DPAPI-encrypted `local.vdf` consumed on auto-login).
    ///
    /// Wine's default prefix user is always `crossover` for Meridian bottles (same name
    /// CrossOver uses). This path matches the value `steamclient64.dll` looks up via
    /// `SHGetFolderPath(CSIDL_LOCAL_APPDATA)`, CLI-verified April 2026.
    var localAppDataSteamDir: URL {
        driveC.appending(path: "users/crossover/AppData/Local/Steam")
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
        // (config.vdf + ssfn files) as a safety net in case the in-memory restore
        // below fails.
        backupSteamCMDCredentials()

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

    /// Ensures the four core Wine services Steam needs are registered:
    /// `nsiproxy`, `RpcSs`, `EventLog`, `PlugPlay`.
    ///
    /// **Why this matters (CLI-verified April 25 2026 on a truly fresh prefix):**
    ///
    /// Without `nsiproxy`, Wine's `\\.\Nsi` device is never created and
    /// `iphlpapi::GetAdaptersAddresses` returns `ERROR_FILE_NOT_FOUND` (2).
    /// Steam's `CalcUnIPThisBox` (in `net_misc.cpp:252`) asserts on it,
    /// then `WebUITransportController:165` asserts when the main↔webhelper
    /// loopback websocket can't bind 127.0.0.1, and steam.exe enters an
    /// assert/auto-restart loop that produces a macOS "wine64 unexpected
    /// error" dialog. Without `RpcSs`, OLE class registration warns at
    /// every Wine command (`err:ole:start_rpcss Failed to open RpcSs service`)
    /// and some Steam IPC paths fail. `EventLog` and `PlugPlay` are
    /// dependencies of the above and the rest of the Wine service stack.
    ///
    /// **Why we have to write these ourselves:** The prefix template that
    /// `release-engine.sh` ships ships with **only 2 services in
    /// `system.reg`** (`MountMgr`, `Tcpip\Parameters`) because the
    /// `wineboot --init` step inside that script is killed by its 180 s
    /// timeout — `rundll32 setupapi InstallHinfSection` against `wine.inf`
    /// hits a runaway recursion in `ntdll.so` on macOS hosts (CLI-confirmed
    /// April 25 2026 via `sample` showing 568 frames at the same address).
    /// Re-running `wineboot --update` from the host is not a fix because the
    /// same recursion stalls there too. We register the minimum set Steam
    /// needs at runtime via short, well-formed `wine64 reg add` invocations
    /// that complete in seconds.
    ///
    /// **Why `wine64 reg add` and NOT direct `system.reg` file surgery:**
    /// Wine's `[System\\CurrentControlSet]` is a registry symlink to
    /// `[System\\ControlSet001]`. Writing directly under
    /// `[System\\CurrentControlSet\\Services\\<svc>]` to the .reg file
    /// looks correct in source but on the next `wineserver` save the symlink
    /// is resolved and the orphan section is dropped. CLI-verified April 25
    /// 2026: file-surgery left zero new services in `system.reg` after the
    /// first subsequent `wine64 reg add`. Using `wine64 reg add
    /// HKLM\\System\\CurrentControlSet\\Services\\<svc>` lets wineserver
    /// resolve the symlink correctly and persist the entry under
    /// `[System\\ControlSet001\\Services\\<svc>]`.
    ///
    /// Idempotent — `wine64 reg add /f` overwrites without error if the
    /// section exists. Total cost: ~3-5 wineserver round-trips per service,
    /// ~10-15 s on a cold prefix, near-zero once wineserver is warm.
    func ensureCoreServices(engine: WineEngine) async {
        // Each tuple: (HKLM key path, [(value name, type, value as string)])
        // Values match what `wine.inf` [<Svc>Service] sections install on a
        // working CX Preview bottle. Order: nsiproxy first so that even if a
        // later registration fails the network-enumeration assertion path is
        // unblocked.
        let services: [(name: String, key: String, vals: [(String, String, String)])] = [
            (
                "nsiproxy",
                #"HKLM\System\CurrentControlSet\Services\nsiproxy"#,
                [
                    ("Description",  "REG_SZ",        "NSI proxy service"),
                    ("DisplayName",  "REG_SZ",        "NSI Proxy"),
                    ("ImagePath",    "REG_EXPAND_SZ", #"C:\windows\system32\drivers\nsiproxy.sys"#),
                    ("ObjectName",   "REG_SZ",        "LocalSystem"),
                    ("Start",        "REG_DWORD",     "2"),       // SERVICE_AUTO_START
                    ("Type",         "REG_DWORD",     "1"),       // SERVICE_KERNEL_DRIVER
                    ("ErrorControl", "REG_DWORD",     "1"),       // SERVICE_ERROR_NORMAL
                    ("Group",        "REG_SZ",        "System Bus Extender"),
                ]
            ),
            (
                "RpcSs",
                #"HKLM\System\CurrentControlSet\Services\RpcSs"#,
                [
                    ("Description",  "REG_SZ",        "Provides the endpoint mapper and other miscellaneous RPC services."),
                    ("DisplayName",  "REG_SZ",        "Remote Procedure Call (RPC)"),
                    ("ImagePath",    "REG_EXPAND_SZ", #"C:\windows\system32\rpcss.exe"#),
                    ("ObjectName",   "REG_SZ",        #"NT AUTHORITY\NetworkService"#),
                    ("Start",        "REG_DWORD",     "2"),       // SERVICE_AUTO_START
                    ("Type",         "REG_DWORD",     "0x110"),   // SERVICE_WIN32_OWN_PROCESS | SERVICE_INTERACTIVE_PROCESS
                    ("ErrorControl", "REG_DWORD",     "1"),
                    ("Group",        "REG_SZ",        "COM Infrastructure"),
                ]
            ),
            (
                "EventLog",
                #"HKLM\System\CurrentControlSet\Services\EventLog"#,
                [
                    ("Description",  "REG_SZ",        "Manages event logging."),
                    ("DisplayName",  "REG_SZ",        "Event Log"),
                    ("ImagePath",    "REG_EXPAND_SZ", #"C:\windows\system32\svchost.exe -k LocalServiceNetworkRestricted"#),
                    ("ObjectName",   "REG_SZ",        #"NT AUTHORITY\LocalService"#),
                    ("Start",        "REG_DWORD",     "2"),
                    ("Type",         "REG_DWORD",     "0x10"),    // SERVICE_WIN32_OWN_PROCESS
                    ("ErrorControl", "REG_DWORD",     "1"),
                ]
            ),
            (
                "PlugPlay",
                #"HKLM\System\CurrentControlSet\Services\PlugPlay"#,
                [
                    ("Description",  "REG_SZ",        "Enables a computer to recognize and adapt to hardware changes."),
                    ("DisplayName",  "REG_SZ",        "Plug and Play"),
                    ("ImagePath",    "REG_EXPAND_SZ", #"C:\windows\system32\plugplay.exe"#),
                    ("ObjectName",   "REG_SZ",        "LocalSystem"),
                    ("Start",        "REG_DWORD",     "2"),
                    ("Type",         "REG_DWORD",     "0x110"),
                    ("ErrorControl", "REG_DWORD",     "0"),       // SERVICE_ERROR_IGNORE
                    ("Group",        "REG_SZ",        "PlugPlay"),
                ]
            ),
        ]

        // Cheap fast-path: if all four services are already present in
        // system.reg under ControlSet001 (where wineserver actually stores
        // them after symlink resolution), skip the work entirely.
        let regPath = path.appending(path: "system.reg").path(percentEncoded: false)
        if let current = try? String(contentsOfFile: regPath, encoding: .utf8) {
            let allPresent = services.allSatisfy { svc in
                current.contains(#"[System\\ControlSet001\\Services\\"# + svc.name + "]")
            }
            if allPresent {
                log.debug("[ensureCoreServices] all 4 services already present — skipping")
                return
            }
        }

        log.info("[ensureCoreServices] registering core Wine services (nsiproxy, RpcSs, EventLog, PlugPlay)")
        for svc in services {
            for (valname, valtype, val) in svc.vals {
                let args = ["reg", "add", svc.key, "/v", valname, "/t", valtype, "/d", val, "/f"]
                do {
                    let process = try await engine.run(args: args, prefix: self)
                    if process.terminationStatus != 0 {
                        log.warning("[ensureCoreServices] reg add \(svc.name).\(valname) failed exit=\(process.terminationStatus)")
                    }
                } catch {
                    log.warning("[ensureCoreServices] reg add \(svc.name).\(valname) threw: \(error.localizedDescription)")
                }
            }
        }
        log.info("[ensureCoreServices] core service registration complete ✓ (nsiproxy + RpcSs + EventLog + PlugPlay)")
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

        // Remove Steam's autorun registry entry before wineboot --update.
        // wineboot processes HKCU\...\Run entries and starts any registered programs.
        // Steam registers itself there during installation — if not removed, wineboot
        // starts steam.exe which shows its sign-in window when no valid session exists.
        // Steam re-adds itself the next time it runs normally, so this is safe to strip.
        let runKey = "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
        _ = try? await engine.run(args: ["reg", "delete", runKey, "/v", "Steam", "/f"], prefix: self)

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

    // MARK: - Steam stub refresh (fix for outdated SteamSetup.exe)
    //
    // The `SteamSetup.exe` installer at `cdn.akamai.steamstatic.com/client/installer/`
    // has been serving an outdated (~Jan 29 2026) stub that hard-reports
    // `Windows 6.2.9200.0` via its application manifest and triggers Valve's
    // "Steam is no longer supported on your operating system" deprecation
    // check. CLI-verified April 22, 2026:
    //
    //   MD5 of SteamSetup-installed stub: b97ff5ac… (4.72 MB, built Jan 29)
    //     → reports Windows 6.2.9200.0, exits code 255 on launch
    //
    //   MD5 of CX Preview 27's stub:      4f2ad574… (5.77 MB, built Mar 12)
    //     → reports Windows 10.0.19045.0, runs cleanly to "Suppressing Steam update"
    //
    // The normal self-update path `steam.exe` follows on launch would pull
    // the newer stub from `client-update.steamstatic.com`, but our Jan 29
    // stub fails its own TLS handshake ("http error 0" — the same macOS-26
    // + WoW64 + static-OpenSSL issue documented at engine-research-findings.mdc
    // lines 39-42) before the update can complete. Stuck in a perpetual-
    // old-stub loop.
    //
    // Fix: `release-engine.sh` copies a current `steam.exe` stub from CX
    // Preview's Steam bottle into the engine tarball at
    //   `$ENGINE/wine/share/meridian/steam.exe.stub`
    // and this function overwrites the freshly-SteamSetup'd stub with the
    // bundled one whenever its size differs.
    //
    // Per [update-system.mdc], CX Preview is a BUILD-TIME reference only —
    // this function only reads from the engine tarball, never from CX at
    // runtime.

    /// Path to the bundled stub inside the engine tarball.
    private static func bundledSteamStubURL() -> URL {
        WineEngine.engineDir.appending(path: "wine/share/meridian/steam.exe.stub")
    }

    /// If the engine ships a newer `steam.exe` stub than whatever
    /// `SteamSetup.exe` installed, overwrite the prefix's copy. Idempotent —
    /// no-op when sizes match or when the engine doesn't ship a bundled stub
    /// (legacy engines without this asset).
    ///
    /// Returns `true` when the stub was actually replaced.
    @discardableResult
    func refreshSteamStubFromEngineIfStale() -> Bool {
        let fm = FileManager.default
        let bundled = Self.bundledSteamStubURL()
        let bundledPath = bundled.path(percentEncoded: false)
        let ourStub = steamExePath
        let ourStubPath = ourStub.path(percentEncoded: false)

        guard fm.fileExists(atPath: bundledPath) else {
            log.debug("[refreshSteamStub] engine does not ship a bundled stub — skipping")
            return false
        }

        let bundledSize = (try? fm.attributesOfItem(atPath: bundledPath))?[.size] as? Int ?? 0
        let ourSize = (try? fm.attributesOfItem(atPath: ourStubPath))?[.size] as? Int ?? 0

        guard bundledSize != ourSize else {
            log.debug("[refreshSteamStub] stub sizes identical (\(bundledSize) bytes) — already up to date")
            return false
        }

        log.info("[refreshSteamStub] stale stub detected (prefix=\(ourSize) bytes, engine=\(bundledSize) bytes) — overwriting with bundled stub")

        do {
            if fm.fileExists(atPath: ourStubPath) {
                try fm.removeItem(atPath: ourStubPath)
            }
            try fm.copyItem(at: bundled, to: ourStub)
            log.info("[refreshSteamStub] steam.exe stub updated from engine bundle ✓")
            return true
        } catch {
            log.error("[refreshSteamStub] copy failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Copies Steam session files from the macOS Steam install into this prefix
    /// to enable auto-login without credentials. Used by `SteamSessionBridge` when
    /// a local macOS Steam install is detected during first-run bootstrap.
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

        // Copy ssfn machine auth tokens (legacy — steam.exe auto-login uses
        // ConnectCache JWT, but these are harmless to copy and reduce friction
        // if the user later inspects the prefix manually).
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
    /// recognises an authenticated user and auto-logs in on next start.
    ///
    /// Called after a successful native IAuthenticationService login, immediately
    /// before (re)starting the persistent Steam process.
    ///
    /// **Key field: `AllowAutoLogin "1"`.** Without this, Steam treats the
    /// user as "known but don't auto-login" — it connects to the CM
    /// network and then sits there with `[U:1:0]` (no user context) waiting
    /// for an explicit user action. The steamwebhelper renders the QR /
    /// login picker. CLI-verified against CX Preview's working
    /// `loginusers.vdf`: CX writes `AllowAutoLogin "1"` + `WantsOfflineMode
    /// "0"` + `SkipOfflineModeWarning "0"` — all three are needed to
    /// unconditionally trigger ConnectCache auto-login with the matching
    /// JWT in `config.vdf`.
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
        \t\t"WantsOfflineMode"\t\t"0"
        \t\t"SkipOfflineModeWarning"\t\t"0"
        \t\t"AllowAutoLogin"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"\(timestamp)"
        \t}
        }
        """

        let dest = configDir.appending(path: "loginusers.vdf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
        log.info("[writeLoginUsers] written steamID=\(steamID) → \(dest.path(percentEncoded: false))")
    }

    /// Writes `drive_c/users/crossover/AppData/Local/Steam/local.vdf` containing a
    /// DPAPI-encrypted JWT refresh token. Steam's `steamclient64.dll` reads this file
    /// on startup, decrypts the blob via `CryptUnprotectData` (passing the account name
    /// as entropy), and auto-logs in silently without showing any UI.
    ///
    /// ## Why this works
    ///
    /// Pre-April-2026 Meridian wrote the JWT to `config/config.vdf` under a `ConnectCache`
    /// block. Steam client `1773426488` (Mar 12 2026+) stopped reading tokens from that
    /// location — `configstore_log.txt` shows `Failed to read store 'machineuser' from
    /// 'local.vdf.tmp'`, then `Clearing in-memory token - 1: cached creds not available`.
    ///
    /// The definitive token store is now `%LOCALAPPDATA%\Steam\local.vdf`, keyed by a
    /// per-account 32-bit hash. CLI-verified April 23 2026 via `WINEDEBUG=+crypt` tracing
    /// of live Steam on our engine:
    ///
    /// ```
    /// trace:crypt:CryptUnprotectData called
    /// trace:crypt:report pDataIn cbData: 666
    /// trace:crypt:report pOptionalEntropy pbData: 6e,69,63,6b,6a,61,63,6b,38,37,36
    ///                                             = "nickjack876" (11 bytes, no NUL)
    /// trace:crypt:CryptUnprotectData returning ok
    /// ```
    ///
    /// The plaintext inside the blob is the raw JWT string (no wrapper, no VDF). The
    /// outer VDF structure wraps the encrypted blob:
    ///
    /// ```
    /// "MachineUserConfigStore" {
    ///   "Software" { "Valve" { "Steam" { "ConnectCache" {
    ///     "<key>"  "<hex-encoded encrypted blob>"
    ///   } } } }
    /// }
    /// ```
    ///
    /// where `<key> = (crc32(accountName) << 4) | slot_number` and `slot_number = 1` for
    /// the only user in this bottle. CRC32 is the IEEE polynomial, standard Ethernet.
    ///
    /// ## Why the DPAPI blob is reproducible from outside the bottle
    ///
    /// Wine's `CryptProtectData` (dlls/crypt32/protectdata.c) derives the symmetric 3DES
    /// key from:
    /// - `GetUserNameA()` — always `"crossover"` in Meridian prefixes (deterministic)
    /// - `crypt32_protectdata_secret` — Wine compile-time constant (`"I'm hunting wabbits"`)
    /// - Random 16-byte salt — stored inside the blob itself (round-trippable)
    /// - `pOptionalEntropy` — we pass the account name, matching what Steam passes at read time
    ///
    /// None of these are machine-bound or keychain-backed. A blob produced by any Wine
    /// binary with the same `crypt32.dll` + `crypt32.so` pair decrypts in any other
    /// bottle sharing those binaries. Meridian's engine ships the same CX Wine 11.4 both
    /// for Meridian's own `meridian-dpapi.exe` and for Steam, so round-trip is guaranteed.
    ///
    /// ## End-to-end verification
    ///
    /// CLI-verified April 23 2026: after this function writes `local.vdf`, Steam's
    /// connection log shows
    /// `[Logging On] Using JWT <id>, persistence: 1 → RecvMsgClientLogOnResponse() : 'OK'`
    /// within 4 seconds of launch, with zero UI rendered.
    ///
    /// ## Parameters
    /// - `engine`: used to invoke `meridian-dpapi.exe` (our mingw-built PE helper that
    ///   wraps Wine's `CryptProtectData`).
    /// - `steamID`: 64-bit Steam ID of the signed-in user (written to `loginusers.vdf`
    ///   too, separately).
    /// - `accountName`: the user's Steam login name (e.g. `"nickjack876"`). Used as the
    ///   DPAPI entropy AND as input to the CRC32 that produces the VDF key.
    /// - `refreshToken`: JWT refresh token captured via `SteamCredentialAuth.authenticate`.
    func writeSteamSessionLocalVdf(
        engine: WineEngine,
        steamID: String,
        accountName: String,
        refreshToken: String
    ) async throws {
        let fm = FileManager.default
        let dpapiHelper = WineEngine.engineDir
            .appending(path: "wine/share/meridian/meridian-dpapi.exe")
        if !fm.fileExists(atPath: dpapiHelper.path(percentEncoded: false)) {
            // Engine tarballs published before April 23 2026 don't ship the
            // helper. The app bundle always carries it (built into
            // `.app/Contents/Resources/` by the `Build meridian-dpapi.exe`
            // build phase), so we can recover transparently. This also
            // handles the case where an engine auto-refresh wipes
            // `wine/share/meridian/` between app launches.
            try Self.installDpapiHelperFromBundle(to: dpapiHelper)
        }

        // Stage plaintext + encrypted blob in drive_c/temp so wine64 can reach both
        // without path-translation complications. Cleanup is best-effort at the end.
        let tempDir = driveC.appending(path: "temp")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString.prefix(8)
        let plaintextURL = tempDir.appending(path: "dpapi-plain-\(sessionID).bin")
        let cipherURL    = tempDir.appending(path: "dpapi-cipher-\(sessionID).bin")

        try Data(refreshToken.utf8).write(to: plaintextURL)

        defer {
            try? fm.removeItem(at: plaintextURL)
            try? fm.removeItem(at: cipherURL)
        }

        // Wine-visible Windows paths for the temp files and the helper exe.
        // Engine dir is outside the prefix — Wine exposes the host filesystem as Z:\
        // by default via the dosdevices/z: symlink pointing at /.
        let winPlain  = "C:\\temp\\dpapi-plain-\(sessionID).bin"
        let winCipher = "C:\\temp\\dpapi-cipher-\(sessionID).bin"
        let winHelper = "Z:" + dpapiHelper.path(percentEncoded: false).replacingOccurrences(of: "/", with: "\\")

        let process = try await engine.run(
            args: [winHelper, "encrypt", winPlain, winCipher, accountName],
            prefix: self
        )
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "WinePrefix.writeSteamSessionLocalVdf", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "meridian-dpapi.exe encrypt failed (exit=\(process.terminationStatus))"
            ])
        }

        let cipher = try Data(contentsOf: cipherURL)
        guard !cipher.isEmpty else {
            throw NSError(domain: "WinePrefix.writeSteamSessionLocalVdf", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "meridian-dpapi.exe produced an empty cipher blob"
            ])
        }

        let key = Self.connectCacheKey(for: accountName)
        let hexBlob = cipher.map { String(format: "%02x", $0) }.joined()

        let vdf = """
        "MachineUserConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"ConnectCache"
        \t\t\t\t{
        \t\t\t\t\t"\(key)"\t\t"\(hexBlob)"
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """

        try fm.createDirectory(at: localAppDataSteamDir, withIntermediateDirectories: true)
        let dest = localAppDataSteamDir.appending(path: "local.vdf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
        log.info("[writeSteamSession] local.vdf written key=\(key) blob=\(cipher.count) bytes → \(dest.path(percentEncoded: false))")
    }

    /// Disables Steam's download-complete desktop notification and chime for
    /// the signed-in user by writing to `userdata/<accountID>/config/localconfig.vdf`.
    ///
    /// Steam uses a split config model:
    ///   - `HKCU\Software\Valve\Steam` for the Win32/native-UI toggles
    ///   - `localconfig.vdf` for the HTML5/CEF webhelper toggles
    ///
    /// Both need to be set — the "Download Complete" popup and chime come from
    /// the webhelper, not the native UI. Writing only the registry leaves the
    /// popup audible and visible when a game finishes downloading.
    ///
    /// `localconfig.vdf` is also overwritten by Steam itself at shutdown, but
    /// Steam merges existing keys with its in-memory view rather than replacing
    /// the whole file, so our values stick as long as we write them before any
    /// download completes in the current session. `WineSteamManager.startPersistent`
    /// calls this right before launching `steam.exe -silent`.
    ///
    /// Pass an empty `steamID64` to skip (user not signed in yet — no userdata
    /// directory exists).
    func writeUserNotificationPreferences(steamID64: String) throws {
        guard !steamID64.isEmpty, let sid = UInt64(steamID64) else {
            log.debug("[writeUserNotificationPrefs] no SteamID64 — skipping")
            return
        }
        // Steam's userdata/ uses the 32-bit account ID, not the full 64-bit ID.
        // AccountID = SteamID64 - 76561197960265728 (the public-universe base).
        let accountID = sid &- 76561197960265728
        let userDir = steamInstallDir.appending(path: "userdata/\(accountID)/config")
        let cfgPath = userDir.appending(path: "localconfig.vdf").path(percentEncoded: false)
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)

        // Minimal VDF overriding the notification + sound toggles. Steam merges
        // this with any existing file at launch. Keys confirmed in Steam's
        // HTML5 UI source (`steamui/chunk~*.js`) as the settings backing:
        //
        //   • `UserLocalConfigStore > Notifications > DownloadCompleted`
        //     — Settings → Interface → "Desktop notifications" → "Download complete"
        //   • `UserLocalConfigStore > Sounds > PlaySoundDownload`
        //     — Settings → Interface → "Sounds" → "Play sound when download completes"
        //   • `EnableCustomSounds = 0` turns off Steam's entire sound pack, a
        //     defence-in-depth belt-and-suspenders against Valve renaming the
        //     specific key above.
        let vdf = """
        "UserLocalConfigStore"
        {
        \t"Notifications"
        \t{
        \t\t"DownloadCompleted"\t\t"0"
        \t\t"ShowDesktopToast"\t\t"0"
        \t\t"ShowInGameToast"\t\t"0"
        \t\t"EnableCustomSounds"\t\t"0"
        \t}
        \t"Sounds"
        \t{
        \t\t"PlaySoundDownload"\t\t"0"
        \t\t"PlaySoundDownloadComplete"\t\t"0"
        \t\t"EnableStandardSounds"\t\t"0"
        \t\t"EnableCustomSounds"\t\t"0"
        \t}
        }
        """

        // Atomic write so Steam never reads a partial file if it happens to be
        // scanning userdata while we write (rare — Steam reads localconfig only
        // at post-login hydration).
        try vdf.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        log.info("[writeUserNotificationPrefs] wrote \(cfgPath) (accountID=\(accountID))")
    }

    /// Copies `meridian-dpapi.exe` from the Meridian app bundle's Resources into
    /// the engine directory. Called by `writeSteamSessionLocalVdf` when the
    /// engine's own copy is missing — which happens when:
    ///   - The user is running an engine tarball predating April 23 2026 (the
    ///     version that first shipped the helper inside `wine/share/meridian/`).
    ///   - An engine auto-refresh wiped `wine/share/meridian/` before a paired
    ///     engine release was published (e.g. the 0.9.9 app bump silently
    ///     re-extracted the 0.9.8 engine tarball, which had no helper).
    ///
    /// The helper is re-built into the app bundle on every Xcode build via the
    /// `Build meridian-dpapi.exe` script phase, so it's always current with the
    /// source in `Scripts/dpapi/meridian_dpapi.c`.
    ///
    /// Throws a clear error if the bundle copy is also missing (which should
    /// never happen for a properly-built app and indicates a bundle integrity
    /// issue worth surfacing).
    private static func installDpapiHelperFromBundle(to destination: URL) throws {
        let fm = FileManager.default
        guard let bundleHelper = Bundle.main.url(forResource: "meridian-dpapi", withExtension: "exe") else {
            throw NSError(domain: "WinePrefix.installDpapiHelper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "meridian-dpapi.exe is missing from both the engine and the Meridian app bundle. Reinstall Meridian."
            ])
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: bundleHelper, to: destination)
        log.info("[installDpapiHelper] copied bundled meridian-dpapi.exe → \(destination.path(percentEncoded: false))")
    }

    /// Steam's ConnectCache map key format: `(crc32(accountName) << 4) | slot_number`.
    /// The slot number is `1` for the only user in this bottle — Meridian never signs
    /// two accounts into the same bottle, so slot is always `1`.
    ///
    /// CLI-verified April 23 2026 against CX Preview's working `local.vdf`:
    /// `crc32("nickjack876") = 0x07a611aa`, CX key is `0x7a611aa1`
    /// → `(0x07a611aa << 4) | 0x1 = 0x7a611aa1` ✓
    static func connectCacheKey(for accountName: String) -> String {
        let bytes = Array(accountName.utf8)
        let crc = ieeeCRC32(bytes: bytes)
        let key: UInt32 = (crc << 4) | 0x1
        return String(format: "%08x", key)
    }

    /// IEEE 802.3 / CRC-32/ISO-HDLC — the same polynomial `zlib.crc32` /
    /// `binascii.crc32` / Ethernet frame CRC use. Init 0xFFFFFFFF, final XOR 0xFFFFFFFF,
    /// reflected input, reflected output. Deliberately implemented locally rather than
    /// pulling in CommonCrypto or zlib to keep `WinePrefix` self-contained and keep the
    /// contract explicit for future maintainers: the key derivation MUST use this exact
    /// variant — any other CRC32 variant produces a different key and Steam's lookup
    /// silently fails with no error message.
    private static func ieeeCRC32(bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) != 0 ? 0xEDB88320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Webhelper Configuration

    /// Writes `steam.cfg` in the Steam install directory to disable the CEF sandbox.
    ///
    /// `SteamNoSandbox=1` — instructs Steam to spawn the webhelper with `--no-sandbox
    /// --no-zygote`, bypassing Chromium's sandbox which fails under Wine due to missing
    /// kernel security primitives (job objects, token impersonation). Without this, the
    /// webhelper crashes on every launch and Steam cannot render any UI.
    ///
    /// **`BootStrapperInhibitAll` is deliberately NOT written.** The Mar 12 2026 Steam
    /// stub requires its self-verify / self-update path to run on every launch so it can
    /// detect a mismatched installation and reconcile its package set (CLI-verified April
    /// 22, 2026: the stub looks for `steam_client_win64.installed` and package `.vz` files;
    /// with BootStrapperInhibit set it silently exits after "Suppressing Steam update"
    /// without handing off to steamclient64.dll). The per-launch update check costs ~1s
    /// when already current — well worth paying for a reliable handoff. See
    /// `stripBootStrapperInhibit()` for the legacy-cleanup utility that removes stale
    /// flags from prefixes written by older Meridian versions.
    ///
    /// Safe to call repeatedly — no-op when the file already contains the desired content.
    func ensureSteamCFG() throws {
        let fm = FileManager.default
        let cfgURL = steamInstallDir.appending(path: "steam.cfg")

        let desiredContent = "SteamNoSandbox=1\n"

        if let existing = try? String(contentsOf: cfgURL, encoding: .utf8),
           existing == desiredContent {
            log.debug("[ensureSteamCFG] steam.cfg already configured — skipping")
            return
        }

        try fm.createDirectory(at: steamInstallDir, withIntermediateDirectories: true)

        try desiredContent.write(to: cfgURL, atomically: true, encoding: .utf8)
        log.info("[ensureSteamCFG] steam.cfg written: SteamNoSandbox=1 → \(cfgURL.path(percentEncoded: false))")
    }

    /// Removes `BootStrapperInhibitAll` from `steam.cfg` if present.
    ///
    /// Legacy-cleanup utility for prefixes written by older Meridian versions that
    /// used to set this flag post-bootstrap. The flag breaks the Mar 12+ Steam stub
    /// (silent-exit after "Suppressing Steam update" — the stub never reaches its
    /// steamclient handoff). `ensureSteamCFG()` now rewrites steam.cfg so this is
    /// implicit, but this helper remains for places that only want to strip the flag
    /// without touching anything else.
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

    /// Removes the `.crash` marker file in the Steam install directory.
    ///
    /// Steam writes a zero-byte `.crash` file at startup and deletes it on clean
    /// shutdown. When Meridian or the host Mac terminates uncleanly (app crash,
    /// forced quit, reboot while Steam is running), the marker is left behind.
    /// On the next launch the bootstrapper sees it and enters a "recover from last
    /// crash" path that, combined with our self-populated install dir, can deadlock
    /// before the steamclient handoff.
    ///
    /// Call immediately before every `steam.exe` launch so startup is deterministic.
    /// Idempotent: no-op when the file doesn't exist.
    func clearCrashMarker() {
        let crashURL = steamInstallDir.appending(path: ".crash")
        let path = crashURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.removeItem(at: crashURL)
        log.info("[clearCrashMarker] removed stale .crash at \(path)")
    }

    // MARK: - Legacy cleanup

    /// Current version of the stale `Steam Client Service` registry cleanup.
    /// Bump when a new cleanup action is needed on existing installations.
    static let staleSteamServiceCleanupVersion = 1

    /// Removes the stale `HKLM\System\CurrentControlSet\Services\Steam Client Service`
    /// registry entry left behind by older Meridian versions running the Jan 29
    /// steam.exe stub. That entry's `ImagePath` points to
    /// `C:\Program Files (x86)\Common Files\Steam\steamservice.exe`, which does
    /// not exist in the Mar 12+ install (binary is at `bin\SteamService.exe`),
    /// so `StartService` returns `ERROR_MOD_NOT_FOUND` (GLE 126) every launch.
    /// Steam will re-register the entry itself with the correct path the next
    /// time the service is needed. Idempotent: succeeds whether or not the key
    /// is present.
    func removeStaleSteamServiceRegistration(engine: WineEngine) async {
        log.info("[removeStaleSteamService] deleting legacy Steam Client Service registration")
        _ = try? await engine.run(
            args: ["reg", "delete", "HKLM\\System\\CurrentControlSet\\Services\\Steam Client Service", "/f"],
            prefix: self
        )
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

    /// Writes a minimal pre-seeded `appmanifest_<appID>.acf` in the default
    /// Steam library's `steamapps/` folder so Steam treats the game as an
    /// "incomplete install that needs to sync" — and kicks off the download
    /// on its NEXT startup scan.
    ///
    /// ## Why this works
    ///
    /// Steam's content manager scans `steamapps/appmanifest_*.acf` exactly
    /// ONCE per launch (during the login post-callback sequence). For every
    /// manifest it finds with `StateFlags = 1026` (UpdateRequired | Validating),
    /// Steam:
    ///   1. Queries Valve's backend for the app's depot metadata
    ///   2. Creates `steamapps/common/<installdir>/` if missing
    ///   3. Downloads the full content silently — no install dialog, no
    ///      library-folder picker, no user interaction
    ///   4. Updates the same ACF in place with real `BytesDownloaded` /
    ///      `BytesToDownload` values as it progresses
    ///
    /// CLI-verified April 23 2026: writing this manifest for Super Battle
    /// Golf (AppID 4069520) + restarting `steam.exe -silent` downloaded the
    /// full 1.8 GB game in 25 seconds with zero UI rendered. The resulting
    /// ACF was updated with the correct `SizeOnDisk`, `InstalledDepots`, and
    /// build ID — identical in structure to what CX Preview's Steam writes
    /// after a GUI-triggered install.
    ///
    /// **Steam does NOT re-scan ACFs while running.** Writing a fresh manifest
    /// only takes effect after the next Steam startup, so the caller must
    /// `stopPersistent` + `startPersistent` after this. See
    /// `WineSteamManager.installGame` for the full flow.
    ///
    /// ## Parameters
    /// - `appID`: Steam app ID
    /// - `name`: display name (cosmetic, Steam may overwrite from backend)
    /// - `installDir`: the `steamapps/common/<installDir>/` folder name. Safe
    ///   to pass the game's display name — Steam normalises to the real value
    ///   from the app's depot metadata on first sync.
    /// - `steamID64`: the user's SteamID (required for `LastOwner` field;
    ///   Steam's content manager gates install on this matching the logged-in
    ///   account's licence list).
    func writePreseededAppManifest(
        appID: Int,
        name: String,
        installDir: String,
        steamID64: String
    ) throws {
        let fm = FileManager.default
        let steamappsDir = steamInstallDir.appending(path: "steamapps")
        try fm.createDirectory(at: steamappsDir, withIntermediateDirectories: true)

        // StateFlags 1026 = 1024 (UpdateRequired) | 2 (Validating).
        // Steam treats this as "content out of date — validate + re-download missing
        // chunks." With zero bytes on disk, that means "download everything."
        let vdf = """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"universe"\t\t"1"
        \t"name"\t\t"\(name.replacingOccurrences(of: "\"", with: "\\\""))"
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t"\(installDir.replacingOccurrences(of: "\"", with: "\\\""))"
        \t"LastUpdated"\t\t"0"
        \t"SizeOnDisk"\t\t"0"
        \t"StagingSize"\t\t"0"
        \t"buildid"\t\t"0"
        \t"LastOwner"\t\t"\(steamID64)"
        \t"DownloadType"\t\t"0"
        \t"UpdateResult"\t\t"0"
        \t"BytesToDownload"\t\t"0"
        \t"BytesDownloaded"\t\t"0"
        \t"BytesToStage"\t\t"0"
        \t"BytesStaged"\t\t"0"
        \t"TargetBuildID"\t\t"0"
        \t"AutoUpdateBehavior"\t\t"0"
        \t"AllowOtherDownloadsWhileRunning"\t\t"0"
        \t"ScheduledAutoUpdate"\t\t"0"
        }
        """
        let dest = steamappsDir.appending(path: "appmanifest_\(appID).acf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
        log.info("[writePreseededAppManifest] appID=\(appID) name=\"\(name)\" installdir=\"\(installDir)\" → \(dest.path(percentEncoded: false))")
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
        guard let details = gameDownloadDetails(appID: appID) else { return nil }
        return (details.bytesDownloaded, details.bytesToDownload, details.stateFlags)
    }

    /// Returns the on-disk bytes written into `steamapps/downloading/<appID>/`
    /// so far — the authoritative live-progress signal during a Steam install.
    ///
    /// ## Why not the ACF?
    ///
    /// Steam buffers ACF writes in memory and only flushes to disk at phase
    /// boundaries. CLI-verified April 23 2026 on a Super Battle Golf install:
    /// `BytesDownloaded` stayed at `0` in the ACF for the full 23-second
    /// download, then the file was rewritten in one shot at completion with
    /// the final byte counts. A 1-second polling loop against `BytesDownloaded`
    /// reads `0 / 1.27 GB` twenty-three times in a row, then `1.27 GB / 1.27 GB`
    /// — no useful progress.
    ///
    /// ## What Steam actually does
    ///
    /// `content_log.txt` for the same install showed:
    /// ```
    /// [19:51:27] update started : download 0/1274955600
    /// [19:51:34] Detected write gap 119 MB in file "Super Battle Golf_Data\data.unity3d"
    /// [19:51:36] Detected write gap 168 MB in file "Super Battle Golf_Data\data.unity3d"
    /// [19:51:40] Increasing target connections to 4 (rate was 0.000, now 427.288)
    /// [19:51:50] starting commit from downloading/4069520 to common/Super Battle Golf
    /// ```
    /// i.e. Steam writes chunks directly into files under
    /// `steamapps/downloading/<appID>/` as they arrive from the CDN. The
    /// directory's on-disk usage grows in lockstep with download progress,
    /// at high temporal resolution (sub-second).
    ///
    /// After download finishes, Steam "commits" by moving the files from
    /// `downloading/<appID>/` into `common/<installdir>/`. During that
    /// (typically very short) window this method may return briefly-low
    /// values as files are renamed; the caller should treat values as
    /// monotonic non-decreasing and clamp accordingly.
    func bytesOnDiskForDownload(appID: Int) -> Int64 {
        let fm = FileManager.default
        let dir = steamInstallDir.appending(path: "steamapps/downloading/\(appID)")
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                  let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// On-disk bytes currently committed under `steamapps/common/<installdir>/`.
    /// Used to track post-download progress: after Steam moves files from
    /// `downloading/<appID>/` to `common/<installdir>/`, this climbs from
    /// 0 to the full installed size over a few seconds. Combined with
    /// `bytesOnDiskForDownload` it covers the full download → install window
    /// without ever reading Steam's laggy ACF.
    func bytesOnDiskForInstall(appID: Int, installDir: String) -> Int64 {
        let fm = FileManager.default
        let dir = steamInstallDir.appending(path: "steamapps/common/\(installDir)")
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
                  let size = values.totalFileAllocatedSize else { continue }
            total += Int64(size)
        }
        return total
    }

    /// Richer variant of `gameDownloadProgress`: includes staging byte counts
    /// and a coarse install phase derived from actual bytes (not Valve's
    /// opaque `StateFlags` bitmask).
    ///
    /// ## Why bytes, not StateFlags
    ///
    /// CLI-verified April 23 2026: `StateFlags` is NOT a reliable
    /// continuous progress signal. On a Super Battle Golf install the ACF's
    /// StateFlags stayed at `1026` (UpdateStarted | UpdateRequired) for the
    /// entire 27-second download, then flipped atomically to `4`
    /// (FullyInstalled) when done — no intermediate values observed at 2 s
    /// polling. The community-documented "Downloading / Staging / Committing"
    /// bits (0x400000, 0x1000000, 0x200000) aren't set until the very last
    /// millisecond before the final flip, so any phase-from-flags decoder
    /// picks "Validating 92%" from bit 0x400 (which Valve actually uses for
    /// `UpdateStarted`) and shows the user a bar stuck at 92% for 27 s.
    ///
    /// `BytesDownloaded` / `BytesToDownload` / `BytesStaged` / `BytesToStage`,
    /// in contrast, update continuously as Steam writes chunks. Same source,
    /// higher resolution, no bitmask guessing.
    ///
    /// ## Phase derivation
    ///
    /// - `StateFlags == "4"`                          → `.installed`
    /// - `bytesToDownload > 0` AND `bytesDownloaded < bytesToDownload`  → `.downloading`
    /// - `bytesToStage > 0` AND `bytesStaged < bytesToStage`            → `.installing` (staging + committing + validating all map here — user doesn't care about the difference)
    /// - everything else (pre-start, unknown)                            → `.preparing`
    func gameDownloadDetails(appID: Int) -> GameDownloadDetails? {
        guard let manifest = acfURL(for: appID),
              let contents = try? String(contentsOfFile: manifest.path(percentEncoded: false), encoding: .utf8)
        else { return nil }

        var bytesDownloaded: Int64 = 0
        var bytesToDownload: Int64 = 0
        var bytesStaged: Int64 = 0
        var bytesToStage: Int64 = 0
        var stateFlagsStr = ""

        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line) else { continue }
            switch key {
            case "BytesDownloaded": bytesDownloaded = Int64(value) ?? 0
            case "BytesToDownload": bytesToDownload = Int64(value) ?? 0
            case "BytesStaged":     bytesStaged     = Int64(value) ?? 0
            case "BytesToStage":    bytesToStage    = Int64(value) ?? 0
            case "StateFlags":      stateFlagsStr   = value
            default: break
            }
        }

        let phase: InstallPhase
        if stateFlagsStr == "4" {
            phase = .installed
        } else if bytesToDownload > 0 && bytesDownloaded < bytesToDownload {
            phase = .downloading
        } else if bytesToStage > 0 && bytesStaged < bytesToStage {
            phase = .installing
        } else {
            phase = .preparing
        }

        return GameDownloadDetails(
            bytesDownloaded: bytesDownloaded,
            bytesToDownload: bytesToDownload,
            bytesStaged: bytesStaged,
            bytesToStage: bytesToStage,
            stateFlags: stateFlagsStr,
            phase: phase
        )
    }

    /// Byte-driven install phase — see `gameDownloadDetails(appID:)` doc for
    /// why we derive this from byte counts instead of Valve's StateFlags.
    enum InstallPhase: String, Sendable {
        case preparing    // ACF exists, byte counts not yet written by Steam
        case downloading  // transferring compressed chunks from CDN
        case installing   // decompressing / staging / committing chunks to `common/`
        case installed    // StateFlags == 4, ready to play

        /// Verb shown in the UI alongside the current progress.
        var userDescription: String {
            switch self {
            case .preparing:   return "Preparing"
            case .downloading: return "Downloading"
            case .installing:  return "Installing"
            case .installed:   return "Installed"
            }
        }
    }

    /// Full ACF snapshot used by the install-progress UI. `stateFlags` is
    /// retained as a string for logging / debugging but is NOT used to drive
    /// the progress bar — see `gameDownloadDetails(appID:)` for the rationale.
    struct GameDownloadDetails: Sendable {
        let bytesDownloaded: Int64
        let bytesToDownload: Int64
        let bytesStaged: Int64
        let bytesToStage: Int64
        let stateFlags: String
        let phase: InstallPhase
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
    /// Searches recursively through the game directory so it correctly handles
    /// Unity games (DLL in GameName_Data/Plugins/x86_64/), Unreal games
    /// (DLL in Engine/Binaries/ThirdParty/Steamworks/), and any other layout.
    func gameRequiresSteamAPI(appID: Int) -> Bool {
        guard let installDirName = gameInstallDir(appID: appID) else { return false }
        let fm = FileManager.default
        for library in steamLibraryFolders {
            let gameDir = library.appending(path: "steamapps/common/\(installDirName)")
            let gameDirPath = gameDir.path(percentEncoded: false)
            guard fm.fileExists(atPath: gameDirPath) else { continue }
            guard let enumerator = fm.enumerator(atPath: gameDirPath) else { continue }
            while let file = enumerator.nextObject() as? String {
                let lower = (file as NSString).lastPathComponent.lowercased()
                if lower == "steam_api64.dll" || lower == "steam_api.dll" {
                    log.debug("[gameRequiresSteamAPI] appID=\(appID) → true (found \(file))")
                    return true
                }
            }
            log.debug("[gameRequiresSteamAPI] appID=\(appID) → false")
            return false
        }
        log.debug("[gameRequiresSteamAPI] appID=\(appID) → false (game dir not found)")
        return false
    }

    /// Writes `steam_appid.txt` into the game's install directory and, if
    /// `steam_api64.dll` is in a subdirectory (e.g. Unity's
    /// `GameName_Data/Plugins/x86_64/`), also into that subdirectory.
    ///
    /// `steam_api64.dll` reads this file at startup to determine the application
    /// ID when it cannot retrieve it from the Steam client shortcut. Unity games
    /// load it relative to the DLL, not the exe, so both locations are needed.
    ///
    /// Safe to call repeatedly — the file is overwritten each time.
    func writeSteamAppID(_ appID: Int) {
        guard let installDirName = gameInstallDir(appID: appID) else {
            log.warning("[writeSteamAppID] cannot find install dir for appID=\(appID)")
            return
        }
        let fm = FileManager.default
        for library in steamLibraryFolders {
            let gameDir = library.appending(path: "steamapps/common/\(installDirName)")
            guard fm.fileExists(atPath: gameDir.path(percentEncoded: false)) else { continue }

            // Always write to the root install directory (for most games + exe lookup)
            let rootFile = gameDir.appending(path: "steam_appid.txt")
            do {
                try "\(appID)".write(to: rootFile, atomically: true, encoding: .utf8)
                log.info("[writeSteamAppID] wrote steam_appid.txt (\(appID)) to \(gameDir.lastPathComponent)")
            } catch {
                log.warning("[writeSteamAppID] failed writing to root: \(error.localizedDescription)")
            }

            // Also write alongside steam_api64.dll if it lives in a subdirectory
            if let enumerator = fm.enumerator(atPath: gameDir.path(percentEncoded: false)) {
                while let file = enumerator.nextObject() as? String {
                    let lower = (file as NSString).lastPathComponent.lowercased()
                    if lower == "steam_api64.dll" || lower == "steam_api.dll" {
                        let dllDir = gameDir.appending(path: (file as NSString).deletingLastPathComponent)
                        let dllDirPath = dllDir.path(percentEncoded: false)
                        if dllDirPath != gameDir.path(percentEncoded: false) {
                            let sideFile = dllDir.appending(path: "steam_appid.txt")
                            do {
                                try "\(appID)".write(to: sideFile, atomically: true, encoding: .utf8)
                                log.info("[writeSteamAppID] wrote steam_appid.txt (\(appID)) alongside DLL at \(file)")
                            } catch {
                                log.warning("[writeSteamAppID] failed writing beside DLL: \(error.localizedDescription)")
                            }
                        }
                        break
                    }
                }
            }
            return
        }
        log.warning("[writeSteamAppID] game dir not found for appID=\(appID)")
    }

    // MARK: - WinRT Registration

    /// Increment this when new entries are added to `registerWinRTClasses()`.
    /// BootstrapManager compares `AppSettings.winRTRegistrationAppliedVersion`
    /// against this value and only re-runs registration when the prefix is behind.
    static let winRTRegistrationVersion = 2

    // MARK: - Steam Install Path Registration

    /// Increment when the set of HKLM Steam or WoW64 crypto registry keys changes.
    /// steam.exe writes these on first run; the native bootstrap bypasses steam.exe,
    /// so we must write them explicitly before steamcmd.exe (32-bit WoW64) starts.
    static let steamInstallPathRegistrationVersion = 2

    // MARK: - Windows Version Registration

    /// Increment when the Windows-version registry mapping changes. Valve
    /// deprecated Windows 7/8 support for the Steam client in late 2024 — any
    /// prefix that reports a pre-Windows-10 version gets "Steam is no longer
    /// supported on your operating system" at startup.
    ///
    /// History:
    ///   v1 — wrote only `HKCU\Software\Wine\Version = win10`. Did not affect
    ///        steam.exe because the stub has a manifest declaring supported OS
    ///        ≤ Win8, and Wine clamps `GetVersionEx` to the highest OS in the
    ///        manifest — ignoring the global `HKCU\Wine\Version` default.
    ///   v2 — added HKLM Windows NT CurrentVersion keys. Also ineffective:
    ///        Steam reads the OS via `GetVersionEx` (the `6.2.9200.0, 0, 2,
    ///        256, 1, 28` in Steam's bootstrap log is an `OSVERSIONINFOEX`
    ///        struct) which goes through the manifest-clamping code path
    ///        before HKLM values are consulted. CLI-verified April 22: Wine's
    ///        `cmd /c ver` (no manifest) correctly reports 10.0.19045, but
    ///        `steam.exe -silent -nofriendsui` (with Win7/Win8 manifest) sees
    ///        6.2.9200.0.
    ///   v3 — writes PER-APP version overrides at
    ///        `HKCU\Software\Wine\AppDefaults\<exe>\Version = win10`. Wine
    ///        honours these regardless of the manifest — same mechanism
    ///        `winecfg`'s "Application Settings" tab uses. Applies to
    ///        `steam.exe`, `steamwebhelper.exe`, and `steamservice.exe` so
    ///        every part of Steam's process tree sees Win10.
    static let windowsVersionRegistrationVersion = 3

    /// Writes registry keys that make the prefix report as Windows 10 to any
    /// app reading either the Wine-level version or the raw HKLM values.
    /// Idempotent — `reg add /f` overwrites any existing value.
    ///
    /// Values chosen to match Windows 10 22H2 (build 19045.5737) — a currently
    /// supported release. Steam's OS-version check looks at
    /// `CurrentMajorVersionNumber` (DWORD) and `CurrentBuildNumber` (REG_SZ);
    /// the rest are written for defensive compatibility with other apps.
    ///
    /// Both 64-bit HKLM and WOW6432Node (for 32-bit steam.exe) are written —
    /// WoW64 filesystem redirection re-routes 32-bit reads to the 32-bit
    /// view, so without the WOW6432Node write Steam (32-bit) still sees the
    /// old values even though the 64-bit hive is correct.
    func setWindowsVersionToWin10(engine: WineEngine) async {
        log.info("[setWindowsVersion] writing Windows 10 version overrides (global + per-app)")

        // Global default — applies to any app WITHOUT a manifest (or with a
        // manifest that declares Win10 support). Benign on its own for Steam
        // but useful for other apps the prefix might run.
        _ = try? await engine.run(
            args: ["reg", "add", "HKCU\\Software\\Wine", "/v", "Version", "/t", "REG_SZ", "/d", "win10", "/f"],
            prefix: self
        )

        // Per-app overrides — these take precedence over both the global default
        // AND the manifest-based clamping. Every Steam component needs Win10 so
        // the DLLs shared across the tree all agree on the OS version.
        let steamApps = [
            "steam.exe",          // main bootstrap / client launcher
            "steamwebhelper.exe", // embedded CEF browser
            "steamservice.exe",   // background IPC service
            "steamerrorreporter.exe",
            "GameOverlayUI.exe",
            "crashhandler.exe",
        ]
        for app in steamApps {
            _ = try? await engine.run(
                args: ["reg", "add", "HKCU\\Software\\Wine\\AppDefaults\\\(app)",
                       "/v", "Version", "/t", "REG_SZ", "/d", "win10", "/f"],
                prefix: self
            )
        }

        log.info("[setWindowsVersion] Windows version → win10 (global + \(steamApps.count) per-app overrides) ✓")
    }

    /// Writes registry keys that steam.exe sets on first run, required by steamcmd.exe.
    ///
    /// **Steam install paths:** steamcmd.exe is 32-bit. Under WoW64, reads from
    /// HKLM\SOFTWARE\Valve\Steam are redirected to HKLM\SOFTWARE\WOW6432Node\Valve\Steam.
    /// If InstallPath is absent there, steamcmd throws a C++ exception at startup.
    ///
    /// **WoW64 crypto provider types:** Wine's wine.inf only writes crypto provider
    /// registry entries to the 64-bit hive (HKLM\SOFTWARE\Microsoft\Cryptography\Defaults).
    /// The 32-bit WoW64 view (WOW6432Node\...) is absent, causing CryptAcquireContextA
    /// to fail with NTE_PROV_TYPE_NOT_DEF (0x80090017) in every 32-bit process, including
    /// steamcmd.exe — which then throws a C++ exception, catches it, checks for mscoree.dll,
    /// doesn't find it, and calls ExitProcess(3).
    func writeSteamInstallPathRegistryKeys(engine: WineEngine) async {
        log.info("[writeSteamInstallPathRegistryKeys] writing Steam HKLM/HKCU + WoW64 crypto keys")
        let installPath = "C:\\Program Files\\Steam"
        let installPathFwd = "C:/Program Files/Steam"

        // Steam install path keys
        let pathKeys: [(String, String, String)] = [
            ("HKLM\\SOFTWARE\\Valve\\Steam",                "InstallPath", installPath),
            ("HKLM\\SOFTWARE\\WOW6432Node\\Valve\\Steam",   "InstallPath", installPath),
            ("HKCU\\SOFTWARE\\Valve\\Steam",                "SteamPath",   installPathFwd),
            ("HKCU\\SOFTWARE\\Valve\\Steam",                "SteamExe",    "\(installPathFwd)/steam.exe"),
        ]

        // WoW64 crypto provider types — mirrors the 64-bit entries that wine.inf writes
        // to HKLM\SOFTWARE\Microsoft\Cryptography\Defaults but omits from WOW6432Node.
        let cryptoBase = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Cryptography\\Defaults"
        let cryptoTypeKeys: [(String, String, String)] = [
            ("\(cryptoBase)\\Provider Types\\Type 001", "Name",     "Microsoft Enhanced Cryptographic Provider v1.0"),
            ("\(cryptoBase)\\Provider Types\\Type 001", "TypeName", "RSA Full (Signature and Key Exchange)"),
            ("\(cryptoBase)\\Provider Types\\Type 003", "Name",     "Microsoft Base DSS Cryptographic Provider"),
            ("\(cryptoBase)\\Provider Types\\Type 003", "TypeName", "DSS Signature"),
            ("\(cryptoBase)\\Provider Types\\Type 012", "Name",     "Microsoft RSA SChannel Cryptographic Provider"),
            ("\(cryptoBase)\\Provider Types\\Type 012", "TypeName", "RSA SChannel"),
            ("\(cryptoBase)\\Provider Types\\Type 013", "Name",     "Microsoft Enhanced DSS and Diffie-Hellman Cryptographic Provider"),
            ("\(cryptoBase)\\Provider Types\\Type 013", "TypeName", "DSS Signature with Diffie-Hellman Key Exchange"),
            ("\(cryptoBase)\\Provider Types\\Type 018", "Name",     "Microsoft DH SChannel Cryptographic Provider"),
            ("\(cryptoBase)\\Provider Types\\Type 018", "TypeName", "Diffie-Hellman SChannel"),
            ("\(cryptoBase)\\Provider Types\\Type 024", "Name",     "Microsoft Enhanced RSA and AES Cryptographic Provider"),
            ("\(cryptoBase)\\Provider Types\\Type 024", "TypeName", "RSA Full and AES"),
            ("\(cryptoBase)\\Provider\\Microsoft Base Cryptographic Provider v1.0",               "Image Path", "C:\\windows\\syswow64\\rsaenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced Cryptographic Provider v1.0",           "Image Path", "C:\\windows\\syswow64\\rsaenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft Strong Cryptographic Provider",                  "Image Path", "C:\\windows\\syswow64\\rsaenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft RSA SChannel Cryptographic Provider",            "Image Path", "C:\\windows\\syswow64\\rsaenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced RSA and AES Cryptographic Provider",    "Image Path", "C:\\windows\\syswow64\\rsaenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft Base DSS Cryptographic Provider",               "Image Path", "C:\\windows\\syswow64\\dssenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft DH SChannel Cryptographic Provider",            "Image Path", "C:\\windows\\syswow64\\dssenh.dll"),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced DSS and Diffie-Hellman Cryptographic Provider", "Image Path", "C:\\windows\\syswow64\\dssenh.dll"),
        ]

        for (key, valueName, data) in pathKeys + cryptoTypeKeys {
            do {
                try await engine.run(
                    args: ["reg", "add", key, "/v", valueName, "/t", "REG_SZ", "/d", data, "/f"],
                    prefix: self
                )
                log.debug("[writeSteamInstallPathRegistryKeys] wrote \(key)\\\\\\(valueName)")
            } catch {
                log.error("[writeSteamInstallPathRegistryKeys] failed \(key)\\\\\\(valueName): \(error.localizedDescription)")
            }
        }

        // Write Type DWORD values for each provider entry
        let cryptoProviderTypes: [(String, Int)] = [
            ("\(cryptoBase)\\Provider\\Microsoft Base Cryptographic Provider v1.0",               1),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced Cryptographic Provider v1.0",           1),
            ("\(cryptoBase)\\Provider\\Microsoft Strong Cryptographic Provider",                  1),
            ("\(cryptoBase)\\Provider\\Microsoft RSA SChannel Cryptographic Provider",            12),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced RSA and AES Cryptographic Provider",    24),
            ("\(cryptoBase)\\Provider\\Microsoft Base DSS Cryptographic Provider",               3),
            ("\(cryptoBase)\\Provider\\Microsoft DH SChannel Cryptographic Provider",            18),
            ("\(cryptoBase)\\Provider\\Microsoft Enhanced DSS and Diffie-Hellman Cryptographic Provider", 13),
        ]
        for (key, typeVal) in cryptoProviderTypes {
            do {
                try await engine.run(
                    args: ["reg", "add", key, "/v", "Type", "/t", "REG_DWORD", "/d", String(typeVal), "/f"],
                    prefix: self
                )
            } catch {
                log.error("[writeSteamInstallPathRegistryKeys] DWORD failed \(key): \(error.localizedDescription)")
            }
        }

        log.info("[writeSteamInstallPathRegistryKeys] Steam install path + WoW64 crypto registry keys written ✓")
    }

    /// Registers WinRT ActivatableClassId entries that Wine's wineboot does not
    /// create by default, mapping class names to their implementing DLLs.
    ///
    /// Without these entries, `combase!RoGetActivationFactory` returns
    /// "Failed to find library" even when the DLL (e.g. coremessaging.dll) is
    /// present and exports `DllGetActivationFactory`. Wine resolves class names
    /// by looking up `HKLM\SOFTWARE\Microsoft\WindowsRuntime\ActivatableClassId\<Class>`
    /// and reading the `DllPath` value.
    ///
    /// This is idempotent — `reg add /f` overwrites any existing value.
    func registerWinRTClasses(engine: WineEngine) async {
        // Step 1: Copy custom stub DLLs into the prefix system32.
        //
        // Prefix system32 has real file copies (not symlinks) of Wine DLLs
        // written during prefix creation. The custom stubs in the engine's
        // wine/lib/wine/x86_64-windows/ are NOT automatically propagated into
        // the prefix — we must copy them explicitly.
        let dllsToInstall: [(URL, String)] = [
            // Our extended coremessaging.dll with IDispatcherQueueStatics support
            (WineEngine.engineDir.appending(path: "wine/lib/wine/x86_64-windows/coremessaging.dll"),
             "coremessaging.dll"),
        ]
        let system32 = path.appending(path: "drive_c/windows/system32")
        for (src, dllName) in dllsToInstall {
            let dest = system32.appending(path: dllName)
            if FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) {
                do {
                    if FileManager.default.fileExists(atPath: dest.path(percentEncoded: false)) {
                        try FileManager.default.removeItem(at: dest)
                    }
                    try FileManager.default.copyItem(at: src, to: dest)
                    log.info("[registerWinRTClasses] installed \(dllName) into prefix system32")
                } catch {
                    log.warning("[registerWinRTClasses] failed to install \(dllName): \(error.localizedDescription)")
                }
            } else {
                log.warning("[registerWinRTClasses] engine stub not found: \(src.lastPathComponent) — skipping")
            }
        }

        // Step 2: Register ActivatableClassId entries.
        // Class name -> system32 DLL path
        let entries: [(String, String)] = [
            // Unity 6.3+ (and any WinRT app) calls RoGetActivationFactory with
            // "Windows.System.DispatcherQueue". Our extended coremessaging.dll
            // handles this class; Wine's shipped version does not.
            ("Windows.System.DispatcherQueue",
             "C:\\windows\\system32\\coremessaging.dll"),
        ]
        for (className, dllPath) in entries {
            let key = "HKLM\\SOFTWARE\\Microsoft\\WindowsRuntime\\ActivatableClassId\\\(className)"
            log.info("[registerWinRTClasses] registering \(className)")
            _ = try? await engine.run(
                args: ["reg", "add", key,
                       "/v", "DllPath", "/t", "REG_SZ", "/d", dllPath, "/f"],
                prefix: self
            )
        }
        log.info("[registerWinRTClasses] WinRT class registration complete ✓")
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
    /// Backs up the DPAPI `local.vdf` (Steam's auto-login token) before wiping
    /// so the user doesn't have to re-authenticate on the next launch. The blob
    /// is keyed to deterministic inputs (Wine user name `"crossover"` + account
    /// name as entropy), so it decrypts fine inside the freshly-rebuilt prefix.
    /// `SteamSessionBridge.prepare` re-writes it from persisted AppSettings;
    /// the `backupSteamSession` call here is belt-and-suspenders for the case
    /// where `AppSettings` is also cleared out-of-band.
    func reset() {
        let prefixPath = path.path(percentEncoded: false)
        log.info("[reset] removing prefix at \(prefixPath)")

        guard FileManager.default.fileExists(atPath: prefixPath) else {
            log.info("[reset] prefix does not exist — nothing to remove")
            return
        }

        backupSteamCMDCredentials()

        do {
            try FileManager.default.removeItem(at: path)
            log.info("[reset] prefix removed")
        } catch {
            log.error("[reset] failed to remove prefix: \(error.localizedDescription)")
        }
    }

    // MARK: - Steam Session Backup / Restore
    //
    // Meridian backs up the DPAPI-encrypted `local.vdf` (Steam's auto-login JWT) so
    // prefix resets and engine upgrades don't force the user to re-authenticate.
    // The blob is keyed to Wine's `"crossover"` user name + the account name (as
    // DPAPI entropy), both of which are deterministic across prefix rebuilds, so
    // restoring the file into a fresh prefix works without any additional state.

    private static var credentialBackupDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "com.meridian.app/steam-session-backup")
    }

    /// Copies `local.vdf` (the DPAPI-encrypted JWT) into the backup directory so it
    /// survives prefix resets. Only call this after observing `[Logged On,` in
    /// `connection_log.txt` — never mid-flight where the file may be half-written.
    func backupSteamSession() {
        let fm = FileManager.default
        let backupDir = Self.credentialBackupDir
        do {
            try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        } catch {
            log.warning("[backupSteamSession] could not create backup dir: \(error.localizedDescription)")
            return
        }

        let localVdf = localAppDataSteamDir.appending(path: "local.vdf")
        let backup   = backupDir.appending(path: "local.vdf")
        guard fm.fileExists(atPath: localVdf.path(percentEncoded: false)) else {
            log.info("[backupSteamSession] no local.vdf to back up (not yet written)")
            return
        }
        do {
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: localVdf, to: backup)
            log.info("[backupSteamSession] local.vdf backed up ✓")
        } catch {
            log.warning("[backupSteamSession] local.vdf backup failed: \(error.localizedDescription)")
        }
    }

    /// Restores a previously backed-up `local.vdf` into the prefix. Called before
    /// starting `steam.exe -silent` when the prefix has been reset but the user has
    /// not signed out.
    func restoreSteamSession() {
        let fm = FileManager.default
        let backupDir = Self.credentialBackupDir
        guard fm.fileExists(atPath: backupDir.path(percentEncoded: false)) else {
            log.info("[restoreSteamSession] no backup dir — nothing to restore")
            return
        }

        let backup   = backupDir.appending(path: "local.vdf")
        let localVdf = localAppDataSteamDir.appending(path: "local.vdf")
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else {
            log.info("[restoreSteamSession] no local.vdf in backup")
            return
        }
        do {
            try fm.createDirectory(at: localAppDataSteamDir, withIntermediateDirectories: true)
            try? fm.removeItem(at: localVdf)
            try fm.copyItem(at: backup, to: localVdf)
            log.info("[restoreSteamSession] local.vdf restored ✓")
        } catch {
            log.warning("[restoreSteamSession] local.vdf restore failed: \(error.localizedDescription)")
        }
    }

    /// Removes the on-disk backup. Called on sign-out so the next user doesn't inherit
    /// the previous account's auto-login token.
    static func clearSteamSessionBackup() {
        let fm = FileManager.default
        let backupDir = Self.credentialBackupDir
        if fm.fileExists(atPath: backupDir.path(percentEncoded: false)) {
            try? fm.removeItem(at: backupDir)
            log.info("[clearSteamSessionBackup] backup dir removed")
        }

        // Clean up any legacy backups from the pre-DPAPI (config.vdf/ssfn) scheme too.
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let legacyDir  = appSupport.appending(path: "com.meridian.app/steamcmd-credentials")
        let legacyFile = appSupport.appending(path: "com.meridian.app/steamcmd-config-backup.vdf")
        try? fm.removeItem(at: legacyDir)
        try? fm.removeItem(at: legacyFile)
    }

    /// Kept as a compatibility shim for the prefix-reset flow in `Settings → Reset
    /// Wine Environment` which still wants a pre-reset snapshot. Routes to the new
    /// DPAPI backup.
    func backupSteamCMDCredentials() { backupSteamSession() }

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
