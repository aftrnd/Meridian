import XCTest
import SwiftUI

/// Tests for the PICS-appinfo logo-hash resolver parser + architectural guards.
///
/// Root cause it addresses (CLI-verified 2026-06-19): Steam's
/// `IStoreBrowseService/GetItems/v1` API never returns the library LOGO hash for
/// any game, and the legacy `/steam/apps/{id}/logo.png` 404s for newer titles —
/// so newer games' title logos fell back to SF-font text. The logo hash lives
/// only in PICS appinfo (`common.library_assets_full.library_logo`), resolved
/// via the DepotDownloader fork's `-appinfo` mode (anonymous, public section).
///
/// The `parse` cases mirror `SteamAppInfoResolver.parse` verbatim (mirror
/// contract). The remaining cases grep production sources so a refactor that
/// drops the appinfo pass or its fork wiring trips during `swift test`.
final class SteamAppInfoResolverTests: XCTestCase {

    // MARK: - Mirror of SteamAppInfoResolver.parse

    struct Placement: Equatable { var pinned: String; var widthPct: Double; var heightPct: Double }
    struct Hashes: Equatable {
        var logo: String?
        var capsule: String?
        var hero: String?
        var logoPlacement: Placement?
    }

    /// Mirror of `SteamAppInfoResolver.parse`. Keep in sync.
    func parse(_ line: String) -> (appID: Int, hashes: Hashes)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "appinfo"
        else { return nil }
        let appID: Int
        if let n = obj["appid"] as? Int { appID = n }
        else if let n = obj["appid"] as? Double { appID = Int(n) }
        else if let s = obj["appid"] as? String, let n = Int(s) { appID = n }
        else { return nil }
        func nonEmpty(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        func double(_ key: String) -> Double {
            if let n = obj[key] as? Double { return n }
            if let n = obj[key] as? Int { return Double(n) }
            if let s = obj[key] as? String, let n = Double(s) { return n }
            return 0
        }
        var placement: Placement?
        let logo = nonEmpty("logo")
        if let pinned = nonEmpty("logoPinned") {
            let w = double("logoWidthPct"), h = double("logoHeightPct")
            if w > 0, h > 0 { placement = Placement(pinned: pinned, widthPct: w, heightPct: h) }
        }
        return (appID, Hashes(logo: logo,
                              capsule: nonEmpty("capsule"),
                              hero: nonEmpty("hero"),
                              logoPlacement: placement))
    }

    // MARK: - Parser cases (real fork output, CLI-captured 2026-06-19)

    func testParsesRealBogosBintedLine() {
        // Real fork output, CLI-captured 2026-06-19 (includes logo_position).
        let line = #"{"type":"appinfo","appid":3588490,"logo":"4037b4ea74455653c6c369d098fbb26dd54c988b","capsule":"0827d5a40c79f400028469d25b8696dc1da7493a","hero":"b1f7f916bc9544220092b213ab02f4948d076e54","logoPinned":"BottomLeft","logoWidthPct":50.794144220416385,"logoHeightPct":50}"#
        let r = parse(line)
        XCTAssertEqual(r?.appID, 3588490)
        XCTAssertEqual(r?.hashes.logo, "4037b4ea74455653c6c369d098fbb26dd54c988b")
        XCTAssertEqual(r?.hashes.capsule, "0827d5a40c79f400028469d25b8696dc1da7493a")
        XCTAssertEqual(r?.hashes.hero, "b1f7f916bc9544220092b213ab02f4948d076e54")
        XCTAssertEqual(r?.hashes.logoPlacement, Placement(pinned: "BottomLeft", widthPct: 50.794144220416385, heightPct: 50))
    }

    func testParsesCenterCenterPlacement() {
        let line = #"{"type":"appinfo","appid":4244510,"logo":"6b0b4b03d09d8d0c8e5369e1623d116f6b23d6a1","capsule":"950ae75b","hero":"ff53ff26","logoPinned":"CenterCenter","logoWidthPct":100,"logoHeightPct":100}"#
        let r = parse(line)
        XCTAssertEqual(r?.hashes.logoPlacement, Placement(pinned: "CenterCenter", widthPct: 100, heightPct: 100))
    }

    func testPlacementAppliesToLegacyLogoWithEmptyHash() {
        // Older titles (e.g. Stardew Valley, appID 413150) return an EMPTY logo
        // hash (bare legacy filename) but a valid logo_position. The placement
        // must still apply — to their working legacy-CDN logo on the detail page.
        // CLI-captured 2026-06-19.
        let line = #"{"type":"appinfo","appid":413150,"logo":"","capsule":"","hero":"","logoPinned":"BottomCenter","logoWidthPct":77.24037339556588,"logoHeightPct":94.6805984326763}"#
        let r = parse(line)
        XCTAssertNil(r?.hashes.logo, "legacy bare-filename logo must map to nil hash so the legacy fallback is used")
        XCTAssertEqual(r?.hashes.logoPlacement,
                       Placement(pinned: "BottomCenter", widthPct: 77.24037339556588, heightPct: 94.6805984326763),
                       "placement must apply even when the new-CDN logo hash is empty")
    }

    func testPlacementNilWithoutPinnedPosition() {
        // No pinned position → no placement (e.g. games with no library logo at all).
        let line = #"{"type":"appinfo","appid":1,"logo":"","capsule":"","hero":"","logoPinned":"","logoWidthPct":0,"logoHeightPct":0}"#
        XCTAssertNil(parse(line)?.hashes.logoPlacement)
    }

