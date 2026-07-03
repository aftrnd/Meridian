import XCTest

/// Unit tests for the headless DepotDownloader install path
/// (`Meridian/Launch/DepotDownloaderInstall.swift` + its wiring in
/// `Launcher.swift`).
///
/// The `Meridian` target is an executableTarget; Swift cannot `@testable import`
/// it, so the pure NDJSON parser is mirrored here (inlined copy). Source-invariant
/// tests read the production files as text and assert the proven invocation
/// contract + wiring decisions hold.
///
/// MIRROR CONTRACT: `Event` + `parse` below mirror
/// `DepotDownloaderInstall.Event` / `DepotDownloaderInstall.parse`. Keep in sync.
final class DepotDownloaderInstallTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Mirror of DepotDownloaderInstall.Event / parse

    struct InstalledDepot: Equatable {
        let depotID: UInt32
        let manifestID: String
        let size: Int64
        let sharedApp: UInt32?
    }

    enum Event: Equatable {
        case phase(phase: String, detail: String)
        case progress(bytesDone: Int64, bytesTotal: Int64, pct: Double)
        case done(bytesDownloaded: Int64, buildID: Int, depots: [InstalledDepot])
        case error(message: String)
    }

    private func parse(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }

        func intValue(_ any: Any?) -> Int64 {
            if let n = any as? Int64 { return n }
            if let n = any as? Int { return Int64(n) }
            if let n = any as? Double { return Int64(n) }
            if let s = any as? String, let n = Int64(s) { return n }
            return 0
        }
        func doubleValue(_ any: Any?) -> Double {
            if let n = any as? Double { return n }
            if let n = any as? Int { return Double(n) }
            if let s = any as? String, let n = Double(s) { return n }
            return 0
        }

        switch type {
        case "phase":
            return .phase(phase: (obj["phase"] as? String) ?? "",
                          detail: (obj["detail"] as? String) ?? "")
        case "progress":
            return .progress(bytesDone: intValue(obj["bytesDone"]),
                             bytesTotal: intValue(obj["bytesTotal"]),
                             pct: doubleValue(obj["pct"]))
        case "done":
            var depots: [InstalledDepot] = []
            if let arr = obj["depots"] as? [[String: Any]] {
                for d in arr {
                    let depotID = UInt32(clamping: intValue(d["depot"]))
                    guard depotID != 0 else { continue }
                    let manifest = (d["manifest"] as? String)
                        ?? (intValue(d["manifest"]) != 0 ? String(intValue(d["manifest"])) : "")
                    guard !manifest.isEmpty else { continue }
                    let shared = intValue(d["sharedApp"])
                    depots.append(InstalledDepot(
                        depotID: depotID,
                        manifestID: manifest,
                        size: intValue(d["size"]),
                        sharedApp: shared != 0 ? UInt32(clamping: shared) : nil
                    ))
                }
            }
            return .done(
                bytesDownloaded: intValue(obj["bytesDownloaded"]),
                buildID: Int(intValue(obj["buildid"])),
                depots: depots
            )
        case "error":
            return .error(message: (obj["message"] as? String) ?? "unknown error")
        default:
            return nil
        }
    }

    // MARK: - NDJSON parsing

    func testParse_phase() {
        XCTAssertEqual(parse(#"{"type":"phase","phase":"connecting","detail":""}"#),
                       .phase(phase: "connecting", detail: ""))
        XCTAssertEqual(parse(#"{"type":"phase","phase":"loggedon","detail":"x"}"#),
                       .phase(phase: "loggedon", detail: "x"))
    }

    func testParse_progress() {
        XCTAssertEqual(parse(#"{"type":"progress","bytesDone":1048576,"bytesTotal":34000000,"pct":3.08}"#),
                       .progress(bytesDone: 1_048_576, bytesTotal: 34_000_000, pct: 3.08))
    }

    func testParse_done() {
        // Older fork binaries emit no buildid/depots → 0/[] (no regression).
        XCTAssertEqual(parse(#"{"type":"done","bytesDownloaded":34000000}"#),
                       .done(bytesDownloaded: 34_000_000, buildID: 0, depots: []))
    }

    /// The fork's `done` event carries the installed buildid + depot manifests
    /// so Launcher can write an ACF Steam's library scan agrees is CURRENT.
    /// Values from the real Super Battle Golf install (Jul 2 2026): buildid
    /// 22804232, own depot 4069521, Steamworks redist 228989 shared from
    /// app 228980. Manifest ids are strings — they exceed Double precision.
    func testParse_doneWithBuildIDAndDepots() {
        let line = #"{"type":"done","bytesDownloaded":0,"buildid":22804232,"depots":[{"depot":4069521,"manifest":"1731867607556253764","size":1818015642},{"depot":228989,"manifest":"3514306556860204959","size":2639,"sharedApp":228980}]}"#
        XCTAssertEqual(parse(line), .done(
            bytesDownloaded: 0,
            buildID: 22_804_232,
            depots: [
                InstalledDepot(depotID: 4_069_521, manifestID: "1731867607556253764",
                               size: 1_818_015_642, sharedApp: nil),
                InstalledDepot(depotID: 228_989, manifestID: "3514306556860204959",
                               size: 2_639, sharedApp: 228_980),
            ]
        ))
        // Precision guard: the manifest id must round-trip EXACTLY (a Double
        // parse would corrupt 1731867607556253764 → 1731867607556253696).
        if case .done(_, _, let depots)? = parse(line) {
            XCTAssertEqual(depots.first?.manifestID, "1731867607556253764")
        } else {
            XCTFail("done event must parse")
        }
    }

    func testParse_error() {
        XCTAssertEqual(parse(#"{"type":"error","message":"REFRESH_TOKEN_INVALID"}"#),
                       .error(message: "REFRESH_TOKEN_INVALID"))
    }

    func testParse_humanProgressLineIsIgnored() {
        // The fork also prints human-readable lines that do NOT start with `{`.
        XCTAssertNil(parse(" 42.00% Animal Well.exe"))
        XCTAssertNil(parse("Logging 'nickjack876' into Steam3 with refresh token..."))
        XCTAssertNil(parse(""))
    }

    func testParse_garbageAndUnknownTypeReturnNil() {
        XCTAssertNil(parse("{not json"))
        XCTAssertNil(parse(#"{"type":"heartbeat"}"#))
        XCTAssertNil(parse(#"{"phase":"connecting"}"#)) // no "type"
    }

    // MARK: - Invocation contract (source invariants)

    func testRun_usesProvenArgContract() throws {
        let src = try readSource("Meridian/Launch/DepotDownloaderInstall.swift")
        // -os windows -osarch 64 is REQUIRED (defaults to host macOS otherwise).
        XCTAssertTrue(src.contains("\"-os\", \"windows\""),
                      "must force Windows depots with -os windows")
        XCTAssertTrue(src.contains("\"-osarch\", \"64\""),
                      "must force 64-bit depots with -osarch 64")
        XCTAssertTrue(src.contains("\"-refreshtoken\""),
                      "must authenticate via -refreshtoken (token-only SSO)")
        XCTAssertTrue(src.contains("\"-username\""),
                      "fork requires both -username and -refreshtoken")
        XCTAssertTrue(src.contains("\"-json\""),
                      "must request NDJSON progress with -json")
        XCTAssertTrue(src.contains("\"-app\""), "must pass -app <id>")
        XCTAssertTrue(src.contains("\"-dir\""), "must pass -dir <installDir>")
    }

    func testRun_cancellationSendsSIGTERM_andMapsExitCodes() throws {
        let src = try readSource("Meridian/Launch/DepotDownloaderInstall.swift")
        // Cancel = SIGTERM (Process.terminate sends SIGTERM → fork exits 130).
        XCTAssertTrue(src.contains("onCancel:") && src.contains("process.terminate()"),
                      "cancellation must SIGTERM the fork (resume-safe exit 130)")
        // Exit-code mapping: 3 → refreshTokenInvalid, cancel → CancellationError.
        XCTAssertTrue(src.contains("case 3:") && src.contains(".refreshTokenInvalid"),
                      "exit 3 must map to refreshTokenInvalid")
        XCTAssertTrue(src.contains("if Task.isCancelled") && src.contains("throw CancellationError()"),
                      "a cancelled task must throw CancellationError regardless of exit code")
    }

    func testRun_drainsStderrConcurrently() throws {
        let src = try readSource("Meridian/Launch/DepotDownloaderInstall.swift")
        // Both stdout AND stderr must be drained or a full stderr pipe (64 KB)
        // would stall the process → deadlock.
        XCTAssertTrue(src.contains("errPipe") && src.contains("Task.detached"),
                      "stderr must be drained concurrently to avoid pipe-fill deadlock")
    }

    /// stdout MUST be read INCREMENTALLY (readabilityHandler), not via
    /// `FileHandle.bytes.lines`. CLI-verified 2026-06-19: the fork streams
    /// NDJSON line-by-line to a pipe in real time, but `FileHandle.bytes.lines`
    /// does not yield those lines until the pipe reaches EOF (process exit) —
    /// the install ran and completed on disk while the UI sat at "Resuming
    /// download…" with zero progress, then dumped every buffered event the
    /// instant the process was terminated.
    func testRun_streamsStdoutLineByLineNotBufferedUntilEOF() throws {
        let src = try readSource("Meridian/Launch/DepotDownloaderInstall.swift")
        XCTAssertTrue(src.contains("readabilityHandler"),
                      "stdout must be read via readabilityHandler so NDJSON progress reaches the UI as it is written")
        XCTAssertFalse(src.contains("outHandle.bytes.lines"),
                      "stdout must NOT use FileHandle.bytes.lines — it buffers a subprocess pipe until EOF, so no live progress reaches the UI")
        XCTAssertTrue(src.contains("Self.lineStream(from: outHandle)"),
                      "the stdout consume loop must read from the incremental lineStream(from:) helper")
    }

    // MARK: - Launcher wiring

    func testLauncher_installGoesThroughDepotDownloader_notSteamExe() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("DepotDownloaderInstall.run"),
                      "install path must drive DepotDownloaderInstall.run")
        XCTAssertFalse(src.contains("session.installGame"),
                      "install must NOT depend on steam.exe (session.installGame removed from pipeline)")
    }

    func testLauncher_installGatesOnRefreshToken_notSteamReady() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("steamCredentialRefreshToken"),
                      "install must gate on a refresh token (SSO), not steam.exe readiness")
        XCTAssertTrue(src.contains("InstallError.notSignedIn"),
                      "missing refresh token must surface as notSignedIn")
        // The old blanket "Steam is not ready" install gate must be gone.
        XCTAssertFalse(src.contains("Steam is not ready. Please sign in before installing"),
                       "the steam.exe-readiness install gate must be removed")
    }

    func testLauncher_drmFreeLaunchDoesNotRequireSteamReady() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        // Only DRM games touch Steam. The Steam path must be gated on the
        // game's DRM requirement (gameRequiresSteamAPI → needsDRM).
        XCTAssertTrue(src.contains("let needsDRM = prefix.gameRequiresSteamAPI(appID: game.id)"),
                      "the Steam path must be gated on gameRequiresSteamAPI (DRM-only)")
        XCTAssertTrue(src.contains("if needsDRM {"),
                      "DRM handling must be gated behind `if needsDRM`")
        // DRM-free games must launch directly with NO Steam readiness gate.
        XCTAssertFalse(src.contains("guard session.isReady"),
                       "DRM-free launches must not gate on steam.exe readiness")
        XCTAssertFalse(src.contains("Please sign in before launching games"),
                       "the blanket launch gate must be removed")
    }

    /// Phase 4 (HANDOFF-2026-06-19): DRM games launch via a Steamworks API
    /// shim, NOT steam.exe. The Launcher must install the gbe_fork emulator
    /// over the game's Valve steam_api(64).dll (`prefix.installSteamEmulator`)
    /// and then launch DIRECTLY via wine64 — no steam.exe, no `-applaunch`,
    /// no silent-auth wall.
    func testLauncher_drmLaunchUsesSteamworksShim() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("prefix.installSteamEmulator("),
                      "Launcher must install the Steamworks API shim for DRM games")
        XCTAssertTrue(src.contains("result = try await launchDirect(game: game, engine: engine, session: session, drmShimActive: needsDRM)"),
                      "DRM (shimmed) AND DRM-free games must both launch directly via wine64")
        // The steam.exe -applaunch launch path must no longer be used in the Launcher.
        XCTAssertFalse(src.contains("launchViaSteam"),
                       "Launcher must not use the steam.exe -applaunch path for DRM games (replaced by the shim)")
        // The old lazy-steam warm must be gone from the DEFAULT (Offline)
        // launch path. `launchOnline` (explicit per-game Online opt-in,
        // HANDOFF-2026-07-02-v2) legitimately brings steam.exe up via
        // `ensureReadyForDRM` — so scope the ban to everything BEFORE
        // launchOnline's definition (executePipeline + the offline pipeline).
        if let onlineRange = src.range(of: "private func launchOnline") {
            let offlinePath = String(src[src.startIndex..<onlineRange.lowerBound])
            XCTAssertFalse(offlinePath.contains("session.ensureReadyForDRM"),
                           "The default (Offline) launch path must not lazy-warm steam.exe (replaced by the shim); only launchOnline may call ensureReadyForDRM")
        } else {
            XCTAssertFalse(src.contains("session.ensureReadyForDRM"),
                           "Launcher must not lazy-warm steam.exe for DRM launches (replaced by the shim)")
        }
    }

    /// SteamSession still EXPOSES the steam.exe DRM bring-up
    /// (`ensureReadyForDRM` / `launchGameViaSteam`) as a documented FALLBACK
    /// for SteamStub exe-encrypted titles the API shim can't satisfy — even
    /// though the default DRM launch path (Phase 4) is the shim. Guards against
    /// these being deleted (they would need to be rebuilt for SteamStub games).
    func testSteamSession_retainsSteamExeDRMFallback() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("func ensureReadyForDRM"),
                      "SteamSession must retain ensureReadyForDRM as the SteamStub fallback")
        XCTAssertTrue(src.contains("func launchGameViaSteam"),
                      "SteamSession must retain launchGameViaSteam as the SteamStub fallback")
    }

    // MARK: - Steamworks API shim (Phase 4)

    /// WineEngine must expose the staged gbe_fork emulator paths.
    func testWineEngine_exposesSteamEmuURLs() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")
        XCTAssertTrue(src.contains("var steamApi64EmuURL"),
                      "WineEngine must expose steamApi64EmuURL")
        XCTAssertTrue(src.contains("tools/steamemu"),
                      "the emulator must live at engine/tools/steamemu")
        XCTAssertTrue(src.contains("steam_api64.dll"),
                      "WineEngine must resolve the emulator's steam_api64.dll")
    }

    /// WinePrefix.installSteamEmulator must back up the original Valve dll,
    /// write the gbe_fork config, and never clobber the original twice.
    func testWinePrefix_installSteamEmulatorContract() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(src.contains("func installSteamEmulator"),
                      "WinePrefix must expose installSteamEmulator(appID:steamID:accountName:engine:)")
        XCTAssertTrue(src.contains(".valve"),
                      "installSteamEmulator must preserve the original Valve dll as <dll>.valve")
        XCTAssertTrue(src.contains("steam_appid.txt") && src.contains("configs.user.ini"),
                      "installSteamEmulator must write steam_settings/steam_appid.txt + configs.user.ini")
        XCTAssertTrue(src.contains("account_steamid="),
                      "configs.user.ini must set the user's account_steamid for the emulator")
    }

    /// release-engine.sh must stage the emulator into the engine tarball.
    func testReleaseEngine_stagesSteamEmu() throws {
        let src = try readSource("Scripts/release-engine.sh")
        XCTAssertTrue(src.contains("build-steamemu.sh"),
                      "release-engine.sh must run build-steamemu.sh")
        XCTAssertTrue(src.contains("tools/steamemu"),
                      "the emulator must stage into engine tools/steamemu")
    }

    /// build-steamemu.sh must pin a release tag (reproducible) and stage the
    /// regular (non-experimental) build.
    func testBuildSteamemu_pinsTagAndStagesRegular() throws {
        let src = try readSource("Scripts/build-steamemu.sh")
        XCTAssertTrue(src.contains("GBE_TAG="),
                      "build-steamemu.sh must pin a gbe_fork release tag for reproducibility")
        XCTAssertTrue(src.contains("regular/x64/steam_api64.dll"),
                      "build-steamemu.sh must stage the regular x64 steam_api64.dll")
    }

    // MARK: - Engine + manifest wiring

    func testWineEngine_exposesDepotDownloaderURL() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")
        XCTAssertTrue(src.contains("var depotDownloaderURL"),
                      "WineEngine must expose depotDownloaderURL")
        XCTAssertTrue(src.contains("tools/depotdownloader/DepotDownloader"),
                      "binary path must be engine/tools/depotdownloader/DepotDownloader")
    }

    func testWinePrefix_writesInstalledManifestStateFlags4() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(src.contains("func writeInstalledAppManifest"),
                      "WinePrefix must expose writeInstalledAppManifest")
        XCTAssertTrue(src.contains("\\t\"StateFlags\"\\t\\t\"4\""),
                      "installed manifest must write StateFlags=4 (fully installed)")
    }

    func testReleaseEngine_stagesDepotDownloader() throws {
        let src = try readSource("Scripts/release-engine.sh")
        XCTAssertTrue(src.contains("build-depotdownloader.sh"),
                      "release-engine.sh must build/stage the DepotDownloader fork")
        XCTAssertTrue(src.contains("tools/depotdownloader"),
                      "DepotDownloader must stage into engine tools/depotdownloader")
    }

    // MARK: - Sign-in sheet is not gated on steam.exe silent auth

    /// A returning user with a valid OAuth session must NOT be re-prompted to
    /// sign in just because Wine's `steam.exe` silent auto-login failed
    /// (Pattern 6). The sheet gate must depend on real identity / API-key state
    /// only — Steam is DRM-only now, and installs/DRM-free launches use the
    /// persisted refresh_token directly.
    func testContentView_setupSheetNotGatedOnSteamReady() throws {
        let src = try readSource("Meridian/Views/ContentView.swift")
        // The one-shot onAppear gate must NOT include !session.isReady.
        XCTAssertFalse(src.contains("!steamAuth.isAuthenticated || !session.isReady || steamAuth.needsAPIKey"),
                       "the setup gate must not force the sheet when steam.exe silent auth fails")
        XCTAssertTrue(src.contains("!steamAuth.isAuthenticated || steamAuth.needsAPIKey"),
                      "the setup gate must depend only on identity / API-key state")
        // The session.isReady→false re-show handler must be gone.
        XCTAssertFalse(src.contains("if !ready && steamAuth.isAuthenticated && !showSetupSheet"),
                       "session.isReady flipping false must NOT re-show the sign-in sheet")
        // Sign-out must still re-show the sheet (now in the else-branch of the
        // isAuthenticated onChange handler).
        XCTAssertTrue(src.contains("showSetupSheet = true"),
                      "signing out must still re-present the sign-in sheet")
        // Sign-IN must refresh the library: mainContent's one-shot .task runs
        // before authentication completes (steamID empty → refresh skipped),
        // so without this a user whose API key was already stored lands on an
        // empty library (observed July 2 2026 after the QR sign-in test).
        if let onChangeRange = src.range(of: ".onChange(of: steamAuth.isAuthenticated)") {
            let handler = String(src[onChangeRange.lowerBound...].prefix(700))
            XCTAssertTrue(handler.contains("library.refresh"),
                          "the isAuthenticated onChange handler must refresh the library on sign-in")
        } else {
            XCTFail("ContentView must observe steamAuth.isAuthenticated")
        }
    }

    // MARK: - Installed-manifest round-trip (mirror)

    /// Mirror of WinePrefix.writeInstalledAppManifest's VDF body (StateFlags=4).
    private func installedManifestVDF(appID: Int, name: String, installDir: String, steamID64: String) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"\(installDir)"
        \t"LastOwner"\t\t"\(steamID64)"
        }
        """
    }

    func testInstalledManifest_roundTripsStateFlagsAndInstallDir() {
        let vdf = installedManifestVDF(appID: 813230, name: "Animal Well",
                                       installDir: "Animal Well", steamID64: "76561198047018335")
        // StateFlags must be exactly "4" (what isGameFullyInstalled checks).
        XCTAssertTrue(vdf.contains("\"StateFlags\"\t\t\"4\""))
        // installdir must be present (what gameInstallDir reads).
        XCTAssertTrue(vdf.contains("\"installdir\"\t\t\"Animal Well\""))
    }

    // MARK: - Installed-manifest buildid + depots (Bug B, HANDOFF-2026-07-02-v4)

    /// Mirror of WinePrefix.installedAppManifestVDF (depot blocks only —
    /// asserts the structural pieces Steam's library scan compares).
    /// MIRROR CONTRACT: must match WinePrefix.installedAppManifestVDF.
    private func installedAppManifestVDFFull(
        buildID: Int, depots: [InstalledDepot]
    ) -> (installedBlock: String, sharedBlock: String) {
        let owned = depots.filter { $0.sharedApp == nil }
        let shared = depots.filter { $0.sharedApp != nil }

        var installedDepotsBlock = ""
        if !owned.isEmpty {
            installedDepotsBlock = "\n\t\"InstalledDepots\"\n\t{\n"
            for d in owned {
                installedDepotsBlock += "\t\t\"\(d.depotID)\"\n\t\t{\n"
                installedDepotsBlock += "\t\t\t\"manifest\"\t\t\"\(d.manifestID)\"\n"
                installedDepotsBlock += "\t\t\t\"size\"\t\t\"\(d.size)\"\n"
                installedDepotsBlock += "\t\t}\n"
            }
            installedDepotsBlock += "\t}"
        }
        var sharedDepotsBlock = ""
        if !shared.isEmpty {
            sharedDepotsBlock = "\n\t\"SharedDepots\"\n\t{\n"
            for d in shared {
                sharedDepotsBlock += "\t\t\"\(d.depotID)\"\t\t\"\(d.sharedApp ?? 0)\"\n"
            }
            sharedDepotsBlock += "\t}"
        }
        return (installedDepotsBlock, sharedDepotsBlock)
    }

    /// A DepotDownloader install must produce an ACF Steam agrees is CURRENT:
    /// real buildid + InstalledDepots (own depots) + SharedDepots (proxied).
    /// With buildid=0 / no depots, Steam flips StateFlags 4→6 and `-applaunch`
    /// silently queues a validation instead of launching (user-verified
    /// Jul 2 2026, Super Battle Golf Online).
    func testInstalledManifest_writesDepotBlocksSteamAgreesWith() {
        let depots = [
            InstalledDepot(depotID: 4_069_521, manifestID: "1731867607556253764",
                           size: 1_818_015_642, sharedApp: nil),
            InstalledDepot(depotID: 228_989, manifestID: "3514306556860204959",
                           size: 2_639, sharedApp: 228_980),
        ]
        let (installed, shared) = installedAppManifestVDFFull(buildID: 22_804_232, depots: depots)
        XCTAssertTrue(installed.contains("\"InstalledDepots\""))
        XCTAssertTrue(installed.contains("\"4069521\""))
        XCTAssertTrue(installed.contains("\"manifest\"\t\t\"1731867607556253764\""))
        // The shared (depotfromapp) depot must NOT land in InstalledDepots…
        XCTAssertFalse(installed.contains("228989"))
        // …but in SharedDepots, mapped to its owning app.
        XCTAssertTrue(shared.contains("\"SharedDepots\""))
        XCTAssertTrue(shared.contains("\"228989\"\t\t\"228980\""))
    }

    /// Source invariants: the writer accepts buildid + depots and the Launcher
    /// passes the fork's `done` values through.
    func testInstalledManifest_wiredWithBuildIDAndDepots() throws {
        let prefixSrc = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(prefixSrc.contains("depots: [DepotDownloaderInstall.InstalledDepot]"),
                      "writeInstalledAppManifest must accept the installed depot list")
        XCTAssertTrue(prefixSrc.contains("InstalledDepots") && prefixSrc.contains("SharedDepots"),
                      "the manifest VDF must include InstalledDepots + SharedDepots blocks")

        let launcherSrc = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(launcherSrc.contains("buildID: result.buildID"),
                      "installHeadless must pass the fork-reported buildid into the ACF")
        XCTAssertTrue(launcherSrc.contains("depots: result.depots"),
                      "installHeadless must pass the fork-reported depots into the ACF")

        let forkPatch = try readSource("Scripts/depotdownloader/meridian-task1.patch")
        XCTAssertTrue(forkPatch.contains("GetSteam3AppBuildNumber(appId, branch)"),
                      "the fork's done event must carry the installed branch buildid")
        XCTAssertTrue(forkPatch.contains("DepotManifestSizes"),
                      "the fork must record per-depot manifest sizes for the ACF")
    }
}
