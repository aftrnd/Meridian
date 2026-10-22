import XCTest
@testable import Meridian

/// The Cloud Saves row on a game's page reads Steam's own files: the state
/// Steam last recorded in localconfig.vdf and the uploads in cloud_log.txt
/// (Pattern 69, Oct 22 2026).
final class SteamCloudStatusTests: XCTestCase {

    /// Noita's block, laid out as Steam writes localconfig.vdf (tabs, LF).
    private func localConfig(state: String) -> String {
        """
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
        \t\t\t\t\t"881100"
        \t\t\t\t\t{
        \t\t\t\t\t\t"LastPlayed"\t\t"1792708104"
        \t\t\t\t\t\t"cloud"
        \t\t\t\t\t\t{
        \t\t\t\t\t\t\t"last_sync_state"\t\t"\(state)"
        \t\t\t\t\t\t}
        \t\t\t\t\t\t"autocloud"
        \t\t\t\t\t\t{
        \t\t\t\t\t\t\t"lastlaunch"\t\t"1792708098"
        \t\t\t\t\t\t}
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }

        """
    }

    func testRecorded_readsSteamsLastSyncState() {
        XCTAssertEqual(SteamCloudStatus.recorded(appID: 881100, localConfig: localConfig(state: "synchronized")), .upToDate)
        XCTAssertEqual(SteamCloudStatus.recorded(appID: 881100, localConfig: localConfig(state: "changeslocally")), .waitingToUpload)
        XCTAssertEqual(SteamCloudStatus.recorded(appID: 881100, localConfig: localConfig(state: "changesincloud")), .newerInCloud)
        XCTAssertEqual(SteamCloudStatus.recorded(appID: 881100, localConfig: localConfig(state: "conflictingchanges")), .conflict)
        XCTAssertNil(SteamCloudStatus.recorded(appID: 881100, localConfig: localConfig(state: "notinitialized")),
                     "Nothing recorded yet hides the row")
        XCTAssertNil(SteamCloudStatus.recorded(appID: 240, localConfig: localConfig(state: "synchronized")),
                     "Another game's state isn't this one's")
    }

    /// Lines verbatim from cloud_log.txt (CRLF).
    func testLastTransfer_isTheGamesLatestUploadLine() throws {
        let log = """
        [2026-10-22 18:29:56] [AppID 881100] Upload batch initiated, ID: 4006946588875291739, ChangeNumber: 329, App Build ID: 17130612
        [2026-10-22 18:30:07] [AppID 881100] Delete OK for file Nolla_Games_Noita/save00/world/entities_42020.bin
        [2026-10-22 18:30:08] [AppID 240] Starting sync (eval,)

        """.replacingOccurrences(of: "\n", with: "\r\n")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let expected = try XCTUnwrap(formatter.date(from: "2026-10-22 18:30:07"))

        XCTAssertEqual(SteamCloudStatus.lastTransfer(appID: 881100, in: log), expected)
        XCTAssertNil(SteamCloudStatus.lastTransfer(appID: 240, in: log), "An evaluation isn't an upload")
    }

    func testRead_anUploadUnder30SecondsOldIsShownOverTheRecordedState() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appending(path: "localconfig.vdf")
        let cloudLog = dir.appending(path: "cloud_log.txt")
        try localConfig(state: "synchronized").write(to: config, atomically: true, encoding: .utf8)
        try "[2026-10-22 18:30:07] [AppID 881100] Delete OK for file Nolla_Games_Noita/save00/world/entities_4.bin\r\n"
            .write(to: cloudLog, atomically: true, encoding: .utf8)
        let logged = try XCTUnwrap(SteamCloudStatus.lastTransfer(appID: 881100, in: String(contentsOf: cloudLog, encoding: .utf8)))

        XCTAssertEqual(SteamCloudStatus.read(appID: 881100, localConfig: config, cloudLog: cloudLog,
                                             now: logged.addingTimeInterval(10)), .uploading)
        XCTAssertEqual(SteamCloudStatus.read(appID: 881100, localConfig: config, cloudLog: cloudLog,
                                             now: logged.addingTimeInterval(45)), .upToDate,
                       "An upload that stopped logging is over")
    }
}
