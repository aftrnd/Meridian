import Foundation

private let log = MeridianLog(category: "GameLogFile")

/// Per-game raw Wine output capture.
///
/// Each game launch gets its own file at:
///
///     ~/Library/Application Support/com.meridian.app/logs/games/<appID>.log
///
/// On every new launch, any existing `<appID>.log` is rotated to
/// `<appID>-previous.log` (one generation kept) and a fresh file is opened.
///
/// ## Why a dedicated file
///
/// Wine spawns many subprocesses (wineserver, services.exe, winedevice.exe,
/// the game's own child processes) that all inherit the parent's
/// stdout/stderr file descriptors. A pipe-based reader using
/// `readDataToEndOfFile()` or polling `availableData` blocks until ALL
/// inheritors close the write end, which they never do — wineserver
/// outlives the game. The previous "drain the pipe in a Task.detached"
/// pattern in `Launcher.launchDirect` only ever got partial output before
/// the task starved or the app quit.
///
/// The fix is to hand the child process a `FileHandle` opened on disk
/// directly via `process.standardOutput` / `standardError`. The kernel
/// writes every byte each subprocess emits straight to the file with no
/// Meridian-side draining required; the file is readable while the game
/// is still running, and `tail -f` works.
///
/// ## Header + trailer
///
/// `beginSession` writes a diagnostic header (game name, appID,
/// timestamp, env summary, exe path) before the child process is
/// launched. `endSession` appends a trailer when the game exits, so
/// post-mortem readers can tell at a glance how the game ended.
enum GameLogFile {

    // MARK: - Paths

    /// Directory holding per-game logs.
    static let logsDir: URL = {
        LogFileWriter.logsDir.appending(path: "games", directoryHint: .isDirectory)
    }()

    static func currentURL(for appID: Int) -> URL {
        logsDir.appending(path: "\(appID).log")
    }

    static func previousURL(for appID: Int) -> URL {
        logsDir.appending(path: "\(appID)-previous.log")
    }

    // MARK: - Session lifecycle

    /// Set of env keys whose values are written into the session header.
    /// All Wine/D3D/DYLD knobs that materially affect rendering and
    /// process behavior — anything that, if misconfigured, would cause
    /// the symptom we'd be debugging.
    private static let relevantEnvKeys: [String] = [
        "WINEPREFIX",
        "WINELOADER",
        "WINESERVER",
        "WINEDLLPATH",
        "WINEDLLOVERRIDES",
        "DYLD_FALLBACK_LIBRARY_PATH",
        "DYLD_FALLBACK_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES",
        "CX_APPLEGPTK_LIBD3DSHARED_PATH",
        "MTL_HUD_ENABLED",
        "ROSETTA_ADVERTISE_AVX",
        "DOTNET_EnableWriteXorExecute",
        "WINE_LARGE_ADDRESS_AWARE",
        "WINE_DISABLE_WINE_CRASH_DIALOG",
    ]

