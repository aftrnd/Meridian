import XCTest

/// Unit tests for the window classification logic in SteamWindowSuppressor.
///
/// The suppressor classifies windows as essential (must be shown), suppressible
/// (Steam chrome that should be hidden), or unknown (also suppressed by default).
/// Meridian owns the Steam-facing UX, so every Steam-rendered window is hidden.
///
/// MIRROR CONTRACT: The pattern lists and classification logic below must match
/// SteamWindowSuppressor.classifyWindow / essentialTitlePatterns / suppressibleTitlePatterns.
final class WindowClassificationTests: XCTestCase {

    // MARK: - Inlined classification logic

    enum WindowClassification {
        case essential
        case suppressible
        case unknown
    }

    /// Mirror of SteamWindowSuppressor.essentialTitlePatterns
    private let essentialTitlePatterns: [String] = [
    ]

    /// Mirror of SteamWindowSuppressor.suppressibleTitlePatterns
    private let suppressibleTitlePatterns: [String] = [
        "steam", "friends", "community", "store", "news", "screenshot",
        "chat", "voice", "broadcast", "music player",
        "download", "install", "update", "complete", "finished",
        "ready to play", "now available", "launch",
        "notification", "alert", "toast",
        "fatal error", "no longer supported",
    ]

    /// Mirror of SteamWindowSuppressor.classifyWindow (title-based logic only)
    private func classifyTitle(_ title: String?) -> WindowClassification {
        guard let title else { return .unknown }
        let lower = title.lowercased()

        for pattern in essentialTitlePatterns {
            if lower.contains(pattern) { return .essential }
        }

        for pattern in suppressibleTitlePatterns {
            if lower.contains(pattern) { return .suppressible }
        }

        return .unknown
    }

    // MARK: - Steam windows are suppressible

    func testNoTitlesAreEssentialByDefault() {
        XCTAssertTrue(essentialTitlePatterns.isEmpty)
    }

