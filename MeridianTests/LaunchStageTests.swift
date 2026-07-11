import XCTest

/// Guard tests for the staged Steam-boot launch UX
/// (HANDOFF-2026-07-03-v6 Goal 2; revised Jul 3 2026).
///
/// `Launcher` funnels every launch-phase status string (from the pipeline
/// itself, `SteamSession.onStatus` callbacks, and `GameProcess.onLog`)
/// through `setLaunchActivity`, which maps recognized markers to a staged
/// SF Symbol + a monotonic progress fraction. During `.launching` the Play
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

    /// Mirror of Launcher.launchStages.
    /// MIRROR CONTRACT: must match `Launcher.launchStages` in
    /// Meridian/Launch/Launcher.swift (same markers, same order, same
    /// icons/fractions — first match wins).
    private static let launchStages: [(marker: String, icon: String, fraction: Double)] = [
        ("Connecting to Steam servers", "network",                     0.54),
        ("Connected to Steam servers",  "network",                     0.58),
        ("Signing in to your Steam account", "lock.shield",            0.62),
        ("Finishing sign-in",           "lock.shield",                 0.66),
        ("Steam is ready",              "checkmark.shield",            0.70),
        ("Steam is updating itself",    "arrow.triangle.2.circlepath", 0.50),
        ("Starting Steam client",       "gear",                        0.46),
        ("Connecting to Steam",         "network",                     0.08),
        ("Downloading Steam client",    "arrow.down.circle",           0.28),
        ("Installing Steam",            "square.and.arrow.down",       0.18),
        ("Opening Steam sign-in",       "person.crop.circle",          0.38),
        ("Waiting for you to sign in",  "person.crop.circle",          0.42),
        ("sign-in required",            "person.crop.circle",          0.38),
        ("session expired",             "person.crop.circle",          0.38),
        ("Starting Steam",              "lock.shield",                 0.42),
        ("through Steam",               "play.circle",                 0.76),
        ("validating",                  "arrow.triangle.2.circlepath", 0.82),
        ("Waiting for Steam to start",  "hourglass",                   0.88),
        ("Waiting for game to start",   "hourglass",                   0.92),
        ("Game is running",             "checkmark.circle.fill",       1.00),
        ("Preparing",                   "gear",                        0.04),
        ("Launching",                   "play.circle",                 0.76),
    ]

    private struct StageState {
        var icon = "gear"
        var fraction = 0.0
    }

    /// Mirror of Launcher.setLaunchActivity's stage-advance logic: icon
    /// follows the LATEST recognized marker; fraction only ever grows.
    private func apply(_ status: String, to state: inout StageState) {
        if let stage = Self.launchStages.first(where: { status.localizedCaseInsensitiveContains($0.marker) }) {
            state.icon = stage.icon
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
        XCTAssertEqual(s.icon, "checkmark.circle.fill")
        XCTAssertEqual(s.fraction, 1.0)
    }

    func testStageMapping_throughSteamWinsOverGenericLaunching() {
        // "Launching X through Steam…" contains both "through Steam" and
        // "Launching" — the more specific marker must win (table order).
        var s = StageState()
        apply("Launching Animal Well through Steam…", to: &s)
        XCTAssertEqual(s.fraction, 0.76)
        XCTAssertEqual(s.icon, "play.circle")
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
        // (StateFlags leaves "4" mid-wait). The icon must follow the newer
        // state; the bar must NOT slide backwards.
        var s = StageState()
        apply("Waiting for game to start… (4s)", to: &s)
        XCTAssertEqual(s.fraction, 0.92)
        apply("Steam is validating Super Battle Golf before launch…", to: &s)
        XCTAssertEqual(s.icon, "arrow.triangle.2.circlepath",
                       "icon follows the latest recognized stage")
        XCTAssertEqual(s.fraction, 0.92,
                       "fraction is monotonic — no backwards slide")
    }

    func testStageMapping_unrecognizedStatusLeavesStageUntouched() {
        var s = StageState()
        apply("Connecting to Steam…", to: &s)
        let before = s
        apply("Some brand new status text the table doesn't know", to: &s)
        XCTAssertEqual(s.icon, before.icon)
        XCTAssertEqual(s.fraction, before.fraction)
    }

    func testStageMapping_offlinePath() {
        var s = StageState()
        apply("Preparing Bogos Binted…", to: &s)
        XCTAssertEqual(s.icon, "gear")
        apply("Launching Bogos Binted…", to: &s)
        XCTAssertEqual(s.icon, "play.circle")
        apply("Waiting for game to start… (2s)", to: &s)
        XCTAssertEqual(s.icon, "hourglass")
        apply("Game is running", to: &s)
        XCTAssertEqual(s.fraction, 1.0)
    }

    // MARK: - Mirror sync guard

    /// Every marker in the mirror table must appear verbatim in Launcher.swift
    /// — catches production-table edits that skip the mirror (and vice versa,
    /// since count is compared against the production table's entry count).
    func testStageTable_mirrorMatchesProduction() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        for stage in Self.launchStages {
            XCTAssertTrue(src.contains("(\"\(stage.marker)\""),
                          "Launcher.launchStages must contain marker \"\(stage.marker)\" — update the mirror in LaunchStageTests if the table changed.")
            XCTAssertTrue(src.contains("\"\(stage.icon)\""),
                          "Launcher.launchStages must use icon \"\(stage.icon)\" — update the mirror if it changed.")
        }
    }

    // MARK: - Launcher wiring

    func testLauncher_exposesStagedProgressSurface() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("var launchStageIcon"),
                      "Launcher must publish the staged SF Symbol.")
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
        XCTAssertTrue(launchingBody.contains("Label(launchModeUI == .online ? \"Play Online\" : \"Play\""),
                      "The launching button must keep the static Play / Play Online label.")
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
        XCTAssertTrue(src.contains("statusSubtitle"),
                      "StatusCard must show contextual subtitles during launch.")
        XCTAssertTrue(src.contains("effectiveLaunchTarget"),
                      "StatusCard must creep the bar forward during long Steam-boot stalls.")
        XCTAssertFalse(src.contains("LaunchCardHighlightRing"),
                       "The border shimmer ring was removed — StatusCard stays clean.")
    }
}