    /// Opens (or rotates + creates) the per-game log file and writes the
    /// session-start header. Returns a `FileHandle` ready to be wired up
    /// as `process.standardOutput` / `process.standardError`.
    ///
    /// On any I/O error, returns `nil` and logs to `meridian.log` — the
    /// caller falls back to its previous pipe-based behavior so launches
    /// never fail because of a per-game log issue.
    static func beginSession(
        appID: Int,
        gameName: String,
        executable: String,
        launchArgs: [String],
        environment: [String: String],
        stackReport: GameStackReport? = nil
    ) -> FileHandle? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            log.warning("[beginSession] could not create \(logsDir.path(percentEncoded: false)): \(error.localizedDescription)")
            return nil
        }

        // Rotate one generation: <appID>.log → <appID>-previous.log
        let currentPath = currentURL(for: appID).path(percentEncoded: false)
        let previousPath = previousURL(for: appID).path(percentEncoded: false)
        if fm.fileExists(atPath: currentPath) {
            if fm.fileExists(atPath: previousPath) {
                try? fm.removeItem(atPath: previousPath)
            }
            try? fm.moveItem(atPath: currentPath, toPath: previousPath)
        }
        fm.createFile(atPath: currentPath, contents: nil)

        guard let handle = try? FileHandle(forWritingTo: currentURL(for: appID)) else {
            log.warning("[beginSession] could not open log handle for appID=\(appID)")
            return nil
        }

        let header = buildHeader(
            appID: appID,
            gameName: gameName,
            executable: executable,
            launchArgs: launchArgs,
            environment: environment,
            stackReport: stackReport
        )
        if let data = header.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        log.info("[beginSession] appID=\(appID) → \(currentPath)")
        return handle
    }

    /// Appends the session-end trailer and closes the handle. Best-effort
    /// — never throws; the worst case is a missing trailer that the user
    /// can still infer from the surrounding game output.
    static func endSession(
        handle: FileHandle?,
        appID: Int,
        reason: String,
        exitCode: Int32?
    ) {
        guard let handle else { return }
        let trailer = buildTrailer(reason: reason, exitCode: exitCode)
        if let data = trailer.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        try? handle.close()
        log.info("[endSession] appID=\(appID) reason=\(reason) exit=\(exitCode.map(String.init) ?? "?")")
    }

    // MARK: - Engine-log collection (Unity / Unreal)

    /// Path to the collected game-engine log (`<appID>-engine.log`).
    ///
    /// The raw Wine stdout/stderr file (`<appID>.log`) captures what Wine and
    /// the game binary printed to the console. But game engines write their
    /// OWN, far more detailed log to disk — Unity's `Player.log`, Unreal's
    /// `Saved/Logs/<Game>.log` — which contains the messages that actually
    /// explain a crash or glitch: shader compile failures, video-decode
    /// errors, missing-asset loads, `SteamAPI.Init()` results, managed
    /// (C#/Blueprint) stack traces. This is the authoritative source for
    /// game-side diagnostics.
    static func engineLogURL(for appID: Int) -> URL {
        logsDir.appending(path: "\(appID)-engine.log")
    }

    /// Copies the game's own engine log (Unity `Player.log` or Unreal
    /// `Saved/Logs/*.log`) for THIS session into `<appID>-engine.log`.
    ///
    /// - `lowLevelDir`: the prefix's `…/AppData/LocalLow` directory, scanned
    ///   for `<Company>/<Product>/Player.log` (Unity).
    /// - `installDir`: the game's `steamapps/common/<dir>` directory, scanned
    ///   for `**/Saved/Logs/*.log` (Unreal). Only walked when no session-valid
    ///   Unity log is found, so Unity games never pay for the deep walk.
    /// - `launchStartedAt`: when the game process started. Logs whose mtime is
    ///   older than this (minus a 5 s slack) are treated as stale leftovers
    ///   from a previous run and skipped — we never copy a log that doesn't
    ///   belong to the session we just ran.
    ///
    /// Best-effort: never throws. Returns the destination URL on success,
    /// `nil` when there was nothing relevant to collect.
    @discardableResult
    static func collectEngineLogs(
        appID: Int,
        lowLevelDir: URL?,
        installDir: URL?,
        launchStartedAt: Date?
    ) -> URL? {
        let fm = FileManager.default
        let cutoff = launchStartedAt?.addingTimeInterval(-5)

        func isFresh(_ mtime: Date) -> Bool {
            guard let cutoff else { return true }
            return mtime >= cutoff
        }

        // 1. Unity — <LocalLow>/<Company>/<Product>/Player.log (shallow, cheap).
        var best: (url: URL, mtime: Date, kind: String)?
        if let lowLevelDir, fm.fileExists(atPath: lowLevelDir.path(percentEncoded: false)),
           let companies = try? fm.contentsOfDirectory(at: lowLevelDir, includingPropertiesForKeys: nil) {
            for company in companies {
                guard let products = try? fm.contentsOfDirectory(at: company, includingPropertiesForKeys: nil) else { continue }
                for product in products {
                    let playerLog = product.appending(path: "Player.log")
                    guard let mtime = modificationDate(playerLog, fm: fm), isFresh(mtime) else { continue }
                    if best == nil || mtime > best!.mtime {
                        best = (playerLog, mtime, "Unity Player.log")
                    }
                }
            }
        }

        // 2. Unreal — <installDir>/**/Saved/Logs/*.log. Only when Unity found
        //    nothing for this session (avoids a deep walk for Unity games).
        if best == nil, let installDir, fm.fileExists(atPath: installDir.path(percentEncoded: false)),
           let enumerator = fm.enumerator(at: installDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "log" else { continue }
                guard url.path(percentEncoded: false).contains("/Saved/Logs/") else { continue }
                guard let mtime = modificationDate(url, fm: fm), isFresh(mtime) else { continue }
                if best == nil || mtime > best!.mtime {
                    best = (url, mtime, "Unreal log")
                }
            }
        }

        guard let chosen = best else { return nil }

        let dest = engineLogURL(for: appID)
        let provenance = """
        ================================================================================
        Engine log for appID \(appID)
        Source: \(chosen.url.path(percentEncoded: false))
        Kind: \(chosen.kind)
        Modified: \(dateFormatter.string(from: chosen.mtime))
        Collected: \(dateFormatter.string(from: Date()))
        ================================================================================


        """
        let body = (try? Data(contentsOf: chosen.url)) ?? Data()
        do {
            if fm.fileExists(atPath: dest.path(percentEncoded: false)) {
                try fm.removeItem(at: dest)
            }
            fm.createFile(atPath: dest.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: dest)
            if let h = provenance.data(using: .utf8) { try? handle.write(contentsOf: h) }
            try? handle.write(contentsOf: body)
            try? handle.close()
            log.info("[collectEngineLogs] appID=\(appID) ← \(chosen.kind) → \(dest.path(percentEncoded: false))")
            return dest
        } catch {
            log.warning("[collectEngineLogs] appID=\(appID) copy failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func modificationDate(_ url: URL, fm: FileManager) -> Date? {
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Header / trailer formatting

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        f.timeZone = .current
        return f
    }()

    private static func buildHeader(
        appID: Int,
        gameName: String,
        executable: String,
        launchArgs: [String],
        environment: [String: String],
        stackReport: GameStackReport?
    ) -> String {
        let now = dateFormatter.string(from: Date())
        let envLines = relevantEnvKeys
            .compactMap { key -> String? in
                guard let value = environment[key], !value.isEmpty else { return nil }
                return "  \(key)=\(value)"
            }
            .joined(separator: "\n")
        let argsStr = launchArgs.isEmpty ? "(none)" : launchArgs.joined(separator: " ")
        // When a resolved-stack report is available, surface it prominently
        // BEFORE the raw env dump. The report names the active renderer
        // (DXMT / GPTK / DXVK / wined3d), translation layer, DRM shim, Metal
        // HUD, and compat status — so a debugger can tell at a glance what
        // stack the game ran with, without mentally parsing WINEDLLPATH /
        // WINEDLLOVERRIDES. The raw env below remains the ground-truth source.
        let stackBlock = stackReport.map { "\($0.detailBlock)\n" } ?? ""
        return """
        ================================================================================
        Game: \(gameName) (appID \(appID))
        Started: \(now)
        Exe: \(executable)
        LaunchArgs: \(argsStr)
        Log: \(currentURL(for: appID).path(percentEncoded: false))
        \(stackBlock)Env:
        \(envLines)
        ================================================================================


        """
    }

    private static func buildTrailer(reason: String, exitCode: Int32?) -> String {
        let now = dateFormatter.string(from: Date())
        let exitStr: String
        if let code = exitCode {
            exitStr = "Exit code: \(code)"
        } else {
            exitStr = "Exit code: (unknown — process was still running when session ended)"
        }
        return """


        ================================================================================
        Session ended \(now)
        Reason: \(reason)
        \(exitStr)
        ================================================================================

        """
    }
}

