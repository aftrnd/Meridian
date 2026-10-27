import XCTest

/// Regression guard for a game page showing the wrong, low-res banner.
///
/// THE BUG (Oct 2026): Big Walk (1478500) opened with Steam's 460×215 store
/// header instead of its 1920×620 library hero. The Friends panel loads
/// `cdn.cloudflare…/header.jpg` for a friend's game, and that URL is also
/// the hero chain's last fallback. GameDetailView's init preloads the first
/// hero candidate found in the MEMORY tier, so the header (in memory) beat
/// the real hero (on disk only), and `loadBannerImage` returned early on
/// any preload, so it stuck.
///
/// THE FIX: `loadBannerImage` always walks the candidates in priority order
/// through memory and disk; the preload stands only if it's the best hit.
///
/// This test file source-greps GameDetailView so the early return on a
/// preload doesn't come back.
final class GameDetailBannerTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testGamePage_bannerPreloadYieldsToABetterCachedHero() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        guard let start = src.range(of: "private func loadBannerImage() async {"),
              let end = src.range(of: "bannerImageFailed = true", range: start.upperBound..<src.endIndex)
        else { return XCTFail("loadBannerImage not found") }
        let body = String(src[start.upperBound..<end.lowerBound])

        XCTAssertFalse(body.contains("if let img = bannerImage {"),
                       "a memory-tier preload must not skip the ordered cache scan")
        XCTAssertTrue(body.contains("let isPreload = cached === bannerImage"),
                      "the scan replaces the preload when a higher-priority URL is cached")
    }
}
