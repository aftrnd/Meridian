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
        let body = String(after.prefix(5000))
        XCTAssertTrue(body.contains("case .launching(let appID):"),
                      "stopGame must act during .launching (was a silent no-op — Bug D)")
        XCTAssertTrue(body.contains("launchTask?.cancel()"),
                      "stopping a launch in flight must cancel the pipeline task")
        XCTAssertTrue(body.contains("cancelMonitoring()"),
                      "Online stop must stop the monitor WITHOUT killing wineserver (Steam owns it)")
    }

    // MARK: - steamwebhelper surfacing after stop (user-reported Jul 3 2026)

    /// Stopping a game while the persistent Steam session is alive must NOT
    /// `wineserver -k` (that SIGKILLs steam.exe + steamwebhelper; CEF treats
    /// the next boot as crash recovery and surfaces webhelper windows), and
    /// it MUST restore window suppression (the .running stop path was
    /// missing `resumeAfterGame`, leaving the suppressor paused/in game
    /// mode indefinitely).
    func testStopGame_runningStopKeepsSteamAliveAndResumesSuppression() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "func stopGame(") else {
            return XCTFail("stopGame must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(5000))

        guard let runningCase = body.range(of: "case .running(let appID):"),
              let launchingCase = body.range(of: "case .launching(let appID):") else {
            return XCTFail("stopGame must handle .running and .launching")
        }
        let runningBody = String(body[runningCase.lowerBound..<launchingCase.lowerBound])

        XCTAssertTrue(runningBody.contains("activeSession?.isReady == true"),
                      ".running stop must check whether the persistent Steam session is alive")
        XCTAssertTrue(runningBody.contains("killGameProcesses(pattern:"),
                      ".running stop must kill only the game's processes when Steam shares the wineserver")
        XCTAssertTrue(runningBody.contains("resumeAfterGame(steamPID: 0)"),
                      ".running stop must restore window suppression (was missing — webhelper windows surfaced at will)")

        let gp = try readSource("Meridian/Engine/GameProcess.swift")
        XCTAssertTrue(gp.contains("func killGameProcesses(pattern:"),
                      "GameProcess must expose the surgical game-only kill")
        XCTAssertTrue(gp.contains("/usr/bin/pkill"),
                      "killGameProcesses must use pkill -f on the game's installdir pattern")
    }

    /// A dead steam.exe behind `isReady == true` makes ensureReadyForDRM
    /// skip the bring-up entirely and dispatch -applaunch against nothing —
    /// the fresh steam.exe cold-boots unmanaged and webhelper windows can
    /// surface. The health monitor must mark the session state truthfully
    /// on a non-42 exit (fail-fast: state must reflect the observed signal).
    func testHealthMonitor_marksSessionIdleOnNon42Exit() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        guard let fn = src.range(of: "private func monitorSteamHealth(") else {
            return XCTFail("monitorSteamHealth must exist")
        }
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(3500))
        XCTAssertTrue(body.contains("guard code == 42 else"),
                      "only Steam's intentional-restart sentinel may trigger a relaunch (Pattern 14)")
        XCTAssertTrue(body.contains("if case .running = state { state = .idle }"),
                      "a non-42 exit must clear the stale .running state so the next launch does a full bring-up")
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

    func testWaitForLoggedOn_reportsStagesToCaller() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("onStatus: (@MainActor (String) -> Void)? = nil"),
                      "waitForLoggedOn must accept an onStatus callback for launch-card progress")
        XCTAssertTrue(src.contains("report(\"Starting Steam client"),
                      "waitForLoggedOn must report the first boot stage immediately")
        XCTAssertTrue(src.contains("report(\"Connected to Steam servers\")"),
                      "waitForLoggedOn must report when Valve connectivity succeeds")
        XCTAssertTrue(src.contains("report(\"Signing in to your Steam account"),
                      "waitForLoggedOn must report credentialed logon activity")
        XCTAssertTrue(src.contains("func start(engine: WineEngine, onStatus:"),
                      "start() must forward onStatus into waitForLoggedOn")
    }

    func testWebhelperHeuristic_isSessionScoped() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("webhelperLogOffset"),
                      "the webhelper fast-fail heuristic must read from a session-start offset")
        XCTAssertFalse(src.contains("readLogTail(path: webhelperPath, from: 0)"),
                       "reading webhelper_js.txt from offset 0 counts stale failures from previous Steam runs (Bug E)")
    }

    // MARK: - Steam notification toasts

    /// Steam reads none of these (sp.js, SteamUI.dll, bin/friendsui.dll and
    /// steamclient64.dll searched in ASCII and UTF-16, Oct 26 2026;
    /// `DownloadCompleted` is only a notification type's name). Its toasts
    /// are kept off screen by the engine's window hold instead
    /// (`WinePrefix.writeSteamWindowHold`).
    func testNoNotificationKeysSteamNeverReads() throws {
        for path in ["Meridian/Engine/WinePrefix.swift", "Meridian/Steam/SteamSession.swift",
                     "Meridian/Views/Auth/AuthView.swift"] {
            let src = try readSource(path)
            for key in ["ShowDesktopToast", "ShowInGameToast", "PlaySoundDownload",
                        "EnableCustomSounds", "EnableStandardSounds", "DesktopNotifications"] {
                XCTAssertFalse(src.contains(key), "\(path): Steam reads no \(key)")
            }
        }
    }

    // MARK: - Sign out

    /// Sign Out left Steam's own client signed in: a running Steam kept the
    /// old account, rewrote local.vdf as it later quit, and setup's "Sign in
    /// to Steam" step skipped itself (`steamClientSignedIn` stayed true).
    func testSignOut_quitsSteamBeforeForgettingTheAccount() throws {
        let settings = try readSource("Meridian/Views/Settings/SettingsView.swift")
        guard let start = settings.range(of: "private func signOut() {"),
              let quit = settings.range(of: "await session.signOut(engine: engine)", range: start.upperBound..<settings.endIndex),
              let forget = settings.range(of: "steamAuth.signOut()", range: start.upperBound..<settings.endIndex)
        else { return XCTFail("Settings › Sign Out must sign out of Steam and of Meridian") }
        XCTAssertLessThan(quit.lowerBound, forget.lowerBound,
                          "Steam quits first: it writes local.vdf on the way out")
        guard let relaunch = settings.range(of: "AppDelegate.relaunch()", range: forget.upperBound..<settings.endIndex)
        else { return XCTFail("Sign Out must restart Meridian") }
        XCTAssertLessThan(forget.lowerBound, relaunch.lowerBound,
                          "The old library stayed behind setup until a restart")

        let session = try readSource("Meridian/Steam/SteamSession.swift")
        guard let body = session.range(of: "func signOut(engine: WineEngine) async {") else {
            return XCTFail("SteamSession.signOut(engine:) must exist")
        }
        XCTAssertTrue(session[body.upperBound...].prefix(400).contains("await shutdown(engine: engine)"))

        let auth = try readSource("Meridian/Steam/SteamAuthService.swift")
        guard let signOut = auth.range(of: "func signOut() {"),
              let end = auth.range(of: "\n    }\n", range: signOut.upperBound..<auth.endIndex)
        else { return XCTFail("SteamAuthService.signOut() must exist") }
        XCTAssertTrue(auth[signOut.upperBound..<end.lowerBound].contains("AppSettings.shared.steamClientSignedIn = false"),
                      "setup must open Steam's own sign-in again")
    }

    /// After Sign Out the old account's library stayed on screen until the
    /// app was restarted (user, Oct 12 2026).
    func testSignOut_emptiesTheLibraryAtOnce() throws {
        let content = try readSource("Meridian/Views/ContentView.swift")
        guard let change = content.range(of: "onChange(of: steamAuth.isAuthenticated)"),
              let signedOut = content.range(of: "} else {", range: change.upperBound..<content.endIndex),
              let sheet = content.range(of: "showSetupSheet = true", range: signedOut.upperBound..<content.endIndex)
        else { return XCTFail("ContentView must react to signing out") }
        XCTAssertTrue(content[signedOut.upperBound..<sheet.lowerBound].contains("library.signOut()"))
        let store = try readSource("Meridian/Steam/SteamLibraryStore.swift")
        XCTAssertTrue(store.contains("func signOut() {"))
    }

    /// Skipping setup left a blank window: Home and Library had nothing to
    /// show and no way forward (user, Oct 12 2026).
    func testEmptyLibrary_explainsAndOffersSetup() throws {
        for path in ["Meridian/Views/HomeView.swift", "Meridian/Views/Library/LibraryView.swift"] {
            let src = try readSource(path)
            XCTAssertTrue(src.contains("LibraryEmptyState()"), "\(path) must show the empty library state")
        }
        let library = try readSource("Meridian/Views/Library/LibraryView.swift")
        XCTAssertTrue(library.contains("NotificationCenter.default.post(name: .meridianShowSetup, object: nil)"))
        let content = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertTrue(content.contains("publisher(for: .meridianShowSetup)"),
                      "ContentView must reopen setup for the empty state's button")
    }

    /// Sign Out's relaunch hung: `terminate(_:)` called from a @MainActor
    /// Task waited forever for a `.terminateLater` reply queued on the main
    /// dispatch queue, which AppKit doesn't drain there (sample, Oct 12 2026).
    func testTermination_repliesThroughTheRunLoop() throws {
        let app = try readSource("Meridian/App/AppDelegate.swift")
        guard let start = app.range(of: "func applicationShouldTerminate(_ sender: NSApplication)"),
              let end = app.range(of: "return .terminateLater", range: start.upperBound..<app.endIndex)
        else { return XCTFail("applicationShouldTerminate must reply later") }
        let body = app[start.upperBound..<end.lowerBound]
        XCTAssertFalse(body.contains("DispatchQueue.main"),
                       "the reply and its timeout must not wait on the main dispatch queue")
        XCTAssertTrue(body.contains("Self.onMainRunLoop"))
        XCTAssertTrue(body.contains("RunLoop.main.add(timeout, forMode: .common)"))
    }

    /// Reset Meridian deleted the engine and Steam but kept the account, so
    /// the next launch signed straight back in with no setup (user, Oct 12
    /// 2026, meridian.log 20:25:52 reset, 20:27:11 bootstrap, no onboarding).
    func testResetMeridian_signsOutSoSetupStartsAgain() throws {
        let settings = try readSource("Meridian/Views/Settings/SettingsView.swift")
        guard let start = settings.range(of: "Button(\"Reset Everything\", role: .destructive) {"),
              let quit = settings.range(of: "AppDelegate.relaunch()", range: start.upperBound..<settings.endIndex)
        else { return XCTFail("Reset Meridian must exist and restart the app") }
        XCTAssertTrue(settings[start.upperBound..<quit.lowerBound].contains("steamAuth.signOut()"),
                      "Reset must sign out, so the next launch starts setup")
    }
}