    func testSteamMainWindowIsSuppressible() {
        XCTAssertEqual(classifyTitle("Steam"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam Client"), .suppressible)
    }

    func testFriendsIsSuppressible() {
        XCTAssertEqual(classifyTitle("Friends & Chat"), .suppressible)
        XCTAssertEqual(classifyTitle("Friends List"), .suppressible)
    }

    func testCommunityIsSuppressible() {
        XCTAssertEqual(classifyTitle("Steam Community"), .suppressible)
    }

    func testStoreIsSuppressible() {
        XCTAssertEqual(classifyTitle("Steam Store"), .suppressible)
    }

    func testNewsIsSuppressible() {
        XCTAssertEqual(classifyTitle("News"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam News"), .suppressible)
    }

    func testScreenshotIsSuppressible() {
        XCTAssertEqual(classifyTitle("Screenshot Manager"), .suppressible)
    }

    func testChatIsSuppressible() {
        XCTAssertEqual(classifyTitle("Chat with friend"), .suppressible)
    }

    func testInstallAndDownloadWindowsAreSuppressible() {
        XCTAssertEqual(classifyTitle("Install - Counter-Strike 2"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam - Installing Game"), .suppressible)
        XCTAssertEqual(classifyTitle("Downloading update..."), .suppressible)
        XCTAssertEqual(classifyTitle("Download Complete"), .suppressible)
    }

    func testSteamErrorWindowsAreSuppressible() {
        XCTAssertEqual(classifyTitle("Fatal Error"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam - No Longer Supported"), .suppressible)
    }

    // MARK: - Unknown windows

    func testNilTitleIsUnknown() {
        XCTAssertEqual(classifyTitle(nil), .unknown)
    }

    func testEmptyTitleIsUnknown() {
        XCTAssertEqual(classifyTitle(""), .unknown)
    }

    func testRandomTitleIsUnknown() {
        XCTAssertEqual(classifyTitle("Some Random Window"), .unknown)
    }

    func testUnknownStillMeansSuppressedByDefault() {
        XCTAssertEqual(classifyTitle("Who's playing on this PC?"), .unknown)
    }

    // MARK: - Case insensitivity

    func testSuppressiblePatternsAreCaseInsensitive() {
        XCTAssertEqual(classifyTitle("INSTALL"), .suppressible)
        XCTAssertEqual(classifyTitle("Install"), .suppressible)
        XCTAssertEqual(classifyTitle("iNsTaLl"), .suppressible)
        XCTAssertEqual(classifyTitle("FRIENDS"), .suppressible)
        XCTAssertEqual(classifyTitle("Friends"), .suppressible)
        XCTAssertEqual(classifyTitle("COMMUNITY"), .suppressible)
    }

    func testSteamMainWindowCaseInsensitive() {
        XCTAssertEqual(classifyTitle("steam"), .suppressible)
        XCTAssertEqual(classifyTitle("STEAM"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam"), .suppressible)
        XCTAssertEqual(classifyTitle("steam client"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam Client"), .suppressible)
    }

    // MARK: - Suppression aggressiveness guards

    func testSuppressorUsesFastPollingInterval() throws {
        let src = try steamWindowSource()
        // SteamWindow uses 0.25s polling (single timer, no burst).
        XCTAssertTrue(src.contains("withTimeInterval: 0.25"))
        XCTAssertTrue(src.contains("Timer.scheduledTimer(withTimeInterval:"))
    }

    func testSteamWindowExposesCoreAPI() throws {
        let src = try steamWindowSource()
        XCTAssertTrue(src.contains("func startSuppressing()"),
                      "SteamWindow must expose startSuppressing()")
        XCTAssertTrue(src.contains("func stopSuppressing()"),
                      "SteamWindow must expose stopSuppressing()")
        XCTAssertTrue(src.contains("func registerPID(_ pid: pid_t)"),
                      "SteamWindow must expose registerPID for immediate suppression of new Wine PIDs")
        XCTAssertTrue(src.contains("func pauseForGame()"),
                      "SteamWindow must expose pauseForGame() to allow game windows to appear")
        XCTAssertTrue(src.contains("func resumeAfterGame(steamPID:"),
                      "SteamWindow must expose resumeAfterGame() to re-enable suppression")
    }

    func testSteamWindowUsesAXObserverForInstantHide() throws {
        let src = try steamWindowSource()
        XCTAssertTrue(src.contains("AXObserverCreate"),
                      "SteamWindow must use AXObserver for instant window-created notification")
        XCTAssertTrue(src.contains("kAXWindowCreatedNotification"),
                      "SteamWindow must subscribe to kAXWindowCreatedNotification")
        XCTAssertTrue(src.contains("func hideWindows(for pid:"),
                      "SteamWindow must have a hideWindows function")
    }

    func testSteamWindowRegisterPIDHidesImmediately() throws {
        let src = try steamWindowSource()
        guard let fn = src.range(of: "func registerPID(") else {
            return XCTFail("SteamWindow must expose registerPID")
        }
        let body = src[fn.lowerBound...]
        XCTAssertTrue(body.contains("installObserver(for: pid)") && body.contains("hideWindows(for: pid)"),
                      "registerPID must install observer and hide windows immediately")
    }

    func testLauncherPausesWindowsForGame() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Launch/Launcher.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("steamWindow?.pauseForGame()"),
                      "Launcher must pause window suppression before game launch so game window appears")
        XCTAssertTrue(src.contains("steamWindow?.resumeAfterGame("),
                      "Launcher must resume window suppression after game exits")
    }

    func testBootstrapDoesNotKillWebhelperAfterReady() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/App/BootstrapManager.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            src.contains("startHeadlessWebhelperKillBurst(reason: \"bootstrap ready\""),
            "Do not kill steamwebhelper after bootstrap: Steam's game-launch IPC can be clicked immediately after readiness and needs webhelper for LaunchApp interstitial/CreatingProcess flow."
        )
    }

    func testSteamSessionKillsWebhelperAfterAuth() throws {
        let src = try steamSessionSource()
        XCTAssertTrue(src.contains("killWebhelper()"),
                      "SteamSession must kill steamwebhelper after Logged On to prevent UI flash")
    }

    private func productionSource() throws -> String {
        // Legacy alias — now reads SteamWindow since SteamWindowSuppressor was replaced.
        return try steamWindowSource()
    }

    private func steamWindowSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Steam/SteamWindow.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func steamSessionSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Steam/SteamSession.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
