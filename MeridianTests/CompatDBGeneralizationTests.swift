import XCTest

/// Guard tests for Phase B6 — Unreal profile factory + DB file wiring and the
/// data-driven performance ranking.
final class CompatDBGeneralizationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testUnrealProfilesFile_existsAndIsWired() throws {
        let dbFile = try readSource("Meridian/Engine/GameCompatibilityDB+Unreal.swift")
        XCTAssertTrue(dbFile.contains("static let unrealProfiles: [GameProfile]"),
                      "GameCompatibilityDB+Unreal.swift must declare unrealProfiles.")

        let db = try readSource("Meridian/Engine/GameCompatibilityDB.swift")
        XCTAssertTrue(db.contains("unrealProfiles"),
                      "allProfiles must include unrealProfiles so Unreal entries are loaded.")
    }

    func testUnrealFactoryExists() throws {
        let profile = try readSource("Meridian/Engine/GameProfile.swift")
        XCTAssertTrue(profile.contains("static func unreal("),
                      "GameProfile must expose the .unreal() engine-level factory.")
    }

    // MARK: - Performance ranking (mirror of GameCompatibilityDB.performanceScore)

    private func statusWeight(_ status: String) -> Double {
        switch status {
        case "verified": return 400
        case "playable": return 300
        case "launches": return 200
        case "untested": return 100
        case "broken":   return 0
        default:         return 100
        }
    }

    private func score(status: String, fps: Double?) -> Double {
        statusWeight(status) + min(fps ?? 0, 99)
    }

    func testPerformanceScore_statusDominatesFPS() {
        // A verified game with 0 fps must still outrank a broken game at 99 fps.
        XCTAssertGreaterThan(score(status: "verified", fps: 0),
                             score(status: "broken", fps: 99),
                             "Status band must dominate — a smooth-but-broken game can't outrank a verified one.")
    }

    func testPerformanceScore_fpsBreaksTiesWithinBand() {
        XCTAssertGreaterThan(score(status: "verified", fps: 90),
                             score(status: "verified", fps: 30),
                             "Within the same status band, higher measured FPS ranks higher.")
    }

    func testPerformanceScore_fpsClampedToBand() {
        // A huge FPS must not let a lower-status game jump a band.
        XCTAssertGreaterThan(score(status: "playable", fps: 0),
                             score(status: "launches", fps: 500),
                             "FPS is clamped so it can never promote a game across a status band.")
    }

    func testGameCompatibilityDB_exposesRankingAPI() throws {
        let db = try readSource("Meridian/Engine/GameCompatibilityDB.swift")
        XCTAssertTrue(db.contains("func performanceScore("),
                      "GameCompatibilityDB must expose performanceScore for data-driven ranking.")
        XCTAssertTrue(db.contains("func rankedByPerformance("),
                      "GameCompatibilityDB must expose rankedByPerformance to sort a library best-first.")
    }
}
