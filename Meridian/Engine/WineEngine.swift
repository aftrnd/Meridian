import Foundation
import Observation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "WineEngine")

/// Manages the Wine runtime used to execute Windows games.
///
/// Detection order:
///   1. Bundled engine — downloaded from GitHub releases to
///      ~/Library/Application Support/com.meridian.app/engine/
///      This is the primary, standalone path. No third-party app required.
///   2. CrossOver.app — fallback if installed and no bundled engine present.
///
/// All runtime components are open source:
///   - Wine (LGPL), DXMT (open source), DXVK (open source), MoltenVK (Apache 2.0)
@Observable
@MainActor
final class WineEngine {

    // MARK: - State

    enum EngineState: Equatable {
        case notInstalled
        case ready
        case error(String)
    }

    private(set) var state: EngineState = .notInstalled

    /// Describes the detected Wine backend.
    private(set) var backendName: String = "None"

    // MARK: - Detected Paths

    /// Path to the Wine executable (wineloader or wine64).
    private(set) var wineExecutableURL: URL?

    /// Path to the wineserver.
    private(set) var wineserverExecutableURL: URL?

    /// Library search path for DYLD_FALLBACK_LIBRARY_PATH.
    private(set) var libraryPath: String?

    /// Path to DXMT DLLs (DirectX -> Metal, best renderer for macOS).
    private(set) var dxmtPath: String?

    /// Path to DXVK DLLs (DirectX -> Vulkan -> Metal via MoltenVK).
    private(set) var dxvkPath: String?

    var isReady: Bool { state == .ready }

    // MARK: - Convenience accessors for compatibility with existing code

    var wine64URL: URL { wineExecutableURL ?? URL(filePath: "/dev/null") }
    var wineserverURL: URL { wineserverExecutableURL ?? URL(filePath: "/dev/null") }

    // MARK: - Settings

    private let settings = AppSettings.shared

    // MARK: - Known Paths

    private static let crossOverApp = "/Applications/CrossOver.app"
    private static let crossOverRoot = "\(crossOverApp)/Contents/SharedSupport/CrossOver"
    private static let crossOverWineloader = "\(crossOverRoot)/CrossOver-Hosted Application/wineloader"
    private static let crossOverWineserver = "\(crossOverRoot)/CrossOver-Hosted Application/wineserver"
    private static let crossOverLib = "\(crossOverRoot)/lib"

