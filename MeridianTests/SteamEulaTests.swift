import XCTest
@testable import Meridian

/// Meridian shows a game's license agreement itself and records the answer
/// where Steam's dialog does, so Steam never opens its library window for it
/// (Pattern 47, CLI-verified Oct 12 2026 with Super Battle Golf).
final class SteamEulaTests: XCTestCase {

    private let url = URL(string: "https://store.steampowered.com//eula/4069520_eula_0")!

    // MARK: - Steam's app info cache

    /// A minimal format-29 appinfo.vdf: header, one app whose key-value tree
    /// lists one agreement, the end marker, then the string table.
    private func appInfo(appID: UInt32, version: Int32) -> Data {
        let keys = ["appinfo", "common", "eulas", "0", "id", "name", "url", "version"]
        func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func key(_ name: String) -> [UInt8] { u32(UInt32(keys.firstIndex(of: name)!)) }
        func string(_ name: String, _ value: String) -> [UInt8] { [0x01] + key(name) + Array(value.utf8) + [0] }

        var tree: [UInt8] = [0x00] + key("appinfo") + [0x00] + key("common") + [0x00] + key("eulas") + [0x00] + key("0")
        tree += string("id", "4069520_eula_0") + string("name", "Super Battle Golf EULA") + string("url", url.absoluteString)
        tree += [0x02] + key("version") + u32(UInt32(bitPattern: version))
        tree += [0x08, 0x08, 0x08, 0x08, 0x08]

        let entry = u32(appID) + u32(UInt32(60 + tree.count)) + [UInt8](repeating: 0, count: 60) + tree
        let body = entry + u32(0)
        let tableOffset = 16 + body.count
        var data = u32(0x0756_4429) + u32(1) + u32(UInt32(tableOffset)) + u32(0) + body
        data += u32(UInt32(keys.count))
        for k in keys { data += Array(k.utf8) + [0] }
        return Data(data)
    }

    func testListed_readsTheGamesAgreementFromSteamsCache() {
        let eulas = SteamEula.listed(appID: 4069520, appInfo: appInfo(appID: 4069520, version: 3))
        XCTAssertEqual(eulas, [SteamEula(appID: 4069520, id: "4069520_eula_0", name: "Super Battle Golf EULA",
                                         url: url, version: 3)])
    }

    func testListed_noAgreementsForOtherGames_unreadableCacheIsNil() {
        XCTAssertEqual(SteamEula.listed(appID: 2291340, appInfo: appInfo(appID: 4069520, version: 3)), [])
        XCTAssertNil(SteamEula.listed(appID: 4069520, appInfo: Data([1, 2, 3, 4])),
                     "A cache Meridian can't read leaves the question to Steam's own dialog")
    }

    // MARK: - localconfig.vdf

    /// Steam's own lines after the player accepted in its window (Oct 12 2026).
    private let accepted = """
    "UserLocalConfigStore"
    {
    \t"Software"
    \t{
    \t\t"Valve"
    \t\t{
    \t\t\t"Steam"
    \t\t\t{
    \t\t\t\t"apps"
    \t\t\t\t{
    \t\t\t\t\t"4069520"
    \t\t\t\t\t{
    \t\t\t\t\t\t"Playtime"\t\t"5072"
    \t\t\t\t\t\t"cloud"
    \t\t\t\t\t\t{
    \t\t\t\t\t\t\t"last_sync_state"\t\t"synchronized"
    \t\t\t\t\t\t}
    \t\t\t\t\t\t"4069520_eula_0"\t\t"3"
    \t\t\t\t\t}
    \t\t\t\t}
    \t\t\t}
    \t\t}
    \t}
    }

    """

    private var eula: SteamEula {
        SteamEula(appID: 4069520, id: "4069520_eula_0", name: "Super Battle Golf EULA", url: url, version: 3)
    }

    func testAcceptedVersions_readsTheGamesBlockOnly() {
        let versions = SteamEula.acceptedVersions(appID: 4069520, localConfig: accepted)
        XCTAssertEqual(versions["4069520_eula_0"], 3)
        XCTAssertNil(versions["last_sync_state"], "Values in nested blocks aren't the game's own")
        XCTAssertEqual(SteamEula.acceptedVersions(appID: 999, localConfig: accepted), [:])
    }

    func testRecording_addsTheAnswerAndKeepsEverythingElse() {
        let declined = accepted.replacingOccurrences(of: "\t\t\t\t\t\t\"4069520_eula_0\"\t\t\"3\"\n", with: "")
        XCTAssertEqual(SteamEula.acceptedVersions(appID: 4069520, localConfig: declined)["4069520_eula_0"], nil)

        let recorded = SteamEula.recording([eula], appID: 4069520, in: declined)
        XCTAssertEqual(recorded, accepted, "Same line Steam writes, in the game's block")
        XCTAssertEqual(SteamEula.recording([eula], appID: 4069520, in: recorded), recorded,
                       "Recording again replaces the line instead of adding another")
    }

    func testRecording_createsTheBlocksSteamHasntWritten() {
        for start in ["", "\"UserLocalConfigStore\"\n{\n\t\"Notifications\"\n\t{\n\t}\n}\n"] {
            let recorded = SteamEula.recording([eula], appID: 4069520, in: start)
            XCTAssertEqual(SteamEula.acceptedVersions(appID: 4069520, localConfig: recorded)["4069520_eula_0"], 3)
        }
        let other = SteamEula(appID: 7, id: "7_eula_0", name: "x", url: url, version: 2)
        let both = SteamEula.recording([other], appID: 7, in: accepted)
        XCTAssertEqual(SteamEula.acceptedVersions(appID: 7, localConfig: both)["7_eula_0"], 2)
        XCTAssertEqual(SteamEula.acceptedVersions(appID: 4069520, localConfig: both)["4069520_eula_0"], 3)
    }

    // MARK: - The agreement's text

    func testBBCode_stylesSteamsTagsAndDropsTheRest() {
        let text = SteamBBCode.attributed("[h2]Terms[/h2]\r\n[list][*]one[*]two[/list][olist][*]a[*]b[/olist][url=https://x.y]site[/url] [spoiler]kept[/spoiler]")
        XCTAssertEqual(String(text.characters), "Terms\n• one\n• two\n1. a\n2. b\nsite kept")
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://x.y")!])
    }

    // MARK: - Steam gets the answer before it starts

    func testAcceptedAgreementsReachSteamBeforeItStarts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let session = try String(contentsOf: root.appending(path: "Meridian/Steam/SteamSession.swift"), encoding: .utf8)
        XCTAssertTrue(session.contains("} else if !pendingEulaAcceptances.isEmpty {"),
                      "A running Steam restarts so it reads the answer")
        XCTAssertTrue(session.contains("try prefix.writeEulaAcceptances(pendingEulaAcceptances,"),
                      "steam.exe's start writes the answers first")
        let launcher = try String(contentsOf: root.appending(path: "Meridian/Launch/Launcher.swift"), encoding: .utf8)
        XCTAssertTrue(launcher.contains("eulaPrompt = EulaPrompt(game: game, eulas: unaccepted)"),
                      "A game with an unaccepted agreement asks in Meridian before Steam launches it")
    }
}
