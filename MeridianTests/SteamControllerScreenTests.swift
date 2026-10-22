import XCTest
@testable import Meridian

/// Steam's "Grab a controller and kick back!" launch screen stays closed:
/// Meridian records it answered "Don't show this on future games" in
/// localconfig.vdf before Steam starts, and the game page shows controller
/// support instead (Pattern 64).
final class SteamControllerScreenTests: XCTestCase {

    private let answer = WinePrefix.controllerRecommendedAnswer

    func testSettingWebStorage_addsTheAnswerAndKeepsEverythingElse() {
        let config = """
        "UserLocalConfigStore"
        {
        \t"Software"
        \t{
        \t}
        \t"WebStorage"
        \t{
        \t\t"CachedNotificationPreferences"\t\t"[{\\"notification_type\\":2}]"
        \t\t"Deck_ConfiguratorInterstitialApps_GamepadRecommended"\t\t"[813230]"
        \t}
        }

        """
        let result = WinePrefix.settingWebStorage(answer, in: config)
        XCTAssertEqual(result, """
        "UserLocalConfigStore"
        {
        \t"Software"
        \t{
        \t}
        \t"WebStorage"
        \t{
        \t\t"CachedNotificationPreferences"\t\t"[{\\"notification_type\\":2}]"
        \t\t"Deck_ConfiguratorInterstitialApps_GamepadRecommended"\t\t"[813230]"
        \t\t"Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended"\t\t"1"
        \t\t"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"\t\t"1"
        \t}
        }

        """, "Only the answer is added; Steam's own list of games is kept")
        XCTAssertEqual(WinePrefix.settingWebStorage(answer, in: result), result, "Writing it again changes nothing")
    }

    func testSettingWebStorage_replacesAnUncheckedBox() {
        let config = "\"UserLocalConfigStore\"\n{\n\t\"WebStorage\"\n\t{\n"
            + "\t\t\"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended\"\t\t\"0\"\n\t}\n}\n"
        let result = WinePrefix.settingWebStorage(answer, in: config)
        XCTAssertTrue(result.contains("\t\t\"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended\"\t\t\"1\""))
        XCTAssertFalse(result.contains("\"0\""))
    }

    func testSettingWebStorage_createsTheBlockSteamHasntWritten() {
        let result = WinePrefix.settingWebStorage(answer, in: "")
        XCTAssertEqual(result, """
        "UserLocalConfigStore"
        {
        \t"WebStorage"
        \t{
        \t\t"Deck_ConfiguratorInterstitialsVersionSeen_GamepadRecommended"\t\t"1"
        \t\t"Deck_ConfiguratorInterstitialsCheckbox_GamepadRecommended"\t\t"1"
        \t\t"Deck_ConfiguratorInterstitialApps_GamepadRecommended"\t\t"[]"
        \t}
        }

        """)
    }

    func testAnswerReachesSteamBeforeItStarts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let session = try String(contentsOf: root.appending(path: "Meridian/Steam/SteamSession.swift"), encoding: .utf8)
        XCTAssertTrue(session.contains("try prefix.hideControllerRecommendedScreen(steamID64: AppSettings.shared.steamCredentialSteamID)"),
                      "Every Steam start records the answer: Steam reads WebStorage only when it starts")
    }
}
