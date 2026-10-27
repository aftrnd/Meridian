import XCTest
@testable import Meridian

/// The status steam.exe signs in with: Steam's friends store saves the
/// player's last choice in localconfig.vdf, and Control Center's Status
/// starts from it.
final class SteamPersonaStateTests: XCTestCase {

    /// Lines as Steam writes them (localconfig.vdf, Oct 27 2026).
    private let config = """
    "UserLocalConfigStore"
    {
    \t"WebStorage"
    \t{
    \t\t"FriendStoreLocalPrefs_66030415"\t\t"{\\"ePersonaState\\":3,\\"strNonFriendsAllowedToMsg\\":\\"\\"}"
    \t\t"FriendStoreLocalPrefs_86752607"\t\t"{\\"ePersonaState\\":7,\\"strNonFriendsAllowedToMsg\\":\\"\\"}"
    \t}
    }

    """

    func testSavedPersonaState_readsTheAccountsEntry() {
        XCTAssertEqual(WinePrefix.savedPersonaState(in: config, accountID: 86752607), 7)
        XCTAssertEqual(WinePrefix.savedPersonaState(in: config, accountID: 66030415), 3)
    }

    func testSavedPersonaState_nilWithoutAnEntry() {
        XCTAssertNil(WinePrefix.savedPersonaState(in: config, accountID: 1))
        XCTAssertNil(WinePrefix.savedPersonaState(in: "", accountID: 86752607))
    }

    func testAccountID_isTheSteamID64LessTheUniverseBase() {
        XCTAssertEqual(WinePrefix.accountID(steamID64: "76561198047018335"), 86752607)
        XCTAssertNil(WinePrefix.accountID(steamID64: ""))
    }

    /// Each case name is its steam://friends/status/<name> route, and its
    /// raw value Valve's EPersonaState (steamui sp.js).
    func testPersonaState_routesAndValues() {
        XCTAssertEqual(SteamSession.PersonaState.allCases.map { "\($0)" }, ["online", "away", "invisible", "offline"])
        XCTAssertEqual(SteamSession.PersonaState.allCases.map(\.rawValue), [1, 3, 7, 0])
    }
}
