import Foundation
import Observation
import os.log

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

    /// The Meridian engine release tag bundled with the installed engine, e.g. `v1.2.0-engine`.
    /// Read from `wine/meridian-engine-version.txt` written by `release-engine.sh`.
    /// Nil when the engine was installed without a version file (older releases or CrossOver).
    private(set) var engineVersion: String?

    // MARK: - Detected Paths

    /// Path to the Wine executable (wineloader or wine64).
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

    /// When CrossOver Preview is installed, its lib/wine path.
    /// Used as the primary DLL source (better stubs) while Gcenx provides DXMT.
    /// Personal-use only — not redistributable.
    private(set) var cxPreviewLibPath: String?

    /// The Gcenx wine64 binary — always available regardless of CX engine.
    /// Used for SteamCMD and other tools that don't need CX's improved stubs.
    /// CLI-verified: SteamCMD works perfectly with Gcenx wine64.
    private(set) var gcenxWine64URL: URL?

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
    /// Meridian is fully standalone — CrossOver.app is not a supported runtime.
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
            state = .notInstalled
            backendName = "None"
            engineVersion = nil
            wineExecutableURL = nil
            wineserverExecutableURL = nil
            libraryPath = nil
            dxmtPath = nil
            dxvkPath = nil
            cxPreviewLibPath = nil
            gcenxWine64URL = nil
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
            cxPreviewLibPath = nil
            gcenxWine64URL = nil
            return
        }

        // Detect CrossOver Preview for personal-use engine augmentation.
        // When CX Preview is installed, use its wineloader/wineserver and DLL set
        // (which fixes 1,131 abort stubs vs our Gcenx Wine 8.0.1). The Gcenx engine
        // still provides DXMT (Metal renderer) which CX Preview does not include.
        //
        // PERSONAL USE ONLY — CX Preview binaries are not redistributable.
        // For distributable builds: use the Gcenx engine path only.
        // Always store the Gcenx wine64 path — SteamCMD uses this exclusively.
        gcenxWine64URL = URL(filePath: bundledWine)

        cxPreviewLibPath = nil
        let cxPaths = [
            "/Applications/CrossOver Preview.app/Contents/SharedSupport/CrossOver",
            "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver",
        ]
        for cxRoot in cxPaths {
            let cxLoader = "\(cxRoot)/bin/wineloader"
            let cxServer = "\(cxRoot)/bin/wineserver"
            let cxLib    = "\(cxRoot)/lib/wine"
            let cxNtdll  = "\(cxRoot)/lib/wine/x86_64-unix/ntdll.so"
            if fm.isExecutableFile(atPath: cxLoader),
               fm.isExecutableFile(atPath: cxServer),
               fm.fileExists(atPath: cxNtdll) {
                // Use CX wineloader and wineserver (better stub coverage)
                wineExecutableURL    = URL(filePath: cxLoader)
                wineserverExecutableURL = URL(filePath: cxServer)
                cxPreviewLibPath = cxLib
                log.info("[detect] CrossOver engine detected at \(cxRoot) — using for improved stub coverage")
                break
            }
        }

        // Fall back to bundled Gcenx engine binaries if CX not found
        if wineExecutableURL == nil {
            wineExecutableURL    = URL(filePath: bundledWine)
            wineserverExecutableURL = URL(filePath: bundledServer)
        }

        libraryPath = Self.engineDir.appending(path: "wine/lib").path(percentEncoded: false)

        // DXMT builtin layout: DLLs live in lib/wine/x86_64-windows/ alongside Wine's own DLLs.
        // Detect presence by checking for the winemetal.so companion (unix-side library).
        let dxmtUnixSo = Self.engineDir.appending(path: "wine/lib/wine/x86_64-unix/winemetal.so").path(percentEncoded: false)
        let dxmtWinDll = Self.engineDir.appending(path: "wine/lib/wine/x86_64-windows/d3d11.dll").path(percentEncoded: false)
        if fm.fileExists(atPath: dxmtUnixSo) && fm.fileExists(atPath: dxmtWinDll) {
            // Store the wine DLL directory as the dxmt path for display in Settings
            dxmtPath = Self.engineDir.appending(path: "wine/lib/wine/x86_64-windows").path(percentEncoded: false)
        } else {
            // Legacy layout: separate lib/dxmt/ directory (v1.0.2 and older)
            let legacyDxmt = Self.engineDir.appending(path: "wine/lib/dxmt").path(percentEncoded: false)
            if fm.fileExists(atPath: legacyDxmt) { dxmtPath = legacyDxmt }
        }

        let bundledDxvk = Self.engineDir.appending(path: "wine/lib/dxvk").path(percentEncoded: false)
        if fm.fileExists(atPath: bundledDxvk) { dxvkPath = bundledDxvk }

        backendName   = cxPreviewLibPath != nil ? "CrossOver Preview + Meridian DXMT" : "Meridian"
        engineVersion = readEngineVersion()
        state         = .ready

        let dxmtMode: String = {
            guard let p = self.dxmtPath else { return "none" }
            return p.hasSuffix("dxmt") ? "\(p) (legacy override)" : "\(p) (builtin)"
        }()
        log.info("[detect] Bundled engine found at \(engineBase)")
        log.info("[detect]   wine64=\(wineExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   wineserver=\(wineserverExecutableURL?.path(percentEncoded: false) ?? "none")")
        log.info("[detect]   lib=\(self.libraryPath ?? "none")")
        log.info("[detect]   dxmt=\(dxmtMode)")
        log.info("[detect]   dxvk=\(self.dxvkPath ?? "none")")
        log.info("[detect]   engineVersion=\(self.engineVersion ?? "unknown")")
        if let cx = cxPreviewLibPath {
            log.info("[detect]   cxPreviewLib=\(cx)")
        }
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

        state         = .notInstalled
        backendName   = "None"
        engineVersion = nil
        wineExecutableURL       = nil
        wineserverExecutableURL = nil
        libraryPath  = nil
        dxmtPath     = nil
        dxvkPath     = nil
        cxPreviewLibPath = nil
        gcenxWine64URL = nil
    }

    // MARK: - Environment

    /// Builds the Gcenx-only environment for SteamCMD.
    /// SteamCMD must use the Gcenx wine64 binary — CLI-verified working.
    /// CX wineloader causes version mismatches with SteamCMD.
    func gcenxEnvironment(for prefix: WinePrefix) -> [String: String] {
        guard let lib = libraryPath else { return [:] }
        let gcenxWine = gcenxWine64URL?.path(percentEncoded: false)
            ?? Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let gcenxServer = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)
        return [
            "WINEPREFIX": prefix.path.path(percentEncoded: false),
            "WINESERVER": gcenxServer,
            "WINELOADER": gcenxWine,
            "WINEDLLPATH": "\(lib)/wine",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(lib):\(lib)/wine/x86_64-unix",
            "WINE_LARGE_ADDRESS_AWARE": "1",
        ]
    }

    /// Builds the environment dictionary for launching a Wine process.
    func environment(for prefix: WinePrefix) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": prefix.path.path(percentEncoded: false),
            "WINE_LARGE_ADDRESS_AWARE": "1",
            "MTL_HUD_ENABLED": settings.metalHUD ? "1" : "0",
            "ROSETTA_ADVERTISE_AVX": "1",
            "DOTNET_EnableWriteXorExecute": "0",
        ]

        // When CrossOver Preview is available, its libs take priority for DLL loading.
        // This eliminates 1,131 abort stubs vs Wine 8.0.1. The Gcenx engine still
        // provides DXMT (Metal renderer) which CX Preview does not include.
        // CX libs are prepended; Gcenx libs follow as fallback for DXMT/NLS/etc.
        let gcenxLib = libraryPath  // Gcenx engine lib path

        if let cxLib = cxPreviewLibPath, let gcenxLib {
            // CX root is two levels up from cxPreviewLibPath ($CX_ROOT/lib/wine → $CX_ROOT)
            let cxRoot = URL(filePath: cxLib).deletingLastPathComponent().deletingLastPathComponent().path(percentEncoded: false)

            // Apple GPTK D3DMetal paths (D3D12 → Metal 3 via libd3dshared / D3DMetal.framework)
            // CLI-verified: GPTK d3d12.dll fixes blue-flashing-screen on D3D12 games (Animal Well).
            let gptkWinDlls  = "\(cxRoot)/lib64/apple_gptk/wine/x86_64-windows"
            let gptkUnixDlls = "\(cxRoot)/lib64/apple_gptk/wine/x86_64-unix"
            let gptkExternal = "\(cxRoot)/lib64/apple_gptk/external"
            let cxLib64      = "\(cxRoot)/lib64"
            let libd3dshared = "\(gptkExternal)/libd3dshared.dylib"

            // CX Preview mode: build DYLD path with GPTK dirs for libd3dshared + D3DMetal resolution
            let cxUnix    = "\(cxLib)/x86_64-unix"
            let gcenxUnix = "\(gcenxLib)/wine/x86_64-unix"
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(cxLib):\(cxUnix):\(gptkUnixDlls):\(gptkExternal):\(cxLib64):\(gcenxUnix):\(gcenxLib)"

            // WINEDLLPATH order:
            //   1. Gcenx x86_64-windows (DXMT d3d11/dxgi — Metal renderer for DX11)
            //   2. GPTK x86_64-windows  (d3d12 via D3DMetal — correct renderer for DX12)
            //   3. CX lib/wine          (CX's modern stubs for everything else)
            //   4. Gcenx lib/wine       (NLS, fallback)
            let gcenxWinDlls = "\(gcenxLib)/wine/x86_64-windows"
            env["WINEDLLPATH"] = "\(gcenxWinDlls):\(gptkWinDlls):\(cxLib):\(gcenxLib)/wine"

            // CX Perl launcher sets this so D3DMetal can find libd3dshared.dylib at runtime
            if FileManager.default.fileExists(atPath: libd3dshared) {
                env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = libd3dshared
            }
        } else if let lib = gcenxLib {
            // Gcenx-only mode (original behavior)
            let unixDir = "\(lib)/wine/x86_64-unix"
            env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(lib):\(unixDir)"
        }

        if let wineExe = wineExecutableURL {
            env["WINELOADER"] = wineExe.path(percentEncoded: false)
        }
        if let wineServer = wineserverExecutableURL {
            env["WINESERVER"] = wineServer.path(percentEncoded: false)
        }

        // DXMT builtin layout (v1.0.3+): DLLs live in lib/wine/x86_64-windows/ alongside
        // Wine's own DLLs. Wine finds and loads them automatically — no WINEDLLPATH or
        // WINEDLLOVERRIDES needed. The DLLs are registered as builtins.
        //
        // Legacy layout (v1.0.2 and older): DXMT DLLs were in a separate lib/dxmt/
        // directory and required WINEDLLOVERRIDES=n,b to force Wine to prefer them.
        //
        // CX Preview mode: DXMT is supplied by Gcenx engine (CX doesn't have winemetal.so).
        // Since CX's DLL path is prepended, we need explicit overrides so DXMT wins over
        // CX's own d3d11/dxgi stubs.
        let fm = FileManager.default
        let isBuiltinDXMT: Bool = {
            guard let lib = gcenxLib else { return false }
            return fm.fileExists(atPath: "\(lib)/wine/x86_64-unix/winemetal.so")
        }()
        let hasLegacyDxmt: Bool = {
            guard let dxmt = dxmtPath else { return false }
            return dxmt.hasSuffix("dxmt") && fm.fileExists(atPath: "\(dxmt)/x86_64-windows")
        }()

        if cxPreviewLibPath != nil && isBuiltinDXMT {
            // CX Preview + builtin DXMT: need explicit override so our DXMT wins over CX's d3d11.
            // "n" = native (from WINEDLLPATH), "b" = builtin fallback. Since we put Gcenx's
            // x86_64-windows dir first in WINEDLLPATH, Wine loads DXMT d3d11 from there.
            env["WINEDLLOVERRIDES"] = "winemetal=b;d3d11,d3d12,dxgi=n,b"
            log.debug("[env] DXMT enabled (CX+builtin): forcing native override for DXMT d3d11/dxgi")
        } else if hasLegacyDxmt, let dxmt = dxmtPath {
            // Legacy: DXMT as native override
            var dllPaths: [String] = ["\(dxmt)/x86_64-windows", "\(dxmt)/i386-windows"]
            if let lib = gcenxLib { dllPaths.append("\(lib)/wine") }
            if cxPreviewLibPath == nil { env["WINEDLLPATH"] = dllPaths.joined(separator: ":") }
            log.debug("[env] DXMT enabled (legacy override): \(dxmt)")
            env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,dxgi=n,b"
        } else if isBuiltinDXMT {
            log.debug("[env] DXMT enabled (builtin): winemetal.so present")
            // Builtin DXMT: no overrides needed — Wine loads them automatically
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: error)
            }
        }

        // Process has exited. Read whatever is buffered in the pipes RIGHT NOW
        // using availableData (non-blocking). Do NOT use readDataToEndOfFile() —
        // Wine child processes (wineserver, services.exe, winedevice.exe) inherit
        // the pipe file descriptors and stay alive indefinitely. readDataToEndOfFile
        // blocks until ALL holders of the write end close it, causing a deadlock
        // that freezes the app forever (e.g. wineboot --update never "returns").
        let stdout = String(data: stdoutPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.availableData, encoding: .utf8) ?? ""
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
