import XCTest
@testable import Meridian

/// Guard tests for the staged Steam-boot launch UX
/// (HANDOFF-2026-07-03-v6 Goal 2; revised Jul 3 2026).
///
/// `Launcher` funnels every launch-phase status string (from the pipeline
/// itself, `SteamSession.onStatus` callbacks, and `GameProcess.onLog`)
/// through `setLaunchActivity`, which maps recognized markers to a staged
/// `LaunchPhase` + a monotonic progress fraction. During `.launching` the Play
/// button stays STATIC (user direction Jul 3 2026 — no in-place morphing,
/// no game title in the button); the inline `StatusCard` below it renders
/// the live status + a plain capsule progress bar — the same look as the
/// download flow — driven by `launchStageFraction` and eased from 0 on
/// every mount so a fast Steam boot never pops the bar in at 75%.
final class LaunchStageTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Mirror of Launcher's stage mapping

    /// Mirror of Launcher.launchStages (phases as their case names).
    /// MIRROR CONTRACT: must match `Launcher.launchStages` in
    /// Meridian/Launch/Launcher.swift (same markers, same order, same
    /// phases/fractions; first match wins).
    private static let launchStages: [(marker: String, phase: String, fraction: Double)] = [
        ("Connecting to Steam servers",      "gettingReady",  0.54),
        ("Connected to Steam servers",       "gettingReady",  0.58),
        ("Signing in to your Steam account", "gettingReady",  0.62),
        ("Finishing sign-in",                "gettingReady",  0.66),
        ("Steam is ready",                   "gettingReady",  0.70),
        ("Steam is updating itself",         "updatingSteam",  0.50),
        ("Updating Steam",                   "updatingSteam",  0.50),
        ("Starting Steam client",            "gettingReady",  0.46),
        ("Connecting to Steam",              "gettingReady",  0.08),
        ("Downloading Steam",                "settingUpSteam", 0.28),
        ("Installing Steam",                 "settingUpSteam", 0.18),
        ("Signed in",                        "gettingReady",  0.44),
        ("Starting Steam",                   "gettingReady",  0.42),
        ("through Steam",                    "startingGame",   0.76),
        ("validating",                       "checkingFiles",  0.82),
        ("Waiting for Steam to start",       "startingGame",   0.88),
        ("Waiting for game to start",        "startingGame",    0.92),
        ("Game is running",                  "startingGame",    1.00),
    ]

    private struct StageState {
        var phase = "gettingReady"
        var fraction = 0.0
    }

    /// Mirror of Launcher.setLaunchActivity's stage-advance logic: phase
    /// follows the LATEST recognized marker; fraction only ever grows.
    private func apply(_ status: String, to state: inout StageState) {
        if let stage = Self.launchStages.first(where: { status.localizedCaseInsensitiveContains($0.marker) }) {
            state.phase = stage.phase
            state.fraction = max(state.fraction, stage.fraction)
        }
    }

    // MARK: - Mapping behaviour

    func testStageMapping_onlineHappyPathFillsMonotonically() {
        var s = StageState()
        let statuses = [
            "Connecting to Steam…",
            "Starting Steam…",
            "Starting Steam client…",
            "Connecting to Steam servers…",
            "Connected to Steam servers",
            "Signing in to your Steam account…",
            "Finishing sign-in…",
            "Steam is ready",
            "Launching Super Battle Golf through Steam…",
            "Waiting for Steam to start the game…",
            "Waiting for game to start… (8s)",
            "Game is running",
        ]
        var lastFraction = 0.0
        for status in statuses {
            apply(status, to: &s)
            XCTAssertGreaterThanOrEqual(s.fraction, lastFraction,
                                        "fraction must never regress (status: \(status))")
            lastFraction = s.fraction
        }
        XCTAssertEqual(s.phase, "startingGame")
        XCTAssertEqual(s.fraction, 1.0)
    }

    func testStageMapping_specificMarkerWinsOverItsPrefix() {
        // "Connecting to Steam servers…" also contains "Connecting to Steam";
        // the more specific marker must win (table order).
        var s = StageState()
        apply("Connecting to Steam servers…", to: &s)
        XCTAssertEqual(s.fraction, 0.54)
        apply("Launching Animal Well through Steam…", to: &s)
        XCTAssertEqual(s.phase, "startingGame")
        XCTAssertEqual(s.fraction, 0.76)
    }

    func testStageMapping_steamClientSetupIsRecognized() {
        // SteamSession reports "Downloading Steam" / "Installing Steam"
        // (SteamClientBootstrap); the old "Downloading Steam client"
        // marker never matched, so first-time setup showed no stage.
        var s = StageState()
        apply("Downloading Steam", to: &s)
        XCTAssertEqual(s.phase, "settingUpSteam")
        apply("Updating Steam…", to: &s)
        XCTAssertEqual(s.phase, "updatingSteam")
        apply("Signed in. Finishing up…", to: &s)
        XCTAssertEqual(s.phase, "gettingReady")
    }

    func testStageMapping_steamBootSubStagesAdvance() {
        var s = StageState()
        apply("Starting Steam client…", to: &s)
        XCTAssertEqual(s.fraction, 0.46)
        apply("Connecting to Steam servers…", to: &s)
        XCTAssertGreaterThan(s.fraction, 0.46)
        apply("Connected to Steam servers", to: &s)
        XCTAssertGreaterThan(s.fraction, 0.54)
        apply("Signing in to your Steam account…", to: &s)
        XCTAssertGreaterThan(s.fraction, 0.58)
        apply("Steam is ready", to: &s)
        XCTAssertEqual(s.fraction, 0.70)
    }

    func testStageMapping_validationAfterWaitingKeepsFractionButUpdatesIcon() {
        // Steam can flip to validating AFTER the game-start wait began
        // (StateFlags leaves "4" mid-wait). The phase must follow the newer
        // state; the bar must NOT slide backwards.
        var s = StageState()
        apply("Waiting for game to start… (4s)", to: &s)
        XCTAssertEqual(s.fraction, 0.92)
        apply("Steam is validating Super Battle Golf before launch…", to: &s)
        XCTAssertEqual(s.phase, "checkingFiles",
                       "phase follows the latest recognized stage")
        XCTAssertEqual(s.fraction, 0.92,
                       "fraction is monotonic — no backwards slide")
    }

    func testStageMapping_unrecognizedStatusLeavesStageUntouched() {
        var s = StageState()
        apply("Connecting to Steam…", to: &s)
        let before = s
        apply("Some brand new status text the table doesn't know", to: &s)
        XCTAssertEqual(s.phase, before.phase)
        XCTAssertEqual(s.fraction, before.fraction)
    }

    // MARK: - Mirror sync guard

    /// Every marker in the mirror table must appear verbatim in Launcher.swift
    /// — catches production-table edits that skip the mirror (and vice versa,
    /// since count is compared against the production table's entry count).
    func testStageTable_mirrorMatchesProduction() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        for stage in Self.launchStages {
            XCTAssertTrue(src.contains("(\"\(stage.marker)\","),
                          "Launcher.launchStages must contain marker \"\(stage.marker)\" — update the mirror in LaunchStageTests if the table changed.")
            XCTAssertTrue(src.contains(".\(stage.phase),"),
                          "Launcher.launchStages must use phase .\(stage.phase). Update the mirror if it changed.")
        }
    }

    // MARK: - Launcher wiring

    func testLauncher_exposesStagedProgressSurface() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("var launchPhase"),
                      "Launcher must publish the staged launch phase.")
        XCTAssertTrue(src.contains("var launchStageFraction"),
                      "Launcher must publish the staged progress fraction.")
        XCTAssertTrue(src.contains("func setLaunchActivity("),
                      "Launcher must funnel launch statuses through setLaunchActivity.")
        XCTAssertTrue(src.contains("launchStageFraction = max(launchStageFraction,"),
                      "The fraction must be monotonic (max), never regressing.")
        XCTAssertTrue(src.contains("func resetLaunchStage()"),
                      "Launcher must reset the stage between launch attempts.")
    }

    func testLauncher_routesStatusCallbacksThroughStageMapping() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("self?.setLaunchActivity(status)"),
                      "SteamSession onStatus callbacks must route through setLaunchActivity.")
        XCTAssertTrue(src.contains("self?.setLaunchActivity(msg)"),
                      "GameProcess onLog messages must route through setLaunchActivity.")
        XCTAssertFalse(src.contains("self?.currentActivity = status"),
                       "No launch status callback may bypass the stage mapping.")
    }

    // MARK: - UI wiring

    func testLaunchGlow_isDeleted() throws {
        // The in-place LaunchGlowButton morph was removed (user direction
        // Jul 3 2026: the Play button stays static during launches). Neither
        // the file nor any reference to it may come back.
        let glowPath = repoRoot.appending(path: "Meridian/Views/Library/LaunchGlow.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: glowPath.path),
                       "LaunchGlow.swift was deleted — the Play button no longer morphs during launch.")
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertFalse(src.contains("LaunchGlowButton"),
                       "GameDetailView must not reference the deleted LaunchGlowButton.")
        let pbxproj = try readSource("Meridian.xcodeproj/project.pbxproj")
        XCTAssertFalse(pbxproj.contains("LaunchGlow.swift"),
                       "The Xcode project must not reference the deleted LaunchGlow.swift.")
    }

    func testGameDetail_playButtonStaysStaticAndStatusCardCarriesProgress() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        // The .launching case renders the SAME static label as the idle
        // button (mode-dependent "Play"/"Play Online", never the game name)
        // and is disabled — no morphing loading surface.
        guard let caseStart = src.range(of: "case .launching:"),
              let caseEnd = src.range(of: "case .running:", range: caseStart.upperBound..<src.endIndex) else {
            XCTFail("GameDetailView must branch on .launching before .running in activePlayButton.")
            return
        }
        let launchingBody = String(src[caseStart.upperBound..<caseEnd.lowerBound])
        XCTAssertTrue(launchingBody.contains("Label(\"Play\", systemImage: \"play.fill\")"),
                      "The launching button must keep the static Play label.")
        XCTAssertTrue(launchingBody.contains(".disabled(true)"),
                      "The static launching button must be disabled.")
        XCTAssertFalse(launchingBody.contains("game.name") || launchingBody.contains("currentGame.name"),
                       "The launching button must not carry the game title.")
        // The inline StatusCard shows during EVERY busy phase, including
        // .launching (the `!launcher.isLaunching` suppression is gone).
        XCTAssertFalse(src.contains("isThisGameActive && !launcher.isLaunching"),
                       "The StatusCard must no longer be suppressed during .launching.")
        // StatusCard drives its bar from the staged fraction during launch…
        XCTAssertTrue(src.contains("launcher.launchStageFraction"),
                      "StatusCard must read the staged launch fraction.")
        // …and eases the displayed value from 0 so a fast Steam boot never
        // pops the bar in at 75% (user report Jul 3 2026).
        XCTAssertTrue(src.contains("displayedLaunchFraction"),
                      "StatusCard must ease the displayed fraction from 0 on mount.")
        XCTAssertTrue(src.contains("clamped > displayedLaunchFraction"),
                      "The displayed fraction must be monotonic — never slides backwards.")
        XCTAssertTrue(src.contains("CompatCardRowMetrics"),
                      "StatusCard must share layout metrics with BannerCompatBadge.")
        XCTAssertTrue(src.contains("iconColumnWidth"),
                      "Both cards must use a shared icon column for alignment.")
        XCTAssertTrue(src.contains(".font(.title2.weight(.semibold))"),
                      "StatusCard icons must match the Meridian Verified badge size.")
        // The card names a handful of phases instead of narrating every
        // Steam status (user feedback Oct 11 2026: "Apple would never do
        // that"). No per-status subtitles, no made-up percentage.
        XCTAssertTrue(src.contains("launcher.launchPhase"),
                      "StatusCard must headline the launch phase, not raw status strings.")
        XCTAssertFalse(src.contains("statusSubtitle"),
                       "StatusCard must not narrate a subtitle for every Steam status.")
        XCTAssertFalse(src.contains("no windows will appear"),
                       "StatusCard must not promise that no window appears; Steam's sign-in can.")
        XCTAssertFalse(src.contains("Int((min(max(progress, 0), 1) * 100).rounded())"),
                       "The launch bar is staged, so it must not show a percentage.")
        XCTAssertTrue(src.contains("launcher.steamSignIn"),
                      "StatusCard must say when the launch is waiting on Steam's sign-in.")
        XCTAssertTrue(src.contains("guard launcher.steamSignIn == nil else { return staged }"),
                      "The bar must hold still while the launch waits on the player.")
        XCTAssertTrue(src.contains("effectiveLaunchTarget"),
                      "StatusCard must creep the bar forward during long Steam-boot stalls.")
        XCTAssertFalse(src.contains("LaunchCardHighlightRing"),
                       "The border shimmer ring was removed — StatusCard stays clean.")
    }

    /// The line under "Starting the game…" follows Steam's own launch steps
    /// in console_log.txt. Lines verbatim from the cabin game's launch
    /// (Oct 12 2026 09:31:46-48), plus another app's line that must be ignored.
    func testLaunchSteps_followSteamsConsoleLog() {
        let log = """
        [2026-10-12 09:31:46] ExecCommandLine: ""C:\\Program Files (x86)\\Steam\\steam.exe" -applaunch 4406280"
        [2026-10-12 09:31:46] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to CheckShaderDepotManifest with ""
        [2026-10-12 09:31:46] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to SynchronizingCloud with ""
        [2026-10-12 09:31:46] GameAction [AppID 2684630, ActionID 2] : LaunchApp changed task to UpdatingAppTicket with ""
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to SynchronizingStats with ""
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to CreatingProcess with ""
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to WaitingGameWindow with ""
        """
        let tasks = Launcher.steamLaunchEvents(in: log, appID: 4406280).compactMap { event -> String? in
            if case .task(let task) = event { return task }
            return nil
        }
        XCTAssertEqual(tasks, ["CheckShaderDepotManifest", "SynchronizingCloud", "SynchronizingStats",
                               "CreatingProcess", "WaitingGameWindow"])
        let lines = tasks.compactMap { Launcher.launchStepText(for: $0, gameName: "the cabin game") }
        XCTAssertEqual(lines, ["Syncing your saves", "Loading your achievements", "Opening the cabin game"],
                       "Only steps that mean something to a player get a line, in plain words")
    }

    /// Steam's EULA dialog is titled just "Steam" and was hidden with the rest
    /// of Steam, so the launch waited forever (Super Battle Golf, Oct 12 2026).
    /// Lines verbatim from its console_log.txt and the cabin game's
    /// interstitial, which Steam answers itself in the same second. Steam
    /// writes CRLF; parsing only "\n" missed the wait in the real file.
    func testLaunchSteps_seeSteamWaitingOnThePlayer() {
        let eula = """
        [2026-10-12 14:08:17] GameAction [AppID 4069520, ActionID 1] : LaunchApp changed task to ShowEula with ""
        [2026-10-12 14:08:17] GameAction [AppID 4069520, ActionID 1] : LaunchApp waiting for user response to ShowEula ""

        """.replacingOccurrences(of: "\n", with: "\r\n")
        XCTAssertEqual(Launcher.steamLaunchEvents(in: eula, appID: 4069520),
                       [.task("ShowEula"), .waitingForPlayer("ShowEula")])

        let interstitial = """
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp changed task to ShowInterstitials with ""
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp waiting for user response to ShowInterstitials ""
        [2026-10-12 09:31:48] GameAction [AppID 4406280, ActionID 1] : LaunchApp continues with user response "ShowInterstitials"
        """
        XCTAssertEqual(Launcher.steamLaunchEvents(in: interstitial, appID: 4406280).last, .answered,
                       "A prompt Steam answers itself must not reach the player")

        let src = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Meridian/Launch/Launcher.swift"), encoding: .utf8)
        XCTAssertTrue(src?.contains("ContinuousClock.now - pendingWait.since >= .seconds(1)") == true,
                      "Only a prompt still open after a second is shown")
        XCTAssertTrue(src?.contains("if task == \"Failed\" { steamFailed = true }") == true,
                      "A launch Steam gave up on must end at once, not at the startup timeout")
    }
}
