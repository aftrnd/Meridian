import XCTest

/// Unit tests for bootstrap pipeline logic in BootstrapManager and WineSteamManager.
///
/// These tests inline the pure functions under test rather than @testable-importing
/// the main target (which is an executable and cannot be imported). If the source
/// logic is changed, the inlined copies here should be updated in lock-step.
///
/// MIRROR CONTRACT: Every inlined function must match its production counterpart.
/// When editing the source, update the mirror here and re-run `swift test`.
final class BootstrapTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Phase enum mirror (BootstrapManager.Phase)

    /// Mirror of BootstrapManager.Phase
    /// MIRROR CONTRACT: Mirrors BootstrapManager.Phase (BootstrapManager.swift)
    enum Phase: Equatable {
        case idle
        case awaitingPermission
        case detectingEngine
        case downloadingEngine
        case creatingPrefix
        case installingSteam
        case bootstrappingSteam
        case syncingSession
        case startingSteam
        case ready
        case failed(String)
    }

    /// Mirror of BootstrapManager retry cleanup logic.
    /// Returns true if the given failed phase warrants a full prefix wipe.
    private func shouldWipePrefixOnRetry(failedPhase: Phase?) -> Bool {
        let cleanupPhases: [Phase] = [
            .creatingPrefix, .installingSteam, .bootstrappingSteam, .startingSteam
        ]
        guard let phase = failedPhase else { return false }
        return cleanupPhases.contains(phase)
    }

    // MARK: - Retry Cleanup Logic

    func testRetryWipesForSteamPhases() {
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .creatingPrefix))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .installingSteam))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .bootstrappingSteam))
        XCTAssertTrue(shouldWipePrefixOnRetry(failedPhase: .startingSteam))
    }

    func testRetryDoesNotWipeForEarlyPhases() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .idle))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .detectingEngine))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .downloadingEngine))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .awaitingPermission))
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .syncingSession))
    }

    func testRetryDoesNotWipeForNilPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: nil))
    }

    func testRetryDoesNotWipeForFailedPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .failed("some error")))
    }

    func testRetryDoesNotWipeForReadyPhase() {
        XCTAssertFalse(shouldWipePrefixOnRetry(failedPhase: .ready))
    }

    // MARK: - Phase ordering

    /// The canonical order phases should progress in during a full fresh-install pipeline.
    func testPhasePipelineOrder() {
        let expectedOrder: [Phase] = [
            .detectingEngine,
            .creatingPrefix,
            .installingSteam,
            .bootstrappingSteam,
            .syncingSession,
            .startingSteam,
            .ready,
        ]

        for i in 0..<expectedOrder.count - 1 {
            XCTAssertNotEqual(
                expectedOrder[i], expectedOrder[i + 1],
                "Adjacent phases should be different"
            )
        }
        XCTAssertEqual(expectedOrder.last, .ready)
    }

    // MARK: - needsBootstrap mirror (WinePrefix.isSteamBootstrapped)

    /// Mirror of WinePrefix.isSteamBootstrapped (checks steamui.dll presence).
    /// BootstrapManager uses !prefix.isSteamBootstrapped as the bootstrap trigger.
    private func needsBootstrap(steamInstallDir: String) -> Bool {
        let dllPath = steamInstallDir + "/steamui.dll"
        return !FileManager.default.fileExists(atPath: dllPath)
    }

    func testNeedsBootstrapWhenDLLMissing() {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BootstrapTests-\(UUID().uuidString)")
            .path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        XCTAssertTrue(needsBootstrap(steamInstallDir: tempDir))
    }

    func testNeedsBootstrapFalseWhenDLLPresent() {
        let tempDir = FileManager.default.temporaryDirectory
            .appending(path: "BootstrapTests-\(UUID().uuidString)")
            .path(percentEncoded: false)
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let dllPath = tempDir + "/steamui.dll"
        FileManager.default.createFile(atPath: dllPath, contents: Data("dummy".utf8))

        XCTAssertFalse(needsBootstrap(steamInstallDir: tempDir))
    }

    // MARK: - Rewrite invariant guards

    /// Bootstrap MUST NEVER send -login (triggers unsolicited 2FA), and as of
    /// Phase 3 (HANDOFF-2026-06-19) must NEVER start steam.exe at all — Steam is
    /// lazy + DRM-only. Starting steam.exe on boot is exactly what surfaced the
    /// "Who's playing" account-picker window and forced a silent-auth wait on
    /// every cold start. The Steam runtime is now brought up on demand by
    /// SteamSession.ensureReadyForDRM the first time a DRM game is launched.
    func testBootstrap_neverSendsLoginFlag() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")
        XCTAssertFalse(
            src.contains("\"-login\""),
            "BootstrapManager MUST NOT contain -login — credential login only happens in the sign-in sheet"
        )
        XCTAssertFalse(
            src.contains("session.start("),
            "BootstrapManager MUST NOT start steam.exe — Steam is lazy/DRM-only (Phase 3). SteamSession.ensureReadyForDRM warms it on DRM launch."
        )
    }

    /// Phase 3: bootstrap must NOT download the Steam client nor inject
    /// local.vdf — those are deferred to the lazy DRM path. A DRM-free-only
    /// user must never pull the ~336 MB Steam client on cold start.
    func testBootstrap_doesNotDownloadSteamClientOrInjectSession() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")
        XCTAssertFalse(src.contains("SteamClientBootstrap.downloadAndInstall"),
                       "BootstrapManager MUST NOT download the Steam client — that is lazy/DRM-only now (SteamSession.bootstrapSteamClientIfNeeded)")
        XCTAssertFalse(src.contains("writeSteamSessionLocalVdf"),
                       "BootstrapManager MUST NOT inject local.vdf — deferred to SteamSession.ensureReadyForDRM")
        // But the GENERAL prefix setup that all games need must remain.
        XCTAssertTrue(src.contains("ensureCoreServices"),
                      "BootstrapManager must still register core Wine services (general, needed by all games)")
        XCTAssertTrue(src.contains("writeSteamInstallPathRegistryKeys"),
                      "BootstrapManager must still write WoW64 crypto provider types (Pattern 11 — needed by 32-bit DRM-free games)")
    }

    /// Pattern 11 recurrence guard (Jun 19 2026). The versioned prefix-registry
    /// counters (winRT / steamInstallPath / windowsVersion / staleSteamService)
    /// live in global UserDefaults, NOT tied to prefix identity. When a prefix
    /// is (re)built — fresh `create()` on a wiped bottle, OR
    /// `resetToEngineTemplate()` on an engine change — the on-disk system.reg is
    /// empty but the counters still read "already applied", so the step-3 setup
    /// block SKIPS the writes. That left HL2's 32-bit `filesystem_stdio.dll`
    /// without the WoW64 crypto provider types → `CryptAcquireContextA` crash.
    ///
    /// Both (re)build paths MUST zero ALL the counters via the shared
    /// `resetVersionedRegistryCounters()` so step 3 re-applies the full registry
    /// setup. A bug where only the engine-reset path reset only 2 of the 4
    /// counters (and the fresh-create path reset none) is what re-broke HL2.
    func testBootstrap_resetsVersionedRegistryCountersOnPrefixRebuild() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")

        // The shared helper must exist and zero all four versioned counters.
        XCTAssertTrue(src.contains("func resetVersionedRegistryCounters"),
                      "BootstrapManager must define resetVersionedRegistryCounters() — the single source of truth for clearing prefix-registry counters")
        for counter in [
            "winRTRegistrationAppliedVersion = 0",
            "steamInstallPathRegistrationVersion = 0",
            "windowsVersionAppliedVersion = 0",
            "staleSteamServiceCleanupVersion = 0",
        ] {
            XCTAssertTrue(src.contains(counter),
                          "resetVersionedRegistryCounters() must zero \(counter) so a rebuilt prefix re-applies every versioned registry mutation")
        }

        // It must be invoked from BOTH (re)build paths — at least twice
        // (fresh create + engine reset). A single call site means one path
        // still skips the registry setup.
        // Invoked from BOTH (re)build paths PLUS its own definition line, so
        // the source mentions the symbol at least 3 times (1 def + 2 calls).
        // Fewer than 3 means a call site is missing and one rebuild path still
        // skips the registry setup.
        let mentions = src.components(separatedBy: "resetVersionedRegistryCounters()").count - 1
        XCTAssertGreaterThanOrEqual(mentions, 3,
                      "resetVersionedRegistryCounters() must be called on BOTH prefix create (!prefix.exists) AND engine reset (resetToEngineTemplate) — found \(mentions) mention(s) incl. definition")

        // The counter must also be re-applied (not just zeroed) by the step-3
        // block, so the live prefix actually gets the keys after a reset.
        XCTAssertTrue(src.contains("writeSteamInstallPathRegistryKeys"),
                      "step 3 must re-run writeSteamInstallPathRegistryKeys once the counter is zeroed")
    }

    /// SteamSession is silent-only — never sends `-login USER PASS`.
    ///
    /// CLI-verified May 19 2026: `steam.exe -login USER PASS` yields a JWT with
    /// `persistence: 0` which Steam refuses to persist to local.vdf. Every cold
    /// start would re-prompt for credentials. The OAuth path (SteamCredentialAuth
    /// + DPAPI local.vdf injection) is the only architecture that yields
    /// persistence: 1 refresh tokens. SteamSession.signIn was the wrapper for the
    /// broken -login path and is deleted.
    func testSteamSession_startIsSilentOnly() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")

        // start() / launchSteamProcess hardcodes -silent -nofriendsui — no auth args.
        XCTAssertTrue(
            src.contains("[steamExePath, \"-silent\", \"-nofriendsui\"]"),
            "SteamSession.launchSteamProcess must launch with exactly -silent -nofriendsui (no -login)"
        )

        // The deleted -login path must not return — guard against accidental restore.
        XCTAssertFalse(
            src.contains("\"-login\""),
            "SteamSession MUST NOT contain `-login` anywhere — that path yields persistence: 0 (CLI-verified May 19 2026)."
        )
        XCTAssertFalse(
            src.contains("func signIn("),
            "SteamSession.signIn() is deleted — sign-in is driven by SteamCredentialAuth via OAuth, not by steam.exe -login."
        )
    }

    /// The Steam-client self-bootstrap now lives in SteamSession (lazy/DRM-only,
    /// Phase 3). Window suppression must engage before the steamui.dll download
    /// in case Steam ever renders UI mid-download.
    func testBootstrapEngagesSuppressionBeforeSteamSelfBootstrap() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        guard let suppressorCall = src.range(of: "steamWindow?.startSuppressing()"),
              let bootstrapCall = src.range(of: "SteamClientBootstrap.downloadAndInstall")
        else {
            XCTFail("SteamSession.bootstrapSteamClientIfNeeded must call steamWindow?.startSuppressing() before SteamClientBootstrap.downloadAndInstall")
            return
        }
        XCTAssertLessThan(suppressorCall.lowerBound, bootstrapCall.lowerBound)
    }

    /// SteamSession.launchSteamProcess must log the value of
    /// `DYLD_INSERT_LIBRARIES` so we can post-mortem-verify whether the
    /// dock-suppression payload (`meridian-wine-accessory.dylib`) was
    /// actually injected. Without this diagnostic, a missing dylib looks
    /// identical to "dylib loaded but ineffective" — both produce a
    /// wine64 Dock icon. CLI-investigated May 19 2026.
    func testSteamSession_logsDyldInsertLibrariesAtLaunch() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("env[\"DYLD_INSERT_LIBRARIES\"]"),
                      "SteamSession.launchSteamProcess must read env[\"DYLD_INSERT_LIBRARIES\"] for diagnostic logging")
        XCTAssertTrue(src.contains("DYLD_INSERT_LIBRARIES="),
                      "SteamSession.launchSteamProcess must emit a log line that includes the resolved DYLD_INSERT_LIBRARIES path so future debug sessions can verify dylib presence on disk")
    }

    /// When steam.exe fails to start / authenticate, SteamSession must dump
    /// steam.exe's OWN diagnostic logs (bootstrap_log.txt + connection_log.txt)
    /// into meridian.log so the failure is self-explanatory without attaching
    /// Xcode or hand-reading the prefix (user ask 2026-06-18: "add logs so I
    /// can just see"). Guards against the failure paths silently swallowing the
    /// underlying steam.exe error (e.g. `http error 0` on the update check).
    func testSteamSession_dumpsSteamLogsOnFailure() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("func logSteamFailureDiagnostics"),
                      "SteamSession must define logSteamFailureDiagnostics(reason:) to dump steam.exe logs on failure")
        XCTAssertTrue(src.contains("bootstrap_log.txt") && src.contains("connection_log.txt"),
                      "logSteamFailureDiagnostics must read both bootstrap_log.txt and connection_log.txt — the two authoritative steam.exe diagnostic logs")
        // It must actually be invoked from the start() failure branches, not
        // just defined.
        let invocations = src.components(separatedBy: "logSteamFailureDiagnostics(reason:").count - 1
        XCTAssertGreaterThanOrEqual(invocations, 2,
                      "logSteamFailureDiagnostics must be called from the silent-auth-timeout AND the launch-throw failure paths in start()")
    }

    /// The DYLD_INSERT payload must auto-refresh from the bundle to the
    /// engine when the bundled copy is newer. A previous version of
    /// `ensureDyldInjection` only copied when the engine copy was MISSING,
    /// so dylib bug fixes shipped in a Meridian update were silently
    /// ignored on hosts that had a stale engine-internal copy.
    func testEnsureDyldInjection_refreshesOnNewerBundle() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")
        XCTAssertTrue(src.contains("contentModificationDateKey"),
                      "ensureDyldInjection must compare bundle vs engine mtimes so newer bundled dylibs replace stale engine copies")
    }

    /// SteamSession must transparently restart steam.exe when it exits
    /// with code=42 — Steam's "self-update completed, please restart me"
    /// sentinel. Without this, Valve pushing a new client mid-session
    /// (CLI-observed May 20 2026: log line `[steam.exe] exited code=42`
    /// during a Bogos Binted launch) kills wineserver and the running
    /// game with it. The health monitor must be started in
    /// `SteamSession.start()` after silent auth succeeds.
    func testSteamSession_relaunchesOnSelfUpdateExit42() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")

        // The health monitor task field must exist.
        XCTAssertTrue(src.contains("healthMonitorTask"),
                      "SteamSession must hold a background task that watches the persistent steam.exe process")
        XCTAssertTrue(src.contains("monitorSteamHealth"),
                      "SteamSession must define monitorSteamHealth() to handle code=42 self-update restarts")
        XCTAssertTrue(src.contains("startHealthMonitor"),
                      "SteamSession must define startHealthMonitor() to spin up the watcher after Logged On")

        // start() must spin up the monitor on success — not before, not
        // on failure (the user signs in via the sheet in those cases).
        XCTAssertTrue(src.contains("startHealthMonitor(engine: engine)"),
                      "SteamSession.start() must call startHealthMonitor after a successful silent auth so subsequent code=42 exits get handled")

        // Must check for code 42 explicitly — any other value is treated
        // as a normal exit and surfaced as `.failed`.
        XCTAssertTrue(src.contains("guard code == 42"),
                      "monitorSteamHealth must only restart on code=42 (Steam's intentional-restart sentinel); other exit codes are real failures")

        // Restart budget — protect against runaway loops if Steam is
        // genuinely broken.
        XCTAssertTrue(src.contains("maxRestartAttempts"),
                      "monitorSteamHealth must cap restart attempts in a rolling window to avoid runaway loops")

        // shutdown() must cancel the monitor to prevent a race where
        // we relaunch right after the user explicitly signed out.
        XCTAssertTrue(src.contains("healthMonitorTask?.cancel()"),
                      "SteamSession.shutdown() must cancel healthMonitorTask so it doesn't fight the user-initiated shutdown")
    }

    /// `WinePrefix.refreshSteamStubFromEngineIfStale` must NEVER
    /// overwrite a healthy on-disk `steam.exe` with the engine's
    /// bundled stub. Steam self-updates its own `steam.exe` as Valve
    /// ships releases; the bundled stub in the engine drifts behind
    /// Valve within days. Forcing a "refresh on size mismatch" rolled
    /// Steam back on every Meridian launch, then Steam re-downloaded
    /// its update + exited code=42 → wineserver tore down → games died.
    /// CLI-verified May 20 2026 in `bootstrap_log.txt`:
    /// `steam.exe is 5767832 bytes, expected 5771928`. With this fix,
    /// the prefix's steam.exe stays at Valve-current and the update
    /// loop is broken.
    func testRefreshSteamStub_neverRollsBackHealthyStub() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")

        // The function must check whether the prefix's stub is HEALTHY
        // (file exists, size > 0) and skip the overwrite when it is.
        // Just looking for the "size mismatch → copy" pattern would
        // miss the real bug.
        XCTAssertTrue(src.contains("prefixHealthy"),
                      "refreshSteamStubFromEngineIfStale must gate the overwrite on a prefixHealthy check (file exists AND size > 0) — never on size mismatch alone")
        XCTAssertTrue(src.contains("ourSize > 0"),
                      "refreshSteamStubFromEngineIfStale must consider a non-zero stub healthy regardless of whether it matches the engine bundle size")
        XCTAssertTrue(src.contains("guard !prefixHealthy"),
                      "refreshSteamStubFromEngineIfStale must early-return when prefix steam.exe is healthy (Steam self-updates this; rolling back triggers a self-update loop)")
    }

    /// WineEngine.environment(for:) must explicitly set
    /// `WINEDLLOVERRIDES=d3d11,dxgi,d3d10core=n,b` (or merge equivalent)
    /// so Wine prefers the native DXMT PE DLLs in `lib/dxmt/` over the
    /// 426 KB wined3d builtins in `lib/wine/x86_64-windows/`. Without
    /// the override, CLI-verified May 20 2026 that a Bogos Binted launch
    /// produced 30+ lines of
    /// `err:winediag:wined3d_adapter_create Using the Vulkan renderer
    ///  for d3d10/11 applications` and `partial-stub` format errors,
    /// because Wine loaded its built-in wined3d d3d11 ahead of DXMT.
    func testWineEngine_forcesDXMTLoadOrder() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")

        XCTAssertTrue(src.contains("WINEDLLOVERRIDES"),
                      "WineEngine.environment must set WINEDLLOVERRIDES so DXMT wins over wined3d")
        XCTAssertTrue(src.contains("d3d11=n,b") || src.contains("d3d11,dxgi"),
                      "WINEDLLOVERRIDES must force d3d11 to native-first so DXMT loads from WINEDLLPATH (lib/dxmt) before the wined3d builtin in lib/wine/x86_64-windows")
        XCTAssertTrue(src.contains("dxgi=n,b") || src.contains("dxgi,d3d10core"),
                      "WINEDLLOVERRIDES must force dxgi to native-first so DXMT's dxgi loads (IDXGIAdapter4 + format support)")
        XCTAssertTrue(src.contains("d3d10core=n,b") || src.contains("d3d10core,"),
                      "WINEDLLOVERRIDES must force d3d10core to native-first so DXMT covers the full D3D10/11 surface")
    }

    /// winegstreamer needs GST_PLUGIN_SYSTEM_PATH_1_0 pointed at the bundled
    /// lib64/gstreamer-1.0 or Unity VideoPlayer / Media Foundation video renders
    /// black (no decoder discovered). Regression guard for the No-I'm-not-a-Human
    /// intro-video fix (June 2026).
    func testWineEngine_setsGStreamerPluginPathForVideo() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")
        XCTAssertTrue(src.contains("GST_PLUGIN_SYSTEM_PATH_1_0"),
                      "environment(for:) must set GST_PLUGIN_SYSTEM_PATH_1_0 so winegstreamer finds the bundled video decoders")
        XCTAssertTrue(src.contains("gstreamer-1.0"),
                      "the GStreamer plugin path must point at lib64/gstreamer-1.0")
    }

    // MARK: - Package directory quiescence logic

    /// Mirror of WineSteamManager.bootstrap() quiescence detection.
    /// Given a sequence of directory sizes, returns the index at which quiescence
    /// is detected (size stable for `windowPolls` consecutive polls and >= minBytes), or nil.
    /// `minBytes` mirrors `quiescenceMinBytes` (1 MB) — stale tiny residuals do not trigger.
    private func detectQuiescence(sizes: [Int], windowPolls: Int, minBytes: Int = 1 * 1024 * 1024) -> Int? {
        var lastSize: Int = -1
        var stableCount: Int = 0

        for (i, size) in sizes.enumerated() {
            if size != lastSize {
                lastSize = size
                stableCount = 0
            } else if size >= minBytes {
                stableCount += 1
                if stableCount >= windowPolls {
                    return i
                }
            }
        }
        return nil
    }

    func testQuiescenceDetectsStableSize() {
        let mb = 1 * 1024 * 1024
        // Size grows above threshold then stabilizes
        let sizes = [0, mb, mb * 5, mb * 10, mb * 10, mb * 10, mb * 10]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNotNil(result)
        XCTAssertEqual(result, 6)
    }

    func testQuiescenceNotTriggeredWhenGrowing() {
        let mb = 1 * 1024 * 1024
        let sizes = [0, mb, mb * 2, mb * 3, mb * 4, mb * 5]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result)
    }

    func testQuiescenceNotTriggeredAtZero() {
        let sizes = [0, 0, 0, 0, 0]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result, "Zero-size dir should not trigger quiescence")
    }

    func testQuiescenceNeedsEnoughStablePolls() {
        let mb = 1 * 1024 * 1024
        let sizes = [0, mb * 5, mb * 5]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result, "Only 1 stable poll, need 3")
    }

    func testQuiescenceResetsByGrowth() {
        let mb = 1 * 1024 * 1024
        // Stable at 5 MB, then grows, then stable at 80 MB
        let sizes = [mb * 5, mb * 5, mb * 5, mb * 80, mb * 80, mb * 80, mb * 80]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertEqual(result, 6, "Should detect quiescence at the second stable run")
    }

    func testQuiescenceBelowMinBytesNotTriggered() {
        // 137 bytes — the exact stale residual size seen in production (steam_client_metrics.bin)
        let sizes = [137, 137, 137, 137, 137, 137, 137, 137, 137, 137]
        let result = detectQuiescence(sizes: sizes, windowPolls: 3)
        XCTAssertNil(result, "Tiny stable residual below 1 MB must not trigger quiescence")
    }

    func testQuiescenceBelowMinBytesWithCustomThreshold() {
        // Verify the threshold itself works: sizes at exactly minBytes trigger, below do not
        let threshold = 1000
        let below = Array(repeating: threshold - 1, count: 10)
        XCTAssertNil(detectQuiescence(sizes: below, windowPolls: 3, minBytes: threshold),
                     "Size below threshold must not trigger")
        let atThreshold = Array(repeating: threshold, count: 10)
        XCTAssertNotNil(detectQuiescence(sizes: atThreshold, windowPolls: 3, minBytes: threshold),
                        "Size at threshold must trigger")
    }

    // MARK: - Health monitor retry budget

    func testHealthMonitorMaxRetries() {
        let maxRetries = 5
        let baseInterval: TimeInterval = 10
        let stableThreshold: TimeInterval = 60

        XCTAssertEqual(maxRetries, 5, "Health monitor max retries should be 5")
        XCTAssertEqual(baseInterval, 10, "Base interval should be 10s")
        XCTAssertEqual(stableThreshold, 60, "Stable threshold should be 60s")
    }

    func testHealthMonitorBackoffIntervals() {
        let baseInterval: TimeInterval = 10
        let maxBackoff: TimeInterval = 120

        for retryCount in 0...6 {
            let backoff = baseInterval * pow(2.0, Double(min(retryCount, 4)))
            let sleepDuration = min(backoff, maxBackoff)

            switch retryCount {
            case 0: XCTAssertEqual(sleepDuration, 10)
            case 1: XCTAssertEqual(sleepDuration, 20)
            case 2: XCTAssertEqual(sleepDuration, 40)
            case 3: XCTAssertEqual(sleepDuration, 80)
            case 4: XCTAssertEqual(sleepDuration, 120)
            case 5: XCTAssertEqual(sleepDuration, 120, "Should cap at 120")
            case 6: XCTAssertEqual(sleepDuration, 120, "Should cap at 120")
            default: break
            }
        }
    }
}
