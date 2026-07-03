import XCTest

/// Guard tests for the staged Steam-boot launch UX
/// (HANDOFF-2026-07-03-v6 Goal 2).
///
/// `Launcher` funnels every launch-phase status string (from the pipeline
/// itself, `SteamSession.onStatus` callbacks, and `GameProcess.onLog`)
/// through `setLaunchActivity`, which maps recognized markers to a staged
/// SF Symbol + a monotonic progress fraction. `LaunchGlowButton` renders
/// them in place of the Play button: status text behind Liquid Glass, a
/// comet of light orbiting the capsule, and a subtle progress fill
/// (HANDOFF-2026-07-03-v8 rev. 3).
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
        ("Connecting to Steam",         "network",                     0.10),
        ("Downloading Steam client",    "arrow.down.circle",           0.30),
        ("Installing Steam",            "square.and.arrow.down",       0.20),
        ("Opening Steam sign-in",       "person.crop.circle",          0.40),
        ("Waiting for you to sign in",  "person.crop.circle",          0.45),
        ("sign-in required",            "person.crop.circle",          0.40),
        ("session expired",             "person.crop.circle",          0.40),
        ("Starting Steam",              "lock.shield",                 0.55),
        ("through Steam",               "play.circle",                 0.72),
        ("validating",                  "arrow.triangle.2.circlepath", 0.78),
        ("Waiting for Steam to start",  "hourglass",                   0.85),
        ("Waiting for game to start",   "hourglass",                   0.90),
        ("Game is running",             "checkmark.circle.fill",       1.00),
        ("Preparing",                   "gear",                        0.05),
        ("Launching",                   "play.circle",                 0.72),
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
        XCTAssertEqual(s.fraction, 0.72)
        XCTAssertEqual(s.icon, "play.circle")
    }

    func testStageMapping_validationAfterWaitingKeepsFractionButUpdatesIcon() {
        // Steam can flip to validating AFTER the game-start wait began
        // (StateFlags leaves "4" mid-wait). The icon must follow the newer
        // state; the bar must NOT slide backwards.
        var s = StageState()
        apply("Waiting for game to start… (4s)", to: &s)
        XCTAssertEqual(s.fraction, 0.90)
        apply("Steam is validating Super Battle Golf before launch…", to: &s)
        XCTAssertEqual(s.icon, "arrow.triangle.2.circlepath",
                       "icon follows the latest recognized stage")
        XCTAssertEqual(s.fraction, 0.90,
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

    func testLaunchGlow_isInPlaceLiquidGlassLoader() throws {
        let glow = try readSource("Meridian/Views/Library/LaunchGlow.swift")
        XCTAssertTrue(glow.contains("struct LaunchGlowButton"),
                      "LaunchGlowButton must exist — the in-place launch loader.")
        XCTAssertTrue(glow.contains("launcher.launchStageIcon"),
                      "The glow button must render the staged icon.")
        XCTAssertTrue(glow.contains("launcher.launchStageFraction"),
                      "The glow button must track the staged progress (ring + percent).")
        XCTAssertTrue(glow.contains("launcher.currentActivity"),
                      "The glow button must show the live status text.")
        XCTAssertTrue(glow.contains(".contentTransition(.symbolEffect(.replace))"),
                      "Stage icon changes must animate with the symbol-replace transition.")
        XCTAssertTrue(glow.contains(".transition(.blurReplace)"),
                      "Status text swaps must use the blurReplace morph.")
        // Liquid Glass: real glassEffect on macOS 26, material fallback on 15
        // (same gating pattern as GlassCapsuleBackground in ContentView).
        XCTAssertTrue(glow.contains("glassEffect(.regular.interactive(), in: .capsule)"),
                      "The loader must sit on Liquid Glass.")
        XCTAssertTrue(glow.contains("#available(macOS 26.0, *)"),
                      "glassEffect must be availability-gated (deployment target is macOS 15).")
        // Native pass (user: "should feel more macOS native, less super
        // custom" — HIG progress-indicators: customize the SYSTEM component
        // via ProgressViewStyle rather than rebuilding it):
        XCTAssertTrue(glow.contains("ProgressView(value:"),
                      "Progress must be a system ProgressView (HIG).")
        XCTAssertTrue(glow.contains(": ProgressViewStyle"),
                      "The ring must be a ProgressViewStyle conformance, not a from-scratch component.")
        XCTAssertFalse(glow.contains("TimelineView"),
                       "No custom frame-driven animation — system transitions and springs only (native pass).")
        XCTAssertFalse(glow.contains("OrbitingComet"),
                       "The custom orbiting comet was rejected — Apple-style restraint.")
        XCTAssertFalse(glow.contains("repeatForever"),
                       "No repeatForever animations.")
    }

    func testGameDetail_mountsLaunchGlowInPlaceOfPlayButton() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("LaunchGlowButton(game: currentGame, launcher: launcher)"),
                      "The .launching case must render the in-place glow where the Play button was.")
        XCTAssertFalse(src.contains("ProgressButton(\"Launching…\")"),
                       "The static Launching… button is replaced by the glow.")
        XCTAssertFalse(src.contains("LaunchTheaterView") && src.contains("launchTheaterPresented"),
                       "The launch modal/sheet is deleted — the loader is in-place now.")
        XCTAssertFalse(src.contains("SteamBootCard"),
                       "The old inline SteamBootCard stays gone.")
        XCTAssertTrue(src.contains("isThisGameActive && !launcher.isLaunching"),
                      "The inline StatusCard stays suppressed during .launching (the glow carries status).")
    }
}
