import XCTest

/// Guard tests for the Online-mode seamlessness fixes
/// (HANDOFF-2026-07-02-v4 bugs A–E, fixed Jul 3 2026).
///
/// - Bug A: Steam's post-login UI must stay suppressed during `-applaunch` —
///   `SteamWindow.enterGameMode()` hides Steam-owned windows while exempting
///   the game's own Wine process.
/// - Bug D: Stop must work during `.launching`, and cancelling must stop the
///   GameProcess monitor (whose onLog otherwise keeps overwriting the UI).
/// - Bug E: `waitForLoggedOn` must extend its post-Connected deadline once a
///   credentialed logon is observably in progress, and the webhelper
///   fast-fail heuristic must only count THIS session's log tail.
final class OnlineFlowTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Bug A: game-mode suppression

    /// Mirror of SteamWindow.steamProcessPatterns.
    /// MIRROR CONTRACT: must match SteamWindow.steamProcessPatterns.
    private let steamProcessPatterns = ["steam.exe", "steamwebhelper"]

    func testSteamWindow_gameModeSuppressesSteamOnly() throws {
        let src = try readSource("Meridian/Steam/SteamWindow.swift")
        XCTAssertTrue(src.contains("func enterGameMode()"),
                      "SteamWindow must expose enterGameMode() for Online launches")
        XCTAssertTrue(src.contains("if gameMode, !steamOwnedPIDs.contains(pid) { return }"),
                      "game mode must exempt non-Steam Wine PIDs (the game) from hiding")
        XCTAssertTrue(src.contains("static let steamProcessPatterns"),
                      "Steam-owned processes must be identified by command-line patterns")
        for pattern in steamProcessPatterns {
            XCTAssertTrue(src.contains("\"\(pattern)\""),
                          "steamProcessPatterns must include \(pattern)")
        }
        // registerPID call sites are all Steam-side — they must join the
        // Steam-owned set immediately (no pgrep-refresh race).
        XCTAssertTrue(src.contains("steamOwnedPIDs.insert(pid)"),
                      "registerPID must add the PID to the Steam-owned set")
    }

    func testLaunchOnline_usesGameModeNotBlanketPause() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "private func launchOnline(") else {
            return XCTFail("launchOnline must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(through: after.range(of: "// MARK:")?.lowerBound ?? after.endIndex))

        XCTAssertTrue(body.contains("enterGameMode()"),
                      "launchOnline must switch the suppressor to game mode before -applaunch")
        XCTAssertFalse(body.contains("pauseForGame()"),
                       "launchOnline must NOT blanket-pause suppression — that let Steam's full post-login UI stay on screen (Bug A)")
    }

    // MARK: - Bug B (secondary): Steam-side validation signal during startup wait

    func testLaunchOnline_reportsSteamValidationInsteadOfSilentWait() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "private func launchOnline(") else {
            return XCTFail("launchOnline must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(through: after.range(of: "// MARK:")?.lowerBound ?? after.endIndex))
        XCTAssertTrue(body.contains("gameDownloadProgress(appID:"),
                      "the startup wait must poll the ACF for Steam-side update/validation state")
        XCTAssertTrue(body.contains("Steam is validating"),
                      "a queued validation must be reported to the user, not spun on silently")
    }

    // MARK: - Bug D: Stop/cancel during launches

    func testStopGame_handlesLaunchingState() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "func stopGame(") else {
            return XCTFail("stopGame must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(2500))
        XCTAssertTrue(body.contains("case .launching(let appID):"),
                      "stopGame must act during .launching (was a silent no-op — Bug D)")
        XCTAssertTrue(body.contains("launchTask?.cancel()"),
                      "stopping a launch in flight must cancel the pipeline task")
        XCTAssertTrue(body.contains("cancelMonitoring()"),
                      "Online stop must stop the monitor WITHOUT killing wineserver (Steam owns it)")
    }

    func testCancelLaunch_stopsProcessMonitor() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "func cancelLaunch(") else {
            return XCTFail("cancelLaunch must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(1200))
        XCTAssertTrue(body.contains("gameProcess.cancelMonitoring()"),
                      "cancelLaunch must stop the monitor — its onLog kept overwriting currentActivity after cancel (Bug D)")

        let gp = try readSource("Meridian/Engine/GameProcess.swift")
        XCTAssertTrue(gp.contains("func cancelMonitoring()"),
                      "GameProcess must expose cancelMonitoring (stop tracking, leave processes alone)")
        XCTAssertTrue(gp.contains("onLog = nil"),
                      "cancelMonitoring must detach onLog so no further UI writes occur")
    }

    // MARK: - Bug E: silent-auth deadline + webhelper heuristic

    /// Mirror of SteamSession.hasCredentialedLogonActivity.
    /// MIRROR CONTRACT: must match SteamSession.hasCredentialedLogonActivity.
    private func hasCredentialedLogonActivity(_ content: String) -> Bool {
        if content.contains("Logging on [U:1:") { return true }
        if content.contains("LogOn() called") { return true }
        var search = content[...]
        while let r = search.range(of: "SetSteamID( [U:1:") {
            let after = search[r.upperBound...]
            if let first = after.first, first != "0" { return true }
            search = after
        }
        return false
    }

    func testLogonActivity_detectedFromRealLogLines() {
        // Real lines from tonight's connection_log (Jul 2 2026):
        XCTAssertTrue(hasCredentialedLogonActivity(
            "[2026-07-02 23:06:42] [Logged Off, 0, 0] [U:1:86752607] CCMInterface::SetSteamID( [U:1:86752607] )"))
        XCTAssertTrue(hasCredentialedLogonActivity(
            "[Connected, 4, 7] [U:1:86752607] LogOn() called; already connected, sending credentials."))
        XCTAssertTrue(hasCredentialedLogonActivity(
            "[Connected, 4, 7] [U:1:86752607] Logging on [U:1:86752607]"))
        // Anonymous connect (SteamID zero) must NOT count as logon activity:
        XCTAssertFalse(hasCredentialedLogonActivity(
            "[2026-07-02 23:06:38] [Logged Off, 0, 0] [U:1:0] CCMInterface::SetSteamID( [U:1:0] )"))
        XCTAssertFalse(hasCredentialedLogonActivity(
            "Connectivity test: result=Connected (since 0.0s ago)"))
        // Multiple zero-id lines followed by a real one:
        XCTAssertTrue(hasCredentialedLogonActivity(
            "SetSteamID( [U:1:0] )\nSetSteamID( [U:1:0] )\nSetSteamID( [U:1:86752607] )"))
    }

    func testWaitForLoggedOn_extendsDeadlineOnLogonActivity() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("static func hasCredentialedLogonActivity"),
                      "SteamSession must detect credentialed logon activity as an observable signal")
        XCTAssertTrue(src.contains("if !logonActivitySeen, let ca = connectedAt"),
                      "the short post-Connected deadline must only apply BEFORE logon activity is seen (Bug E: 12 s killed a working silent auth)")
    }

    func testWebhelperHeuristic_isSessionScoped() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("webhelperLogOffset"),
                      "the webhelper fast-fail heuristic must read from a session-start offset")
        XCTAssertFalse(src.contains("readLogTail(path: webhelperPath, from: 0)"),
                       "reading webhelper_js.txt from offset 0 counts stale failures from previous Steam runs (Bug E)")
    }
}