// MARK: - GameStackReport

/// A human-readable summary of the graphics/translation stack a game will
/// actually run with, derived from the FINAL resolved launch environment.
///
/// ## Why derive from the environment, not re-decide
///
/// The stack decision lives in `WineEngine.environment(for:)` +
/// `SteamSession.gameEnvironment(for:engine:)`. Those build the canonical
/// `WINEDLLPATH` / `WINEDLLOVERRIDES` that Wine actually obeys. Rather than
/// duplicate (and inevitably drift from) that decision logic, this report
/// *reads it back* from the resolved environment — the single source of
/// truth — and names the active renderer. If the env says
/// `WINEDLLPATH=…/dxmt:…` + `d3d11=n,b`, the report says "DXMT → Metal",
/// because that is what Wine will load. This makes the per-game log header
/// and `meridian.log` state exactly what stack ran, without a debugger
/// having to mentally parse the override string.
struct GameStackReport {

    /// The renderer/translation layer Wine will actually load, inferred from
    /// the resolved `WINEDLLPATH` + `WINEDLLOVERRIDES`.
    enum Renderer: String {
        case dxmt        // D3D11/D3D10 → DXMT → Metal
        case gptk        // D3D12 → GPTK → D3DMetal → Metal
        case dxvk        // D3D9/10/11 → DXVK → MoltenVK → Metal
        case wined3d     // D3D → Wine builtin (wined3d) → MoltenVK → Metal
        case unknown     // No D3D override seen (OpenGL/Vulkan game, or unconfigured)