    func testEmptyAssetBecomesNil() {
        let line = #"{"type":"appinfo","appid":730,"logo":"","capsule":"6328493f","hero":""}"#
        let r = parse(line)
        XCTAssertEqual(r?.appID, 730)
        XCTAssertNil(r?.hashes.logo, "empty string must map to nil so the caller keeps the legacy fallback")
        XCTAssertEqual(r?.hashes.capsule, "6328493f")
        XCTAssertNil(r?.hashes.hero)
    }

    func testIgnoresHumanStatusLines() {
        XCTAssertNil(parse("Logging anonymously into Steam3... Done!"))
        XCTAssertNil(parse("Got AppInfo for 3588490"))
        XCTAssertNil(parse(""))
        // Other NDJSON event types are not appinfo.
        XCTAssertNil(parse(#"{"type":"phase","phase":"loggedon","detail":""}"#))
    }

    // MARK: - Production wiring guards

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private func readSource(_ p: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: p), encoding: .utf8)
    }

    func testResolverInvokesForkAppInfoMode() throws {
        let src = try readSource("Meridian/Steam/SteamAppInfoResolver.swift")
        XCTAssertTrue(src.contains(#""-appinfo""#),
                      "resolver must invoke the fork's -appinfo mode")
        XCTAssertTrue(src.contains("tools/depotdownloader/DepotDownloader"),
                      "resolver must locate the DepotDownloader fork binary")
    }

    func testLibraryStoreRunsAppInfoLogoPass() throws {
        let src = try readSource("Meridian/Steam/SteamLibraryStore.swift")
        XCTAssertTrue(src.contains("SteamAppInfoResolver.resolve"),
                      "prefetchLibraryCapsuleHashes must run the appinfo logo-hash pass (Pass 3)")
        XCTAssertTrue(src.contains("func needsAppinfo"),
                      "the appinfo pass must target only games still missing a logo hash/placement after GetItems + librarycache")
        XCTAssertTrue(src.contains("recentNeeding"),
                      "the appinfo pass must resolve recent/visible games first for fast first-run paint")
    }

    /// The slow PICS-appinfo pass must be cached to disk so logos + positions
    /// apply instantly on later launches (no 1–2 min re-resolve every time).
    func testLibraryStorePersistsAndAppliesArtCache() throws {
        let src = try readSource("Meridian/Steam/SteamLibraryStore.swift")
        XCTAssertTrue(src.contains("library-art-cache.json"),
                      "resolved art hashes + placement must persist to a disk cache")
        XCTAssertTrue(src.contains("func applyArtCache"),
                      "the cache must be applied on launch so logos are positioned on the first frame")
        XCTAssertTrue(src.contains("func persistArtCache"),
                      "resolved art must be written back to the cache after the network passes")
        XCTAssertTrue(src.contains("appinfoResolved"),
                      "resolved apps (incl. legacy titles with no new-CDN logo) must not be re-queried every launch")
        XCTAssertTrue(src.contains("applyArtCache()"),
                      "refresh() must apply the cached art before the network passes run")
    }

    // MARK: - Logo placement (game detail only)

    /// Mirror of `HeroLogoLoader.alignment(for:)`. Keep in sync.
    func alignment(for pinned: String) -> Alignment {
        switch pinned {
        case "BottomLeft":    return .bottomLeading
        case "BottomCenter":  return .bottom
        case "BottomRight":   return .bottomTrailing
        case "CenterLeft":    return .leading
        case "CenterCenter":  return .center
        case "CenterRight":   return .trailing
        case "UpperLeft", "TopLeft":     return .topLeading
        case "UpperCenter", "TopCenter": return .top
        case "UpperRight", "TopRight":   return .topTrailing
        default:              return .bottomLeading
        }
    }

    func testPinnedPositionAlignmentMapping() {
        XCTAssertEqual(alignment(for: "BottomLeft"), .bottomLeading)
        XCTAssertEqual(alignment(for: "CenterCenter"), .center)
        XCTAssertEqual(alignment(for: "UpperLeft"), .topLeading)
        XCTAssertEqual(alignment(for: "BottomCenter"), .bottom)
        // Steam's default when unspecified/unknown is bottom-left.
        XCTAssertEqual(alignment(for: "Whatever"), .bottomLeading)
    }

    func testGameDetailUsesPositionedLogoOnly() throws {
        let detail = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(detail.contains("HeroLogoPositioned") && detail.contains("effectiveLogoPlacement"),
                      "GameDetailView must render HeroLogoPositioned when effectiveLogoPlacement is set")
        // Home must NOT use the positioned logo — the carousel keeps its fixed layout.
        let home = try readSource("Meridian/Views/HomeView.swift")
        XCTAssertFalse(home.contains("HeroLogoPositioned"),
                       "Home carousel must stay unchanged — no positioned logo")
    }

    func testHeroArtViewsDefinesPositionedLogo() throws {
        let src = try readSource("Meridian/Views/Library/HeroArtViews.swift")
        XCTAssertTrue(src.contains("struct HeroLogoPositioned"),
                      "HeroArtViews must define HeroLogoPositioned")
        XCTAssertTrue(src.contains("enum HeroLogoLoader") && src.contains("func alignment(for"),
                      "HeroArtViews must define the shared HeroLogoLoader + pinned→alignment mapping")
    }
}