    static let engineDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/engine", directoryHint: .isDirectory)
    }()

    // MARK: - Init

    init() {
        detect()
    }

    // MARK: - Detection

    /// Detects the best available Wine backend.
    func detect() {
        let fm = FileManager.default
        let engineBase = Self.engineDir.path(percentEncoded: false)

        // 1. Try bundled engine (primary — standalone, no third-party app needed)
        let bundledWine = Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let bundledServer = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)

        if fm.isExecutableFile(atPath: bundledWine),
           fm.isExecutableFile(atPath: bundledServer) {

            wineExecutableURL = URL(filePath: bundledWine)
            wineserverExecutableURL = URL(filePath: bundledServer)
            libraryPath = Self.engineDir.appending(path: "wine/lib").path(percentEncoded: false)

            let bundledDxmt = Self.engineDir.appending(path: "wine/lib/dxmt").path(percentEncoded: false)
            if fm.fileExists(atPath: bundledDxmt) { dxmtPath = bundledDxmt }

            let bundledDxvk = Self.engineDir.appending(path: "wine/lib/dxvk").path(percentEncoded: false)
            if fm.fileExists(atPath: bundledDxvk) { dxvkPath = bundledDxvk }

            backendName = "Meridian"
            state = .ready

            log.info("[detect] Bundled engine found at \(engineBase)")
            log.info("[detect]   wine64=\(bundledWine)")
            log.info("[detect]   wineserver=\(bundledServer)")
            log.info("[detect]   lib=\(self.libraryPath ?? "none")")
            log.info("[detect]   dxmt=\(self.dxmtPath ?? "none")")
            log.info("[detect]   dxvk=\(self.dxvkPath ?? "none")")
            log.info("[detect] backend=Meridian ✓")
            return
        }

        // 2. Fallback: CrossOver.app (if user happens to have it installed)
        if fm.isExecutableFile(atPath: Self.crossOverWineloader),
           fm.isExecutableFile(atPath: Self.crossOverWineserver) {

            wineExecutableURL = URL(filePath: Self.crossOverWineloader)
            wineserverExecutableURL = URL(filePath: Self.crossOverWineserver)
            libraryPath = Self.crossOverLib

            let dxmt = "\(Self.crossOverLib)/dxmt"
            if fm.fileExists(atPath: dxmt) { dxmtPath = dxmt }

            let dxvk = "\(Self.crossOverLib)/dxvk"
            if fm.fileExists(atPath: dxvk) { dxvkPath = dxvk }

            backendName = "CrossOver"
            state = .ready

            log.info("[detect] CrossOver found (fallback)")
            log.info("[detect]   wineloader=\(Self.crossOverWineloader)")
            log.info("[detect]   wineserver=\(Self.crossOverWineserver)")
            log.info("[detect]   lib=\(Self.crossOverLib)")
            log.info("[detect]   dxmt=\(self.dxmtPath ?? "none")")
            log.info("[detect]   dxvk=\(self.dxvkPath ?? "none")")
            log.info("[detect] backend=CrossOver ✓")
            return
        }

        // 3. Nothing found
        log.warning("[detect] No Wine backend found")
        log.warning("[detect]   Bundled: \(engineBase) exists=\(fm.fileExists(atPath: engineBase))")
        log.warning("[detect]   CrossOver: \(Self.crossOverApp) exists=\(fm.fileExists(atPath: Self.crossOverApp))")
        state = .notInstalled
        backendName = "None"
    }

    // MARK: - Environment

    /// Builds the environment dictionary for launching a Wine process.
    func environment(for prefix: WinePrefix) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix.path.path(percentEncoded: false),
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "MTL_HUD_ENABLED": settings.metalHUD ? "1" : "0",
        ]

        // CrossOver's wineloader requires CX_ROOT to find its compat database,
        // DLL overrides, and internal libraries. Without it, the launcher fails
        // to set up DLL paths and the child process may not start correctly.
        if backendName == "CrossOver" {
            env["CX_ROOT"] = Self.crossOverRoot
            env["CX_BOTTLE"] = prefix.path.path(percentEncoded: false)
        }

        if let lib = libraryPath {
            env["DYLD_FALLBACK_LIBRARY_PATH"] = lib
        }

        if let wineExe = wineExecutableURL {
            env["WINELOADER"] = wineExe.path(percentEncoded: false)
        }
        if let wineServer = wineserverExecutableURL {
            env["WINESERVER"] = wineServer.path(percentEncoded: false)
        }

        // Build WINEDLLPATH: DXMT first (best renderer), then base Wine DLLs.
        // Wine searches WINEDLLPATH left-to-right, so DXMT's d3d11.dll/dxgi.dll
        // take priority, giving us Direct3D -> Metal translation.
        var dllPaths: [String] = []

        if let dxmt = dxmtPath {
            dllPaths.append("\(dxmt)/x86_64-windows")
            dllPaths.append("\(dxmt)/i386-windows")
            log.debug("[env] DXMT enabled: \(dxmt)")
        }

        if let lib = libraryPath {
            let wineDllPath = "\(lib)/wine"
            if FileManager.default.fileExists(atPath: wineDllPath) {
                dllPaths.append(wineDllPath)
            }
        }

        if !dllPaths.isEmpty {
            env["WINEDLLPATH"] = dllPaths.joined(separator: ":")
        }

        // DXMT replaces both D3D11 (rendering) and DXGI (swap chain/presentation).
        // Both must be overridden together — using DXMT's d3d11 with Wine's
        // builtin dxgi causes solid-color frames because the Metal textures
        // created by DXMT's d3d11 can't be presented by Wine's dxgi.
        env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,dxgi=n,b"

        log.debug("[env] full environment: \(env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " | "))")

        return env
    }

    /// Runs a Wine command and waits for it to finish. Captures stdout+stderr.
    @discardableResult
    func run(
        args: [String],
        prefix: WinePrefix,
        extraEnv: [String: String] = [:]
    ) async throws -> Process {
        guard let wineExe = wineExecutableURL else {
            throw EngineError.notInstalled
        }

        let process = Process()
        process.executableURL = wineExe
        process.arguments = args

        var env = environment(for: prefix)
        env.merge(extraEnv) { _, new in new }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let cmdString = "\(wineExe.lastPathComponent) \(args.joined(separator: " "))"
        log.info("[run] \(cmdString)")
        log.debug("[run] WINEPREFIX=\(prefix.path.path(percentEncoded: false))")

        do {
            try process.run()
        } catch {
            log.error("[run] failed to launch: \(error.localizedDescription) | cmd=\(cmdString)")
            throw error
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        log.info("[run] exit=\(process.terminationStatus) | cmd=\(cmdString)")
        if !stdout.isEmpty {
            log.debug("[run] stdout: \(stdout.prefix(2000))")
        }
        if !stderr.isEmpty {
            log.debug("[run] stderr: \(stderr.prefix(2000))")
        }

        if process.terminationStatus != 0 {
            log.error("[run] non-zero exit \(process.terminationStatus) | cmd=\(cmdString) | stderr=\(stderr.prefix(500))")
        }

        return process
    }

    // MARK: - Errors

    enum EngineError: LocalizedError {
        case notInstalled

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "No Wine runtime found. Download the engine from Settings."
            }
        }
    }
}
