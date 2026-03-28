import XCTest

/// Unit tests for the window classification logic in SteamWindowSuppressor.
///
/// The suppressor classifies windows as essential (must be shown), suppressible
/// (Steam chrome that should be hidden), or unknown (suppressed by default).
/// These tests inline the classification logic to verify that install dialogs,
/// EULAs, login prompts, and progress windows are never hidden.
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
        "install", "uninstall", "update", "updating",
        "eula", "license", "agreement",
        "steam guard", "verification", "confirm", "warning", "error",
        "sign in", "log in", "login", "activate", "redeem",
        "extracting", "validating", "downloading", "preparing", "completing",
        "first-time setup", "setup", "requires restart",
    ]

    /// Mirror of SteamWindowSuppressor.suppressibleTitlePatterns
    private let suppressibleTitlePatterns: [String] = [
        "friends", "community", "store", "news", "screenshot",
        "chat", "voice", "broadcast", "music player",
    ]

    /// Mirror of SteamWindowSuppressor.classifyWindow (title-based logic only)
    private func classifyTitle(_ title: String?) -> WindowClassification {
        guard let title, !title.isEmpty else { return .unknown }
        let lower = title.lowercased()

        for pattern in essentialTitlePatterns {
            if lower.contains(pattern) { return .essential }
        }

        for pattern in suppressibleTitlePatterns {
            if lower.contains(pattern) { return .suppressible }
        }

        if lower == "steam" || lower == "steam client" {
            return .suppressible
        }

        return .unknown
    }

    // MARK: - Essential windows: install flow

    func testInstallDialogIsEssential() {
        XCTAssertEqual(classifyTitle("Install - Counter-Strike 2"), .essential)
        XCTAssertEqual(classifyTitle("Steam - Installing Game"), .essential)
        XCTAssertEqual(classifyTitle("install"), .essential)
    }

    func testUninstallDialogIsEssential() {
        XCTAssertEqual(classifyTitle("Uninstall Game"), .essential)
        XCTAssertEqual(classifyTitle("Steam - Uninstall"), .essential)
    }

    func testUpdateDialogIsEssential() {
        XCTAssertEqual(classifyTitle("Steam Update"), .essential)
        XCTAssertEqual(classifyTitle("Updating Steam..."), .essential)
        XCTAssertEqual(classifyTitle("Update Required"), .essential)
    }

    // MARK: - Essential windows: legal

    func testEULAIsEssential() {
        XCTAssertEqual(classifyTitle("EULA"), .essential)
        XCTAssertEqual(classifyTitle("Steam Subscriber Agreement - EULA"), .essential)
    }

    func testLicenseAgreementIsEssential() {
        XCTAssertEqual(classifyTitle("License Agreement"), .essential)
        XCTAssertEqual(classifyTitle("Software License"), .essential)
    }

    func testAgreementIsEssential() {
        XCTAssertEqual(classifyTitle("User Agreement"), .essential)
    }

    // MARK: - Essential windows: auth

    func testSteamGuardIsEssential() {
        XCTAssertEqual(classifyTitle("Steam Guard"), .essential)
        XCTAssertEqual(classifyTitle("Steam Guard - Mobile Authenticator"), .essential)
    }

    func testLoginIsEssential() {
        XCTAssertEqual(classifyTitle("Sign In"), .essential)
        XCTAssertEqual(classifyTitle("Log In"), .essential)
        XCTAssertEqual(classifyTitle("Steam Login"), .essential)
    }

    func testVerificationIsEssential() {
        XCTAssertEqual(classifyTitle("Verification Required"), .essential)
        XCTAssertEqual(classifyTitle("Email Verification"), .essential)
    }

    // MARK: - Essential windows: progress (new patterns)

    func testExtractingIsEssential() {
        XCTAssertEqual(classifyTitle("Extracting files..."), .essential)
        XCTAssertEqual(classifyTitle("Steam - Extracting"), .essential)
    }

    func testValidatingIsEssential() {
        XCTAssertEqual(classifyTitle("Validating installation..."), .essential)
    }

    func testDownloadingIsEssential() {
        XCTAssertEqual(classifyTitle("Downloading update..."), .essential)
        XCTAssertEqual(classifyTitle("Downloading game files"), .essential)
    }

    func testPreparingIsEssential() {
        XCTAssertEqual(classifyTitle("Preparing to launch..."), .essential)
    }

    func testCompletingIsEssential() {
        XCTAssertEqual(classifyTitle("Completing installation"), .essential)
    }

    func testFirstTimeSetupIsEssential() {
        XCTAssertEqual(classifyTitle("First-Time Setup"), .essential)
    }

    func testSetupIsEssential() {
        XCTAssertEqual(classifyTitle("Game Setup"), .essential)
        XCTAssertEqual(classifyTitle("Setup Wizard"), .essential)
    }

    func testRequiresRestartIsEssential() {
        XCTAssertEqual(classifyTitle("Requires Restart"), .essential)
    }

    // MARK: - Essential windows: misc

    func testWarningIsEssential() {
        XCTAssertEqual(classifyTitle("Warning"), .essential)
        XCTAssertEqual(classifyTitle("Steam Warning"), .essential)
    }

    func testErrorIsEssential() {
        XCTAssertEqual(classifyTitle("Error"), .essential)
        XCTAssertEqual(classifyTitle("Fatal Error"), .essential)
    }

    func testConfirmIsEssential() {
        XCTAssertEqual(classifyTitle("Confirm Delete"), .essential)
        XCTAssertEqual(classifyTitle("Confirmation Required"), .essential)
    }

    func testActivateIsEssential() {
        XCTAssertEqual(classifyTitle("Activate Product"), .essential)
    }

    func testRedeemIsEssential() {
        XCTAssertEqual(classifyTitle("Redeem a Code"), .essential)
    }

    // MARK: - Suppressible windows

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

    // MARK: - Edge cases: essential takes priority

    func testInstallTakesPriorityOverStore() {
        // "Steam Store - Install Game" contains both "store" and "install"
        // Essential patterns are checked first, so "install" wins
        XCTAssertEqual(classifyTitle("Steam Store - Install Game"), .essential)
    }

    func testUpdateTakesPriorityOverNews() {
        XCTAssertEqual(classifyTitle("News - Update Available"), .essential)
    }

    // MARK: - Case insensitivity

    func testEssentialPatternsAreCaseInsensitive() {
        XCTAssertEqual(classifyTitle("INSTALL"), .essential)
        XCTAssertEqual(classifyTitle("Install"), .essential)
        XCTAssertEqual(classifyTitle("iNsTaLl"), .essential)
        XCTAssertEqual(classifyTitle("STEAM GUARD"), .essential)
        XCTAssertEqual(classifyTitle("EULA"), .essential)
    }

    func testSuppressiblePatternsAreCaseInsensitive() {
        XCTAssertEqual(classifyTitle("FRIENDS"), .suppressible)
        XCTAssertEqual(classifyTitle("Friends"), .suppressible)
        XCTAssertEqual(classifyTitle("COMMUNITY"), .suppressible)
    }

    func testSteamMainWindowCaseInsensitive() {
        XCTAssertEqual(classifyTitle("steam"), .suppressible)
        XCTAssertEqual(classifyTitle("STEAM"), .suppressible, "Lowercased to 'steam' matches exact check")
        XCTAssertEqual(classifyTitle("Steam"), .suppressible, "Lowercased to 'steam' matches exact check")
        XCTAssertEqual(classifyTitle("steam client"), .suppressible)
        XCTAssertEqual(classifyTitle("Steam Client"), .suppressible, "Lowercased to 'steam client' matches exact check")
    }
}
