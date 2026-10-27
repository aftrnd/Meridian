import XCTest
@testable import Meridian

/// Regression guard for achievements showing the gold-trophy placeholder.
///
/// THE BUG (Oct 2026): GetSchemaForGame returns icon URLs on the legacy
/// community CDN (steamcdn-a…/steamcommunity/public/images/apps/), which
/// 404s for newer games (Moon Sweepers, Machine Party, Big Dig), so their
/// icons never loaded.
///
/// THE FIX: `SteamAPIService.achievementIconURL` keeps the schema's file
/// name and serves it from community_assets, where Steam's own achievements
/// pages load it for every game.
final class AchievementIconURLTests: XCTestCase {

    func testSchemaIcon_isServedFromCommunityAssets() {
        let schema = "https://steamcdn-a.akamaihd.net/steamcommunity/public/images/apps/5335510/2cc52cf1d9d19186e554bfc69713d30f951221d6.jpg"
        XCTAssertEqual(
            SteamAPIService.achievementIconURL(schema, appID: 5335510)?.absoluteString,
            "https://shared.fastly.steamstatic.com/community_assets/images/apps/5335510/2cc52cf1d9d19186e554bfc69713d30f951221d6.jpg"
        )
    }

    func testMissingSchemaIcon_hasNoURL() {
        XCTAssertNil(SteamAPIService.achievementIconURL(nil, appID: 5335510))
        XCTAssertNil(SteamAPIService.achievementIconURL("", appID: 5335510))
    }
}
