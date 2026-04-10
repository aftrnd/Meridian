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
/// All runtime components are legally redistributable:
///   - CX Wine LGPL, DXMT MIT, DXVK zlib, Apple GPTK Apple-distributed,
///     MoltenVK Apache 2.0
///
/// ## D3D12 Support
///
/// GPTK (D3D12 → D3DMetal → Metal) requires CX Wine ABI. Detection checks for
/// `__wine_unix_call` in ntdll.so — GPTK's d3d12.dll and dxgi.dll both import this
/// function. With CX Wine (current engine): gptkPath is set, full GPTK environment
/// is injected for game launches. D3D12 → D3DMetal → Metal works automatically.
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

    /// Path to the D3D12 implementation directory (VKD3D-proton, not used on macOS).
    private(set) var d3d12Path: String?

    /// Path to the GPTK directory (D3D12 → D3DMetal → Metal).
    /// Set when `wine/lib/gptk/external/D3DMetal.framework/D3DMetal` exists.
    private(set) var gptkPath: String?

    /// Path to lib64/ (MoltenVK, GnuTLS, GStreamer, libgmp).
    /// Required on DYLD_FALLBACK_LIBRARY_PATH so secur32.so can dlopen libgnutls
    /// for Wine's TLS stack. Without this, all Wine HTTPS operations fail.
    private(set) var lib64Path: String?

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
            lib64Path = nil
            dxmtPath = nil
            dxvkPath = nil
            d3d12Path = nil
            gptkPath = nil
            return
        }

        wineExecutableURL       = URL(filePath: bundledWine)
        wineserverExecutableURL = URL(filePath: bundledServer)
        libraryPath             = Self.engineDir.appending(path: "wine/lib").path(percentEncoded: false)

        let l64 = Self.engineDir.appending(path: "wine/lib64").path(percentEncoded: false)
        lib64Path = fm.fileExists(atPath: l64) ? l64 : nil

        // DXMT is in lib/dxmt/ (separate directory, matches CX Preview layout).
        // Wine's original dxgi.dll (214KB) and d3d11.dll (416KB) remain untouched
        // in lib/wine/. This allows GPTK to load its own dxgi for D3D12 games:
        //   DX11: WINEDLLPATH = lib/dxmt:lib/wine → DXMT dxgi/d3d11 loaded first
        //   D3D12: WINEDLLPATH = gptk/wine:lib/wine → GPTK dxgi/d3d12 loaded first
        // If DXMT were in lib/wine/ (old layout), any =b override would still find
        // DXMT's dxgi before GPTK's, causing IDXGIAdapter4 NULL deref crashes.
        let dxmtUnixSo = Self.engineDir.appending(path: "wine/lib/dxmt/x86_64-unix/winemetal.so").path(percentEncoded: false)
        let dxmtWinDll = Self.engineDir.appending(path: "wine/lib/dxmt/x86_64-windows/d3d11.dll").path(percentEncoded: false)
        if fm.fileExists(atPath: dxmtUnixSo) && fm.fileExists(atPath: dxmtWinDll) {
            dxmtPath = Self.engineDir.appending(path: "wine/lib/dxmt").path(percentEncoded: false)
        }

        let bundledDxvk = Self.engineDir.appending(path: "wine/lib/dxvk").path(percentEncoded: false)
        if fm.fileExists(atPath: bundledDxvk) { dxvkPath = bundledDxvk }

        // D3D12: detect VKD3D-proton (present but NOT used on macOS — lacks VK_EXT_transform_feedback)
        let vkd3dProton = Self.engineDir.appending(path: "wine/lib/vkd3d-proton/x86_64-windows/d3d12.dll").path(percentEncoded: false)
        d3d12Path = fm.fileExists(atPath: vkd3dProton)
            ? Self.engineDir.appending(path: "wine/lib/vkd3d-proton").path(percentEncoded: false)
            : nil

        // GPTK: D3D12 → D3DMetal.framework → Metal
        // REQUIRES CX Wine ABI: ntdll.__wine_unix_call must be present as a PE export.
        // GPTK's d3d12.dll AND dxgi.dll both import ntdll.__wine_unix_call.
        // Loading them on Gcenx Wine (which lacks this export) causes:
        //   "wine: Call from ... to unimplemented function ntdll.dll.__wine_unix_call, aborting"
        // With CX Wine (current engine base): __wine_unix_call IS exported → gptkPath is set
        // and GPTK env vars are injected for game launches → D3D12 → D3DMetal → Metal works.
        // CLI-verified April 2026: CX Wine steam.exe bootstrap downloads successfully
        // (confirmed 130 MB/s download). Gcenx Wine 11.6 fails with HTTP error 0 on macOS 26.
        //
        // DETECTION: Search the Windows PE ntdll.dll (not ntdll.so) for the null-terminated
        // string "__wine_unix_call\0". The PE export table embeds the export name as a C string.
        // CLI-verified April 2026: ntdll.dll contains "__wine_unix_call\0" at byte offset 673776.
        // ntdll.so does NOT contain this string — the .so has only __wine_unix_call_dispatcher
        // and __wine_unix_call_funcs. Searching ntdll.so was the original bug causing cxABI=false.
        let ntdllDll = Self.engineDir.appending(path: "wine/lib/wine/x86_64-windows/ntdll.dll")
        let hasCXWineABI: Bool = {
            guard let data = try? Data(contentsOf: ntdllDll, options: .mappedIfSafe),
                  let base = "__wine_unix_call".data(using: .utf8) else { return false }
            // Append null byte to match the exact export name, not __wine_unix_call_dispatcher
            var marker = base
            marker.append(0)
            return data.range(of: marker) != nil
        }()
        let gptkD3DMetal = Self.engineDir.appending(path: "wine/lib/gptk/external/D3DMetal.framework/D3DMetal").path(percentEncoded: false)
        gptkPath = (hasCXWineABI && fm.fileExists(atPath: gptkD3DMetal))
            ? Self.engineDir.appending(path: "wine/lib/gptk").path(percentEncoded: false)
            : nil

        backendName   = "Meridian"
        engineVersion = readEngineVersion()
        state         = .ready

        let dxmtMode: String = {
            guard let p = self.dxmtPath else { return "none" }
            return p.hasSuffix("dxmt") ? "\(p) (separate dir)" : "\(p)"
        }()
        log.info("[detect] Engine found at \(engineBase)")
        log.info("[detect]   wine64=\(wineExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   wineserver=\(wineserverExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   lib=\(self.libraryPath ?? "none")")
        log.info("[detect]   dxmt=\(dxmtMode)")
        log.info("[detect]   dxvk=\(self.dxvkPath ?? "none")")
        log.info("[detect]   d3d12=\(self.d3d12Path ?? "none")")
        log.info("[detect]   gptk=\(self.gptkPath ?? "none") cxABI=\(hasCXWineABI)")
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
        lib64Path               = nil
        dxmtPath                = nil
        dxvkPath                = nil
        d3d12Path               = nil
        gptkPath                = nil
    }

    // MARK: - Environment

    /// Builds the minimal environment for SteamCMD (no Metal HUD, no Rosetta flags).
    /// SteamCMD is a console tool; it does not use DirectX or Metal.
    func steamCMDEnvironment(for prefix: WinePrefix) -> [String: String] {
        guard let lib = libraryPath else { return [:] }
        let wine64  = Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let server  = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)
        var dyld = "\(lib):\(lib)/wine/x86_64-unix"
        if let l64 = lib64Path { dyld += ":\(l64)" }
        return [
            "WINEPREFIX":                prefix.path.path(percentEncoded: false),
            "WINESERVER":                server,
            "WINELOADER":                wine64,
            "WINEDLLPATH":               "\(lib)/wine",
            "DYLD_FALLBACK_LIBRARY_PATH": dyld,
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

        if let wineExe = wineExecutableURL {
            env["WINELOADER"] = wineExe.path(percentEncoded: false)
        }
        if let wineServer = wineserverExecutableURL {
            env["WINESERVER"] = wineServer.path(percentEncoded: false)
        }

        if let lib = libraryPath {
            let unixDir = "\(lib)/wine/x86_64-unix"

            let l64Suffix = lib64Path.map { ":\($0)" } ?? ""

            if let gptk = gptkPath {
                // GPTK present (CX Wine ABI confirmed): D3D12 → D3DMetal → Metal
                //
                // DYLD includes gptk paths so libd3dshared.dylib/D3DMetal load when a
                // D3D12 game's WINEDLLPATH routes through gptk/wine. Also includes
                // lib/dxmt/x86_64-unix for winemetal.so (DXMT's Metal bridge).
                let dxmtUnixDir = "\(lib)/dxmt/x86_64-unix"
                env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(gptk)/external:\(gptk)/wine/x86_64-unix:\(lib):\(dxmtUnixDir):\(unixDir)\(l64Suffix)"
                env["DYLD_FALLBACK_FRAMEWORK_PATH"] = "\(gptk)/external"

                // DX11 default: DXMT first in WINEDLLPATH, Wine builtins as fallback.
                // D3D12 games override both WINEDLLPATH and WINEDLLOVERRIDES in
                // WineSteamManager.launchGameDirectly() based on profile.graphicsAPI == .dx12.
                let dxmtLibDir = "\(lib)/dxmt"
                env["WINEDLLPATH"] = "\(dxmtLibDir):\(lib)/wine"

                // No global WINEDLLOVERRIDES — Wine's default builtin,native load order
                // correctly picks DXMT from lib/dxmt for DX11 games. D3D12 games set
                // d3d12=b;dxgi=b in launchGameDirectly to bypass lib/dxmt entirely.

                env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = "\(gptk)/external/libd3dshared.dylib"
            } else {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(lib):\(unixDir)\(l64Suffix)"
            }
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
/// Uses raw Darwin.read() with O_NONBLOCK rather than availableData.
/// NSConcreteFileHandle.availableData throws NSFileHandleOperationException
/// when read() returns EAGAIN (errno 35) — it does not return empty Data.
/// Darwin.read() returns -1 on EAGAIN which we handle by breaking the loop.
private func readNonBlocking(_ pipe: Pipe) -> Data {
    let fh = pipe.fileHandleForReading
    let fd = fh.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0 else { return Data() }
    fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    defer { fcntl(fd, F_SETFL, flags) }

    var result = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n > 0 {
            result.append(contentsOf: buf[..<n])
        } else {
            // n == 0: EOF  |  n == -1: EAGAIN or other error — stop reading
            break
        }
    }
    return result
}
