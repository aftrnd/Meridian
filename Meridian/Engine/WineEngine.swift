import Foundation
import Observation

private let log = MeridianLog(category: "WineEngine")

/// Manages the Wine runtime used to execute Windows games.
///
/// Meridian is fully standalone. The only supported backend is the bundled engine
/// downloaded from GitHub releases to:
///   ~/Library/Application Support/com.meridian.app/engine/
///
/// Detection validates both executables and required Wine data files (NLS tables).
/// If the engine is absent or incomplete, state is `.notInstalled` or `.error` and
/// the bootstrap pipeline will auto-download the correct release from GitHub.
///
/// All runtime components are open source:
///   - Wine FOSS (wine-devel from Gcenx/macOS_Wine_builds), DXMT (open source),
///     DXVK (open source), Apple GPTK (Apple-distributed), MoltenVK (Apache 2.0)
///
/// ## D3D12 Support (experimental)
///
/// When `wine/lib/vkd3d-proton/` is present, `environment(for:)` sets WINEDLLPATH
/// and `d3d12,d3d12core=n` override so VKD3D-proton handles D3D12→Vulkan→MoltenVK→Metal.
/// VKD3D-proton DLLs are native Windows PE DLLs (no Wine PE-Unix bridge needed).
/// DXMT continues to handle D3D11/D3D10 via builtin wiremetal.so.
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

    /// The Meridian engine release tag bundled with the installed engine, e.g. `v1.2.0-engine`.
    /// Read from `wine/meridian-engine-version.txt` written by `release-engine.sh`.
    private(set) var engineVersion: String?

    // MARK: - Detected Paths

    /// Path to the Wine executable (wine64).
    private(set) var wineExecutableURL: URL?

    /// Path to the wineserver.
    private(set) var wineserverExecutableURL: URL?

    /// Library search path for DYLD_FALLBACK_LIBRARY_PATH.
    private(set) var libraryPath: String?

    /// Whether DXMT builtin DLLs are present (DirectX -> Metal, best renderer for macOS).
    /// With the builtin layout, DXMT DLLs live alongside Wine's own DLLs in
    /// lib/wine/x86_64-windows/ — no separate WINEDLLPATH entry needed.
    private(set) var dxmtPath: String?

    /// Path to DXVK DLLs (DirectX -> Vulkan -> Metal via MoltenVK).
    private(set) var dxvkPath: String?

    /// Path to the D3D12 implementation directory.
    /// Present when `wine/lib/vkd3d-proton/x86_64-windows/d3d12.dll` exists in the engine.
    private(set) var d3d12Path: String?

    var isReady: Bool { state == .ready }

    // MARK: - Convenience accessors for compatibility with existing code

    var wine64URL: URL { wineExecutableURL ?? URL(filePath: "/dev/null") }
    var wineserverURL: URL { wineserverExecutableURL ?? URL(filePath: "/dev/null") }

    // MARK: - Settings

    private let settings = AppSettings.shared

    // MARK: - Known Paths

    nonisolated(unsafe) static let engineDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/engine", directoryHint: .isDirectory)
    }()

    // MARK: - Init

    init() {
        detect()
    }

    // MARK: - Detection

    /// Detects the bundled Wine engine under Application Support.
    ///
    /// Meridian is fully standalone — no external Wine installation is required or used.
    /// If the engine is absent or incomplete, state is set to `.notInstalled` or
    /// `.error` so the bootstrap pipeline can trigger an automatic download.
    func detect() {
        let fm = FileManager.default
        let engineBase = Self.engineDir.path(percentEncoded: false)

        let bundledWine   = Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let bundledServer = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)

        guard fm.isExecutableFile(atPath: bundledWine),
              fm.isExecutableFile(atPath: bundledServer) else {
            log.warning("[detect] Bundled engine not found at \(engineBase)")
            clearState()
            return
        }

        // Validate that required Wine data files are present. Wine's wineserver
        // resolves NLS tables as ../share/wine/nls/ relative to lib/, so they must
        // be in the engine package or wineboot will abort before the prefix is created.
        let nlsDir = Self.engineDir.appending(path: "wine/share/wine/nls").path(percentEncoded: false)
        let requiredNLS = ["l_intl.nls", "locale.nls", "normnfc.nls"]
        let missingNLS = requiredNLS.filter { !fm.fileExists(atPath: "\(nlsDir)/\($0)") }

        guard missingNLS.isEmpty else {
            log.error("[detect] Engine incomplete — missing NLS files: \(missingNLS.joined(separator: ", "))")
            state = .error("Engine incomplete — NLS data files missing (\(missingNLS.joined(separator: ", "))). Re-download the engine from Settings.")
            backendName = "None"
            engineVersion = nil
            wineExecutableURL = nil
            wineserverExecutableURL = nil
            libraryPath = nil
            dxmtPath = nil
            dxvkPath = nil
            d3d12Path = nil
            return
        }

        wineExecutableURL       = URL(filePath: bundledWine)
        wineserverExecutableURL = URL(filePath: bundledServer)
        libraryPath             = Self.engineDir.appending(path: "wine/lib").path(percentEncoded: false)

        // DXMT builtin layout: DLLs live in lib/wine/x86_64-windows/ alongside Wine's own DLLs.
        let dxmtUnixSo = Self.engineDir.appending(path: "wine/lib/wine/x86_64-unix/winemetal.so").path(percentEncoded: false)
        let dxmtWinDll = Self.engineDir.appending(path: "wine/lib/wine/x86_64-windows/d3d11.dll").path(percentEncoded: false)
        if fm.fileExists(atPath: dxmtUnixSo) && fm.fileExists(atPath: dxmtWinDll) {
            dxmtPath = Self.engineDir.appending(path: "wine/lib/wine/x86_64-windows").path(percentEncoded: false)
        }

        let bundledDxvk = Self.engineDir.appending(path: "wine/lib/dxvk").path(percentEncoded: false)
        if fm.fileExists(atPath: bundledDxvk) { dxvkPath = bundledDxvk }

        // D3D12: detect VKD3D-proton
        let vkd3dProton = Self.engineDir.appending(path: "wine/lib/vkd3d-proton/x86_64-windows/d3d12.dll").path(percentEncoded: false)
        d3d12Path = fm.fileExists(atPath: vkd3dProton)
            ? Self.engineDir.appending(path: "wine/lib/vkd3d-proton").path(percentEncoded: false)
            : nil

        backendName   = "Meridian"
        engineVersion = readEngineVersion()
        state         = .ready

        let dxmtMode: String = {
            guard let p = self.dxmtPath else { return "none" }
            return p.hasSuffix("dxmt") ? "\(p) (legacy override)" : "\(p) (builtin)"
        }()
        log.info("[detect] Engine found at \(engineBase)")
        log.info("[detect]   wine64=\(wineExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   wineserver=\(wineserverExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   lib=\(self.libraryPath ?? "none")")
        log.info("[detect]   dxmt=\(dxmtMode)")
        log.info("[detect]   dxvk=\(self.dxvkPath ?? "none")")
        log.info("[detect]   d3d12=\(self.d3d12Path ?? "none (D3D12 disabled)")")
        log.info("[detect]   engineVersion=\(self.engineVersion ?? "unknown")")
        log.info("[detect] backend=\(backendName) ✓")
    }

    /// Reads the engine release tag from the version file written by `release-engine.sh`.
    private func readEngineVersion() -> String? {
        let versionFile = Self.engineDir.appending(path: "wine/meridian-engine-version.txt")
        return try? String(contentsOf: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    // MARK: - Reset

    /// Kills all Wine processes and wipes the engine directory completely.
    /// The next bootstrap run will auto-download a fresh engine from GitHub.
    func resetEngine() {
        let fm = FileManager.default
        let enginePath = Self.engineDir.path(percentEncoded: false)
        log.info("[resetEngine] removing engine at \(enginePath)")

        if fm.fileExists(atPath: enginePath) {
            do {
                try fm.removeItem(at: Self.engineDir)
                log.info("[resetEngine] engine directory removed ✓")
            } catch {
                log.error("[resetEngine] failed: \(error.localizedDescription)")
            }
        }

        clearState()
    }

    private func clearState() {
        state                   = .notInstalled
        backendName             = "None"
        engineVersion           = nil
        wineExecutableURL       = nil
        wineserverExecutableURL = nil
        libraryPath             = nil
        dxmtPath                = nil
        dxvkPath                = nil
        d3d12Path               = nil
    }

    // MARK: - Environment

    /// Builds the minimal environment for SteamCMD (no Metal HUD, no Rosetta flags).
    /// SteamCMD is a console tool; it does not use DirectX or Metal.
    func steamCMDEnvironment(for prefix: WinePrefix) -> [String: String] {
        guard let lib = libraryPath else { return [:] }
        let wine64  = Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let server  = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)
        return [
            "WINEPREFIX":                prefix.path.path(percentEncoded: false),
            "WINESERVER":                server,
            "WINELOADER":                wine64,
            "WINEDLLPATH":               "\(lib)/wine",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(lib):\(lib)/wine/x86_64-unix",
            "WINE_LARGE_ADDRESS_AWARE":  "1",
        ]
    }

    /// Builds the environment dictionary for launching a Wine process.
    func environment(for prefix: WinePrefix) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX":                    prefix.path.path(percentEncoded: false),
            "WINE_LARGE_ADDRESS_AWARE":      "1",
            "MTL_HUD_ENABLED":               settings.metalHUD ? "1" : "0",
            "ROSETTA_ADVERTISE_AVX":         "1",
            "DOTNET_EnableWriteXorExecute":  "0",
        ]

        if let lib = libraryPath {
            let unixDir = "\(lib)/wine/x86_64-unix"
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(lib):\(unixDir)"
        }

        if let wineExe = wineExecutableURL {
            env["WINELOADER"] = wineExe.path(percentEncoded: false)
        }
        if let wineServer = wineserverExecutableURL {
            env["WINESERVER"] = wineServer.path(percentEncoded: false)
        }

        // D3D11 → DXMT (builtin wiremetal.so, no overrides needed).
        // D3D12 → VKD3D-proton (native DLLs in lib/vkd3d-proton/, loaded via WINEDLLPATH).
        let vkd3dDir = Self.engineDir.appending(path: "wine/lib/vkd3d-proton/x86_64-windows").path(percentEncoded: false)
        if FileManager.default.fileExists(atPath: vkd3dDir) {
            env["WINEDLLPATH"] = vkd3dDir
            env["WINEDLLOVERRIDES"] = "d3d12,d3d12core=n"
            log.debug("[env] VKD3D-proton D3D12 enabled: \(vkd3dDir)")
        }

        log.debug("[env] full environment: \(env.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " | "))")

        return env
    }

    /// Runs a Wine command and waits for it to finish. Captures stdout+stderr.
    ///
    /// Uses `terminationHandler` + `CheckedContinuation` so the main thread is
    /// never blocked. The previous implementation used `process.waitUntilExit()`
    /// which is a synchronous blocking call — on `@MainActor` this freezes the
    /// entire app (spinning beach ball) if the Wine process takes more than a
    /// fraction of a second (e.g. `wineboot --update` showing a GUI dialog).
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

        var env = steamCMDEnvironment(for: prefix)
        env.merge(extraEnv) { _, new in new }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let cmdString = "\(wineExe.lastPathComponent) \(args.joined(separator: " "))"
        log.info("[run] \(cmdString)")
        log.debug("[run] WINEPREFIX=\(prefix.path.path(percentEncoded: false))")

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        // Process has exited. Read buffered pipe output with O_NONBLOCK so we don't
        // block waiting for wine child processes (wineserver, winedevice.exe) that
        // inherited the pipe write-ends and stay alive indefinitely.
        // availableData calls read() which blocks when the write end is still open
        // and no data has been written — exactly the case here after wine64 exits.
        let stdout = String(data: readNonBlocking(stdoutPipe), encoding: .utf8) ?? ""
        let stderr = String(data: readNonBlocking(stderrPipe), encoding: .utf8) ?? ""
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

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

// MARK: - String helpers

private extension String {
    /// Returns `self` if non-empty, otherwise `nil`.
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Non-blocking pipe read

/// Reads whatever bytes are currently buffered in a Pipe without blocking.
///
/// availableData calls read() which blocks when the write end of the pipe
/// is still held open by another process (e.g. wineserver inheriting Wine's
/// pipe fds). Setting O_NONBLOCK makes read() return EAGAIN immediately
/// instead of blocking, so we get buffered data without waiting for EOF.
private func readNonBlocking(_ pipe: Pipe) -> Data {
    let fh = pipe.fileHandleForReading
    let fd = fh.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return Data() }
    fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    let data = fh.availableData
    fcntl(fd, F_SETFL, flags)
    return data
}
