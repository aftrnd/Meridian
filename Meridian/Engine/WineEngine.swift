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
/// `__wine_unix_call` in ntdll.dll (PE export table) — GPTK's d3d12.dll and dxgi.dll
/// both import this function. With CX Wine (current engine): gptkPath is set, full
/// GPTK environment is injected for game launches. D3D12 → D3DMetal → Metal works
/// automatically.
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

    /// Path to the bundled DepotDownloader fork — a native macOS (arm64) binary
    /// that installs owned games headlessly via Meridian's OAuth `refresh_token`,
    /// without `steam.exe`. Staged into the engine tarball at
    /// `engine/tools/depotdownloader/DepotDownloader` by `release-engine.sh`
    /// (built by `Scripts/build-depotdownloader.sh`). Returns `nil` when the
    /// binary is absent or not executable — callers surface a "re-download the
    /// engine" error rather than crashing.
    var depotDownloaderURL: URL? {
        let url = Self.engineDir.appending(path: "tools/depotdownloader/DepotDownloader")
        return FileManager.default.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    // MARK: - Steamworks API emulator (gbe_fork) — DRM games without steam.exe

    /// Directory holding the bundled open-source Steamworks API emulator
    /// (gbe_fork). Staged by `Scripts/build-steamemu.sh` /
    /// `release-engine.sh` at `engine/tools/steamemu/`.
    ///
    /// DRM games (those shipping `steam_api64.dll`) have their Valve
    /// `steam_api(64).dll` replaced with these so `SteamAPI_Init()` succeeds
    /// locally — no `steam.exe`, no auth, no "Who's playing" window. See
    /// `WinePrefix.installSteamEmulator`.
    ///
    /// `nonisolated` because these are pure static-path + FileManager checks
    /// (no actor state) — `WinePrefix.installSteamEmulator` runs off the main
    /// actor (it does multi-MB file copies) and reads them directly.
    nonisolated var steamEmuDir: URL { Self.engineDir.appending(path: "tools/steamemu") }

    /// The emulator's 64-bit `steam_api64.dll`, or nil if not staged.
    nonisolated var steamApi64EmuURL: URL? { Self.existingFile(steamEmuDir.appending(path: "steam_api64.dll")) }

    /// The emulator's 32-bit `steam_api.dll`, or nil if not staged.
    nonisolated var steamApi32EmuURL: URL? { Self.existingFile(steamEmuDir.appending(path: "steam_api.dll")) }

    /// gbe_fork's `generate_interfaces_x64.exe` — run under Wine against the
    /// ORIGINAL Valve dll to produce `steam_interfaces.txt`. Staged for manual
    /// / future use; the emulator falls back to built-in interface defaults
    /// (sufficient for modern games), so the launch path does not invoke it.
    nonisolated var generateInterfacesX64URL: URL? { Self.existingFile(steamEmuDir.appending(path: "generate_interfaces_x64.exe")) }

    nonisolated private static func existingFile(_ url: URL) -> URL? {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    // MARK: - Settings

    private let settings = AppSettings.shared

    // MARK: - Known Paths

    nonisolated static let engineDir: URL = {
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

        // Seed the wine-accessory dylib into the engine + re-sign wine64
        // ad-hoc with the `allow-dyld-environment-variables` entitlement.
        // This is the one-time-per-engine setup that makes
        // `DYLD_INSERT_LIBRARIES` work under hardened runtime. Idempotent —
        // on second launch it fast-paths out when the entitlement is
        // already present. See `Scripts/wine-accessory/` for the dylib
        // rationale and `WineEngine.ensureDyldInjection` for the re-sign
        // mechanics.
        Self.ensureDyldInjection()
    }

    /// Reads the engine release tag from the version file written by `release-engine.sh`.
    private func readEngineVersion() -> String? {
        Self.installedEngineTagOnDisk()
    }

    /// Reads the installed engine tag (e.g. `v3.0.6-engine`) directly from disk
    /// without needing a `WineEngine` instance. Used by `EngineDownloader` to
    /// short-circuit no-op downloads before extraction wipes the engine
    /// directory and races with any in-flight Wine process.
    static func installedEngineTagOnDisk() -> String? {
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

    /// Builds the minimal environment for Steam administrative Wine calls
    /// (bootstrap, persistent steam.exe, IPC forwarders, registry writes).
    /// No Metal HUD, no D3D overrides, no Rosetta game tweaks — those
    /// belong to `environment(for:)` which is game-launch-only.
    ///
    /// Includes `DYLD_INSERT_LIBRARIES` pointing at Meridian's
    /// `meridian-wine-accessory.dylib` when it's on disk. The dylib's
    /// constructor calls `[NSApp setActivationPolicy:.accessory]` inside
    /// every Wine subprocess, killing its Dock tile and preventing
    /// self-activation for notification toasts. See
    /// `Scripts/wine-accessory/meridian_wine_accessory.m` for the full
    /// rationale.
    ///
    /// Only injected for Steam — NOT game launches — because a real game
    /// window SHOULD appear in the Dock + menu bar.
    func steamCMDEnvironment(for prefix: WinePrefix) -> [String: String] {
        guard let lib = libraryPath else { return [:] }
        let wine64  = Self.engineDir.appending(path: "wine/bin/wine64").path(percentEncoded: false)
        let server  = Self.engineDir.appending(path: "wine/bin/wineserver").path(percentEncoded: false)
        var dyld = "\(lib):\(lib)/wine/x86_64-unix"
        if let l64 = lib64Path { dyld += ":\(l64)" }
        var env: [String: String] = [
            "WINEPREFIX":                prefix.path.path(percentEncoded: false),
            "WINESERVER":                server,
            "WINELOADER":                wine64,
            "WINEDLLPATH":               "\(lib)/wine",
            "DYLD_FALLBACK_LIBRARY_PATH": dyld,
            "WINE_LARGE_ADDRESS_AWARE":  "1",
            // Disable the Windows audio API for all non-game Wine processes
            // (steam.exe, wineboot, reg, etc.) so Steam sounds never leak
            // through. Games use environment(for:) which does not set this.
            "WINEDLLOVERRIDES":          "mmdevapi=d",
        ]
        if let accessoryPath = Self.accessoryDylibPath() {
            env["DYLD_INSERT_LIBRARIES"] = accessoryPath
        }
        return env
    }

    /// Path to `meridian-wine-accessory.dylib` on disk, or `nil` if it's
    /// missing both from the engine and the app bundle. Prefers the
    /// engine-internal copy (so versioned engines ship their own), falls
    /// back to the app bundle (so a bundled-only install works), and
    /// returns `nil` as a last resort (callers degrade to the previous
    /// Dock-visible behavior, not a crash).
    static func accessoryDylibPath() -> String? {
        let fm = FileManager.default
        let engineCopy = Self.engineDir
            .appending(path: "wine/share/meridian/meridian-wine-accessory.dylib")
        if fm.fileExists(atPath: engineCopy.path(percentEncoded: false)) {
            return engineCopy.path(percentEncoded: false)
        }
        if let bundled = Bundle.main.url(forResource: "meridian-wine-accessory", withExtension: "dylib"),
           fm.fileExists(atPath: bundled.path(percentEncoded: false)) {
            return bundled.path(percentEncoded: false)
        }
        return nil
    }

    /// Ensures `wine64` is signed with the
    /// `com.apple.security.cs.allow-dyld-environment-variables` entitlement,
    /// required for `DYLD_INSERT_LIBRARIES` to take effect under hardened
    /// runtime. CrossOver's stock wine64 doesn't include it; this method
    /// re-signs ad-hoc with the full entitlement set (preserving CX's
    /// existing entitlements + adding the dyld-env permission).
    ///
    /// Idempotent — checks current entitlements first and returns early if
    /// already present. Safe to call on every app launch.
    ///
    /// Note on ad-hoc signing: we lose CrossOver's Developer ID signature,
    /// but `wine64` is launched as a subprocess of the Developer-ID-signed
    /// Meridian app, not directly by the user, so Gatekeeper is not
    /// consulted. The re-sign preserves all functionality. Meridian owns
    /// the engine; CX's signature was never a trust anchor in our flow.
    ///
    /// Also seeds `meridian-wine-accessory.dylib` into the engine if the
    /// engine tarball didn't ship one (same pattern as `meridian-dpapi.exe`).
    static func ensureDyldInjection() {
        let fm = FileManager.default
        let wine64 = Self.engineDir.appending(path: "wine/bin/wine64")
        let wine64Path = wine64.path(percentEncoded: false)
        guard fm.isExecutableFile(atPath: wine64Path) else {
            log.debug("[ensureDyld] wine64 missing — engine not ready yet")
            return
        }

        // Sync dylib from bundle → engine when bundle is newer (or engine
        // copy is missing). Without the mtime check the engine copy would
        // never refresh from a Meridian app update — diagnostic logging,
        // bug fixes, and policy tweaks in the dylib would be silently
        // ignored. Same self-heal pattern as `installDpapiHelperFromBundle`.
        let dylibDest = Self.engineDir.appending(path: "wine/share/meridian/meridian-wine-accessory.dylib")
        if let bundled = Bundle.main.url(forResource: "meridian-wine-accessory", withExtension: "dylib") {
            let needsCopy: Bool
            if !fm.fileExists(atPath: dylibDest.path(percentEncoded: false)) {
                needsCopy = true
            } else {
                let bundledMtime = (try? bundled.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                let engineMtime  = (try? dylibDest.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                needsCopy = (bundledMtime ?? .distantPast) > (engineMtime ?? .distantPast)
            }
            if needsCopy {
                do {
                    try fm.createDirectory(at: dylibDest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dylibDest.path(percentEncoded: false)) {
                        try fm.removeItem(at: dylibDest)
                    }
                    try fm.copyItem(at: bundled, to: dylibDest)
                    log.info("[ensureDyld] synced meridian-wine-accessory.dylib bundle → engine")
                } catch {
                    log.warning("[ensureDyld] could not copy accessory dylib: \(error.localizedDescription)")
                }
            }
        }

        // Fast path: entitlement already present → no re-sign needed.
        if currentEntitlements(for: wine64Path).contains("com.apple.security.cs.allow-dyld-environment-variables") {
            log.debug("[ensureDyld] wine64 already has allow-dyld-environment-variables ✓")
            return
        }

        log.info("[ensureDyld] wine64 missing allow-dyld-environment-variables — re-signing ad-hoc with augmented entitlements")

        // Write the combined entitlements plist. Keys match what CrossOver's
        // wine64 ships with, plus our dyld-env addition. Keeping CX's set
        // verbatim is important — stripping any of them (e.g. disable-
        // library-validation) would break legitimate Wine functionality.
        let entitlements = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
            <true/>
            <key>com.apple.security.cs.disable-executable-page-protection</key>
            <true/>
            <key>com.apple.security.cs.disable-library-validation</key>
            <true/>
            <key>com.apple.security.cs.allow-dyld-environment-variables</key>
            <true/>
            <key>com.apple.security.device.audio-input</key>
            <true/>
            <key>com.apple.security.device.camera</key>
            <true/>
        </dict>
        </plist>
        """
        let plistURL = URL.temporaryDirectory
            .appending(path: "meridian-wine64-ents-\(UUID().uuidString.prefix(8)).plist")
        do {
            try entitlements.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("[ensureDyld] could not write entitlements plist: \(error.localizedDescription)")
            return
        }
        defer { try? fm.removeItem(at: plistURL) }

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        // CRITICAL: do NOT preserve `team-identifier` from CrossOver's original
        // signature. Ad-hoc signing (`--sign -`) produces a signature with no
        // team identifier by design; keeping CW's "9C6B7X7Z8E" leaves the
        // binary with a contradictory `Signature=adhoc` + `TeamIdentifier=…`
        // state. The kernel SIGKILLs such binaries at exec time with
        // exit 137 (= 128 + 9). CLI-verified April 23 2026.
        //
        // `flags` must be preserved so the hardened-runtime flag survives
        // the re-sign (without it, our dyld-env entitlement would be
        // applied to a non-hardened-runtime binary, which macOS accepts
        // but means `DYLD_INSERT_LIBRARIES` would work even without the
        // entitlement — harmless, just wastes the re-sign work).
        codesign.arguments = [
            "--force",
            "--sign", "-",
            "--entitlements", plistURL.path(percentEncoded: false),
            "--preserve-metadata=flags,runtime",
            wine64Path,
        ]
        let stderrPipe = Pipe()
        codesign.standardError = stderrPipe
        codesign.standardOutput = FileHandle.nullDevice
        do {
            try codesign.run()
            codesign.waitUntilExit()
            if codesign.terminationStatus != 0 {
                let err = (try? stderrPipe.fileHandleForReading.readToEnd())
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                log.error("[ensureDyld] codesign exit=\(codesign.terminationStatus) stderr=\(err.prefix(500))")
            } else {
                log.info("[ensureDyld] wine64 re-signed ad-hoc with allow-dyld entitlement ✓")
            }
        } catch {
            log.error("[ensureDyld] codesign failed to launch: \(error.localizedDescription)")
        }
    }

    /// Returns the current codesign entitlements for a path as a single string
    /// (used for substring-based feature-detection — "does the binary have
    /// entitlement X?"). Returns empty on error.
    private static func currentEntitlements(for path: String) -> String {
        let cs = Process()
        cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        cs.arguments = ["-d", "--entitlements", ":-", path]
        let outPipe = Pipe()
        cs.standardOutput = outPipe
        cs.standardError = FileHandle.nullDevice
        guard (try? cs.run()) != nil else { return "" }
        cs.waitUntilExit()
        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
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
                // SteamSession.gameEnvironment(for:engine:) based on
                // profile.graphicsAPI == .dx12.
                let dxmtLibDir = "\(lib)/dxmt"
                env["WINEDLLPATH"] = "\(dxmtLibDir):\(lib)/wine"

                // Force Wine to load native PE versions of d3d11/dxgi/d3d10core
                // BEFORE its own builtin wined3d implementations.
                //
                // CRITICAL — without this override, Wine prefers the much
                // smaller wined3d-based `lib/wine/x86_64-windows/d3d11.dll`
                // (426 KB) over the full DXMT `lib/dxmt/x86_64-windows/d3d11.dll`
                // (4.8 MB). The wined3d path then translates D3D11 → Vulkan →
                // MoltenVK → Metal which has many partial-stub format/feature
                // gaps (CLI-verified May 20 2026 game log: a Bogos Binted
                // launch produced 30+ lines of
                // `err:winediag:wined3d_adapter_create Using the Vulkan
                //  renderer for d3d10/11 applications` and
                // `fixme:d3d11:d3d11_device_CheckFormatSupport ... partial-stub!`
                // before silently failing to render).
                //
                // `n,b` order means "try native (PE) first, fall back to
                // builtin if not found." Wine searches WINEDLLPATH for the
                // native version; since `lib/dxmt` is first, it finds DXMT's
                // PE there. Builtin path is preserved as a safety net for
                // environments where DXMT isn't present.
                env["WINEDLLOVERRIDES"] = "d3d11=n,b;dxgi=n,b;d3d10core=n,b"

                env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = "\(gptk)/external/libd3dshared.dylib"
            } else {
                env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(lib):\(unixDir)\(l64Suffix)"
            }
        }

        // GStreamer plugin discovery for winegstreamer (Unity VideoPlayer / any
        // Media Foundation video playback). The bundled GStreamer plugins live in
        // lib64/gstreamer-1.0, but GStreamer's compiled-in default scan path points
        // at CrossOver's build location, which doesn't exist on the user's machine.
        // Without GST_PLUGIN_SYSTEM_PATH_1_0 the MF video pipeline finds ZERO
        // decoders, so intro/cutscene videos render black while the dialogue text
        // still draws over them. CLI-diagnosed June 2026 from
        // logs/games/3180070.log (No I'm not a Human): the video path reached
        // winegstreamer but failed caps negotiation ("gst_video_info_from_caps:
        // caps not fixed") because no decoder plugin was discovered. CrossOver
        // ships the identical plugin set (applemedia/VideoToolbox is the H.264
        // decoder) — the only missing piece was telling GStreamer where to look.
        if let l64 = lib64Path {
            let pluginDir = "\(l64)/gstreamer-1.0"
            env["GST_PLUGIN_SYSTEM_PATH_1_0"] = pluginDir
            env["GST_PLUGIN_PATH_1_0"]        = pluginDir
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
    // fcntl return value is discarded — we only care that O_NONBLOCK was set/restored
    // (errors here would surface as unexpected blocking behaviour in the read loop
    // below, which we'd see immediately during development).
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    defer { _ = fcntl(fd, F_SETFL, flags) }

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