        var translationLayer: String {
            switch self {
            case .dxmt:    return "DXMT → Metal"
            case .gptk:    return "GPTK → D3DMetal → Metal"
            case .dxvk:    return "DXVK → MoltenVK → Metal"
            case .wined3d: return "Wine builtin (wined3d) → MoltenVK → Metal"
            case .unknown: return "Wine default (no D3D override — OpenGL/Vulkan or unconfigured)"
            }
        }
    }

    let appID: Int
    let gameName: String
    let renderer: Renderer
    /// The declared graphics API (resolved: explicit profile › PCGamingWiki ›
    /// local engine-default), if known.
    let declaredAPI: GraphicsAPI?
    let declaredEngine: GameEngine?
    let status: CompatStatus?
    let verifiedWith: String?
    let drmShimActive: Bool
    let metalHUD: Bool
    let launchArgs: [String]
    let dllOverrides: String?
    let engineVersion: String?
    /// Executable bitness (32 / 64) from the PE header, when detected.
    let bitness: Int?
    /// Provenance of `declaredAPI` / `declaredEngine` ("explicit", "pcgw",
    /// "detected", "unknown") so a wrong stack is easy to attribute.
    let apiSource: String?
    let engineSource: String?

    // MARK: - Resolution

    /// Builds a report from the resolved launch environment + optional
    /// compat profile. Pure — no actor state, no I/O.
    static func resolve(
        appID: Int,
        gameName: String,
        profile: GameProfile?,
        resolved: ResolvedGameStack? = nil,
        environment: [String: String],
        drmShimActive: Bool,
        engineVersion: String?
    ) -> GameStackReport {
        let dllPath = environment["WINEDLLPATH"] ?? ""
        let overridesStr = environment["WINEDLLOVERRIDES"] ?? ""
        let overrides = parseOverrides(overridesStr)

        let renderer: Renderer
        if dllPath.contains("/gptk"), overrides["d3d12"] == "b" {
            renderer = .gptk
        } else if dllPath.contains("/dxvk") {
            renderer = .dxvk
        } else if dllPath.contains("/dxmt"), let m = overrides["d3d11"], m.hasPrefix("n") {
            // n,b = native (DXMT PE) preferred, builtin fallback.
            renderer = .dxmt
        } else if overrides["d3d11"] == "b" {
            // DXMT explicitly disabled for this game → Wine's builtin wined3d.
            renderer = .wined3d
        } else {
            renderer = .unknown
        }

        // Prefer the merged resolver values (engine/API/bitness/status with
        // provenance) over the bare explicit profile. Falls back to the
        // profile when no resolved stack was supplied (cold cache).
        let declaredAPI = resolved?.graphicsAPI ?? profile?.graphicsAPI
        let declaredEngine = resolved?.engine ?? profile?.gameEngine
        let status = resolved?.status ?? profile?.status

        return GameStackReport(
            appID: appID,
            gameName: gameName,
            renderer: renderer,
            declaredAPI: declaredAPI.flatMap { $0 == .unknown ? nil : $0 },
            declaredEngine: declaredEngine.flatMap { $0 == .unknown ? nil : $0 },
            status: status,
            verifiedWith: profile?.verifiedWith,
            drmShimActive: drmShimActive,
            metalHUD: environment["MTL_HUD_ENABLED"] == "1",
            launchArgs: profile?.launchArgs ?? [],
            dllOverrides: overridesStr.isEmpty ? nil : overridesStr,
            engineVersion: engineVersion,
            bitness: resolved?.bitness,
            apiSource: resolved?.apiSource.rawValue,
            engineSource: resolved?.engineSource.rawValue
        )
    }

