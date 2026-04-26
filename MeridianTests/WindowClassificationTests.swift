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
        let src = try productionSource()
        XCTAssertTrue(src.contains("private static let pollingInterval: TimeInterval = 0.2"))
        XCTAssertTrue(src.contains("private static let burstSuppressDuration: TimeInterval = 20.0"))
        XCTAssertTrue(src.contains("Timer(timeInterval: Self.pollingInterval"))
    }

    func testSuppressNowSweepsLiveWinePIDsAndArmsBurst() throws {
        let src = try productionSource()
        guard let fn = src.range(of: "func suppressNow(") else {
            return XCTFail("SteamWindowSuppressor must expose suppressNow()")
        }
        let body = src[fn.lowerBound...]
        XCTAssertTrue(body.contains("hideAllKnownWineWindows()"))
        XCTAssertTrue(body.contains("reason: String = \"manual suppressNow\""))
        XCTAssertTrue(body.contains("startSuppressionBurst(reason: reason, duration: duration)"))
    }

    func testRegisterPIDArmsBurstSuppression() throws {
        let src = try productionSource()
        guard let fn = src.range(of: "func registerPID(_ pid: pid_t)") else {
            return XCTFail("SteamWindowSuppressor must expose registerPID(_:)")
        }
        let body = src[fn.lowerBound...]
        XCTAssertTrue(body.contains("startSuppressionBurst(reason: \"registered pid=\\(pid)\")"))
    }

    func testBurstSuppressionUsesLiveWineSweep() throws {
        let src = try productionSource()
        XCTAssertTrue(src.contains("private func hideAllKnownWineWindows()"))
        XCTAssertTrue(src.contains("let livePIDs = currentWinePIDs()"))
        XCTAssertTrue(src.contains("if suppressionActive, isBurstSuppressionActive"))
    }

    func testInstallPathArmsSuppressionBeforeSteamRestart() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Engine/WineSteamManager.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("windowSuppressor?.suppressNow(reason: \"installGame preseed appID=\\(appID)\")"))
        XCTAssertTrue(src.contains("startHeadlessWebhelperKillBurst(reason: \"installGame start appID=\\(appID)\", duration: .seconds(20))"))
        XCTAssertTrue(src.contains("windowSuppressor?.suppressNow(reason: \"installGame restart appID=\\(appID)\")"))
        XCTAssertTrue(src.contains("windowSuppressor?.suppressNow(reason: \"installGame post-start appID=\\(appID)\")"))
        XCTAssertTrue(src.contains("startHeadlessWebhelperKillBurst(reason: \"installGame ready appID=\\(appID)\", duration: .seconds(12))"))
        XCTAssertTrue(src.contains("self.windowSuppressor?.registerPID(shutdownProcess.processIdentifier)"))
    }

    func testGameLauncherSuppressesAtDownloadClick() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Launch/GameLauncher.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("windowSuppressor?.suppressNow(reason: \"download click appID=\\(game.id)\")"))
        XCTAssertTrue(src.contains("steamManager.startHeadlessWebhelperKillBurst(reason: \"download click appID=\\(game.id)\", duration: .seconds(20))"))
        XCTAssertTrue(src.contains("WineSteamManager.killWebhelper(reason: \"download complete chime\")"))
        XCTAssertFalse(src.contains("silenceSteamChime"))
    }

    func testBootstrapKillsWebhelperAfterReady() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/App/BootstrapManager.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("steamManager.startHeadlessWebhelperKillBurst(reason: \"bootstrap ready\", duration: .seconds(12))"))
    }

    func testWineSteamManagerExposesHeadlessWebhelperKillBurst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Engine/WineSteamManager.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("func startHeadlessWebhelperKillBurst(reason: String, duration: Duration = .seconds(8))"))
        XCTAssertTrue(src.contains("Self.killWebhelper(reason: reason)"))
        XCTAssertTrue(src.contains("static func killWebhelper(reason: String = \"manual\")"))
    }

    private func productionSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Meridian/Engine/SteamWindowSuppressor.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
