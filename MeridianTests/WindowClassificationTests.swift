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

    // MARK: - A2: actionable-dialog allowlist (surface vs suppress)
    //
    // MIRROR CONTRACT: mirrors SteamWindow.actionableTitlePatterns +
    // SteamWindow.policy(forTitle:). EULA / agreement / purchase / family
    // dialogs are SURFACED (user must act); everything else is SUPPRESSED.

    enum WindowPolicy: Equatable { case suppress, surface }

    /// Mirror of SteamWindow.actionableTitlePatterns.
    private let actionableTitlePatterns: [String] = [
        "end user license", "eula",
        "subscriber agreement", "license agreement", "agreement",
        "terms of service",
        "purchase", "checkout", "confirm your purchase",
        "family sharing", "family view", "parental",
        "enter your", "authorize",
    ]

    /// Mirror of SteamWindow.policy(forTitle:).
    private func policy(forTitle title: String?) -> WindowPolicy {
        guard let title, !title.isEmpty else { return .suppress }
        let lower = title.lowercased()
        for pattern in actionableTitlePatterns where lower.contains(pattern) {
            return .surface
        }
        return .suppress
    }

    func testEULAWindowsAreSurfaced() {
        XCTAssertEqual(policy(forTitle: "End User License Agreement"), .surface)
        XCTAssertEqual(policy(forTitle: "EULA"), .surface)
        XCTAssertEqual(policy(forTitle: "Steam Subscriber Agreement"), .surface,
                       "The subscriber agreement contains 'steam' but must SURFACE, not suppress — the user must accept it.")
        XCTAssertEqual(policy(forTitle: "License Agreement"), .surface)
        XCTAssertEqual(policy(forTitle: "Terms of Service"), .surface)
    }

    func testPurchaseAndFamilyDialogsAreSurfaced() {
        XCTAssertEqual(policy(forTitle: "Confirm Your Purchase"), .surface)
        XCTAssertEqual(policy(forTitle: "Checkout"), .surface)
        XCTAssertEqual(policy(forTitle: "Steam Family Sharing"), .surface)
        XCTAssertEqual(policy(forTitle: "Family View"), .surface)
    }

    func testChromeAndInstallWindowsAreSuppressed() {
        XCTAssertEqual(policy(forTitle: "Steam"), .suppress)
        XCTAssertEqual(policy(forTitle: "Friends & Chat"), .suppress)
        XCTAssertEqual(policy(forTitle: "Install - Counter-Strike 2"), .suppress)
        XCTAssertEqual(policy(forTitle: "Downloading update..."), .suppress)
        XCTAssertEqual(policy(forTitle: "Who's playing on this PC?"), .suppress)
    }

    func testNilOrEmptyTitleIsSuppressed() {
        XCTAssertEqual(policy(forTitle: nil), .suppress,
                       "Transient untitled Steam chrome must be suppressed by default.")
        XCTAssertEqual(policy(forTitle: ""), .suppress)
    }

    func testSteamWindowExposesPolicyAllowlist() throws {
        let src = try steamWindowSource()
        XCTAssertTrue(src.contains("static func policy(forTitle"),
                      "SteamWindow must expose policy(forTitle:) for the actionable-dialog allowlist.")
        XCTAssertTrue(src.contains("actionableTitlePatterns"),
                      "SteamWindow must declare actionableTitlePatterns.")
        XCTAssertTrue(src.contains("actionableDialogTitle"),
                      "SteamWindow must publish actionableDialogTitle so the UI can show the confirmation banner.")
        XCTAssertTrue(src.contains("case surface"),
                      "SteamWindow.WindowPolicy must have a .surface case for user-actionable dialogs.")
        // hideWindows must consult the policy (not blindly hide everything).
        guard let fn = src.range(of: "func hideWindows(for pid:") else {
            return XCTFail("SteamWindow must have hideWindows(for:)")
        }
        let body = src[fn.lowerBound...]
        XCTAssertTrue(body.contains("Self.policy(forTitle:"),
                      "hideWindows must consult policy(forTitle:) so EULA/agreement/purchase dialogs are surfaced.")
    }

    // MARK: - Suppression aggressiveness guards

    func testSuppressorUsesFastPollingInterval() throws {
        let src = try steamWindowSource()
        // SteamWindow uses 0.25s polling (single timer, no burst).
        XCTAssertTrue(src.contains("withTimeInterval: 0.25"))
        XCTAssertTrue(src.contains("Timer.scheduledTimer(withTimeInterval:"))
    }

    /// Told to quit, Steam shows its library with a "Shutdown" popup over it,
    /// which flashed on screen when suppression stopped first (Oct 12 2026).
    func testShutdown_keepsSteamHiddenUntilItHasExited() throws {
        let src = try steamSessionSource()
        guard let start = src.range(of: "func shutdown(engine: WineEngine) async {"),
              let end = src.range(of: "\n    }\n", range: start.upperBound..<src.endIndex)
        else { return XCTFail("SteamSession.shutdown must exist") }
        let body = src[start.upperBound..<end.lowerBound]
        guard let kill = body.range(of: "killAllWineProcesses(engine: engine)"),
              let stop = body.range(of: "steamWindow?.stopSuppressing()")
        else { return XCTFail("shutdown must kill Steam and then stop suppressing") }
        XCTAssertLessThan(kill.lowerBound, stop.lowerBound,
                          "Suppression stops only after Steam has exited")
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
        XCTAssertTrue(src.contains("steamWindow?.enterGameMode()"),
                      "Launcher must switch to game-mode suppression (Steam hidden, game shown) before the game launches")
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

    // MARK: - Sign-in presentation (Pattern 37)

    /// Mirror of SteamWindow.isSignInWindow(title:size:)
    private func isSignInWindow(title: String?, size: CGSize) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return (300...900).contains(size.width) && (200...700).contains(size.height)
    }

    func testSignInWindowMatchedBySizeNotTitle() {
        XCTAssertTrue(isSignInWindow(title: "Sign in to Steam", size: CGSize(width: 700, height: 440)))
        XCTAssertTrue(isSignInWindow(title: "Bei Steam anmelden", size: CGSize(width: 700, height: 440)),
                      "localized sign-in titles must still be presented")
        XCTAssertFalse(isSignInWindow(title: "ANGLE Mock Window", size: CGSize(width: 1, height: 1)))
        XCTAssertFalse(isSignInWindow(title: "", size: CGSize(width: 700, height: 440)))
        XCTAssertFalse(isSignInWindow(title: nil, size: CGSize(width: 700, height: 440)))
        XCTAssertFalse(isSignInWindow(title: "Steam", size: CGSize(width: 1280, height: 800)),
                       "Steam's library window opens right after sign-in and must stay hidden")
    }

    /// Mirror of SteamWindow.isPromptWindow(title:size:)
    private func isPromptWindow(title: String?, size: CGSize) -> Bool {
        guard let title, !title.isEmpty else { return false }
        return size.width >= 300 && size.height >= 200
    }

    /// Steam's EULA dialog is titled just "Steam" (1010×600, CGWindowList,
    /// Oct 12 2026), so the title allowlist hid it. While Steam waits on the
    /// player, any titled dialog-sized Steam window is shown, centred.
    func testSteamPrompt_showsTheUntitledEulaWindow() throws {
        XCTAssertTrue(isPromptWindow(title: "Steam", size: CGSize(width: 1010, height: 600)))
        XCTAssertFalse(isPromptWindow(title: "ANGLE Mock Window", size: CGSize(width: 1, height: 1)))
        XCTAssertFalse(isPromptWindow(title: "", size: CGSize(width: 1010, height: 600)))

        let window = try steamWindowSource()
        XCTAssertTrue(window.contains("return size.width >= 300 && size.height >= 200"),
                      "mirror must match SteamWindow.isPromptWindow")
        XCTAssertTrue(window.contains("present(window, pid: pid, once: &presentedPromptWindows)"),
                      "a surfaced window must be moved back on screen, not only un-minimized (it was left at -32000)")
        let launcher = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Meridian/Launch/Launcher.swift"), encoding: .utf8)
        XCTAssertTrue(launcher.contains("steamWindow?.presentSteamPrompt()"),
                      "Launcher must show Steam's window while Steam waits on the player")
    }

    func testInteractiveSignInPresentsInsteadOfPausingSuppression() throws {
        let window = try steamWindowSource()
        XCTAssertTrue(window.contains("static func isSignInWindow(title: String?, size: CGSize) -> Bool"))
        XCTAssertTrue(window.contains("return (300...900).contains(size.width) && (200...700).contains(size.height)"),
                      "mirror must match SteamWindow.isSignInWindow")
        XCTAssertTrue(window.contains("func beginSignIn()"))
        let session = try steamSessionSource()
        XCTAssertTrue(session.contains("steamWindow?.beginSignIn()"),
                      "signInInteractively must present only Steam's sign-in window, not pause all suppression")
        XCTAssertTrue(session.contains("if interactive { env[\"MERIDIAN_STEAM_SIGNIN\"] = \"1\" }"),
                      "the accessory dylib styles Steam's windows only for the interactive launch")
    }

    // MARK: - Wine process discovery

    /// Mirror of SteamWindow.parseProcArgs.
    private func parseProcArgs(_ buffer: [UInt8]) -> String? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count > header else { return nil }
        let argc = buffer.prefix(header).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = header
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while index < buffer.count, args.count < argc {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args.joined(separator: " ")
    }

    func testProcArgsParsing_returnsWindowsCommandLine() {
        // KERN_PROCARGS2 layout: argc, exec path, NUL padding, argv, then env.
        var buffer = withUnsafeBytes(of: Int32(2).littleEndian) { Array($0) }
        buffer += Array("/private/var/folders/x/winetemp-1/steamwebhelper.exe".utf8) + [0, 0, 0]
        buffer += Array(#"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe"#.utf8) + [0]
        buffer += Array("--no-sandbox".utf8) + [0]
        buffer += Array("WINEPREFIX=/tmp/p".utf8) + [0]
        XCTAssertEqual(parseProcArgs(buffer),
                       #"C:\Program Files (x86)\Steam\bin\cef\cef.win64\steamwebhelper.exe --no-sandbox"#,
                       "argv only: the environment after argc arguments must not be included")
        XCTAssertNil(parseProcArgs([1, 0]))
    }

    /// winemac lists each Wine program under its Windows name with no bundle
    /// identifier; `runningApplications(withBundleIdentifier: "")` matched
    /// none, so Steam's windows were never hidden (Oct 7 2026).
    func testWineProcessDiscovery_doesNotUseEmptyBundleIdentifier() throws {
        let window = try steamWindowSource()
        XCTAssertFalse(window.contains("runningApplications(withBundleIdentifier: \"\")"))
        XCTAssertTrue(window.contains("path.contains(\"/winetemp-\")"))
        XCTAssertTrue(window.contains("Self.commandLine(of: pid)?.lowercased().contains(\"steamwebhelper\")"),
                      "steamwebhelper is identified by its command line; localizedName from outside is not reliable")
    }

    /// Every NSRunningApplication read is LaunchServices XPC, `processIdentifier`
    /// included; walking all running apps per 250 ms tick dropped frames
    /// (Instruments, Oct 11 2026). Wine PIDs come from KVO instead.
    func testWineProcessDiscovery_followsRunningApplicationsByKVO() throws {
        let window = try steamWindowSource()
        XCTAssertTrue(window.contains("NSWorkspace.shared.observe(\\.runningApplications)"))
        guard let tick = window.range(of: "private func pollingTick()"),
              let end = window.range(of: "private func hideAllKnownWine()", range: tick.upperBound..<window.endIndex) else {
            return XCTFail("SteamWindow must have pollingTick() followed by hideAllKnownWine()")
        }
        XCTAssertFalse(window[tick.lowerBound..<end.lowerBound].contains("runningApplications"),
                       "the polling tick must not enumerate running apps")
    }
}