    /// Human label for a provenance source code.
    private func sourceLabel(_ source: String?) -> String {
        switch source {
        case "explicit": return "compat profile"
        case "pcgw":     return "PCGamingWiki"
        case "detected": return "detected from files"
        default:         return "inferred"
        }
    }

    /// Parses a `WINEDLLOVERRIDES` string (`dll1,dll2=mode;dll3=mode`) into a
    /// per-DLL mode map. The last entry for a DLL wins, matching Wine.
    private static func parseOverrides(_ s: String) -> [String: String] {
        var map: [String: String] = [:]
        for entry in s.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let mode = parts[1]
            for dll in parts[0].split(separator: ",") {
                map[String(dll)] = mode
            }
        }
        return map
    }

    // MARK: - Formatting

    private var apiTag: String {
        guard let api = declaredAPI, api != .unknown else { return "unknown" }
        return "\(api.rawValue)(\(apiSource ?? "?"))"
    }

    /// Compact one-liner for `meridian.log` at launch time.
    var summaryLine: String {
        let statusTag = status?.rawValue ?? "untested"
        let verified = verifiedWith.map { " verifiedWith=\($0)" } ?? ""
        let bitnessTag = bitness.map { " bitness=\($0)" } ?? ""
        return "[stack] appID=\(appID) \"\(gameName)\" api=\(apiTag)"
            + " renderer=\(renderer.rawValue)(\(renderer.translationLayer))"
            + bitnessTag
            + " drm=\(drmShimActive ? "shim(gbe_fork)" : "none")"
            + " hud=\(metalHUD ? "on" : "off")"
            + " status=\(statusTag)\(verified)"
    }

    /// Multi-line block embedded in the per-game log header.
    var detailBlock: String {
        let engineStr: String = {
            guard let e = declaredEngine else { return "Unknown" }
            return "\(displayEngine(e)) (\(sourceLabel(engineSource)))"
        }()
        let apiStr: String = {
            guard let api = declaredAPI, api != .unknown else { return "Unknown (inferred from env)" }
            return "\(displayAPI(api)) (\(sourceLabel(apiSource)))"
        }()
        let bitnessStr: String = {
            switch bitness {
            case 32: return "32-bit"
            case 64: return "64-bit"
            default: return "unknown"
            }
        }()
        let statusStr: String = {
            guard let status else { return "untested" }
            let v = verifiedWith.map { " — verified with \($0)" } ?? ""
            return "\(status.rawValue)\(v)"
        }()
        let argsStr = launchArgs.isEmpty ? "(none)" : launchArgs.joined(separator: " ")
        let overridesLine = dllOverrides ?? "(engine default)"
        return """
        Stack:
          Game engine:     \(engineStr)
          Graphics API:    \(apiStr)
          Active renderer: \(renderer.translationLayer)
          Bitness:         \(bitnessStr)
          DRM:             \(drmShimActive ? "Steamworks shim (gbe_fork) — no steam.exe" : "none (DRM-free)")
          Metal HUD:       \(metalHUD ? "on" : "off")
          Compat status:   \(statusStr)
          Launch args:     \(argsStr)
          DLL overrides:   \(overridesLine)
          Engine build:    \(engineVersion ?? "unknown")
        """
    }

    private func displayEngine(_ e: GameEngine) -> String {
        switch e {
        case .unity:   return "Unity"
        case .unreal:  return "Unreal Engine"
        case .godot:   return "Godot"
        case .source:  return "Source"
        case .custom:  return "Custom Engine"
        case .unknown: return "Unknown"
        }
    }

    private func displayAPI(_ a: GraphicsAPI) -> String {
        switch a {
        case .dx9:     return "DirectX 9"
        case .dx11:    return "DirectX 11"
        case .dx12:    return "DirectX 12"
        case .vulkan:  return "Vulkan"
        case .unknown: return "Unknown"
        }
    }
}
