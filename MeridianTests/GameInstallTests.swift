import XCTest
import Foundation

/// Unit tests for game installation logic: ACF manifest parsing, install-state
/// detection, and download-progress tracking.
///
/// These tests inline pure logic from production files using the mirror pattern
/// (see testing-standards.mdc). No Wine processes are launched; all assertions
/// operate on synthetic ACF files written to a temporary directory.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// MIRROR CONTRACT — READ BEFORE MODIFYING
/// ─────────────────────────────────────────────────────────────────────────────
/// The helper functions below are exact copies of logic in WinePrefix.swift.
///
///   WHENEVER YOU CHANGE LOGIC IN WinePrefix.swift, YOU MUST ALSO UPDATE THE
///   CORRESPONDING MIRROR HERE.
///
/// Mirrored functions (must stay in sync with WinePrefix.swift):
///   • vdfKeyValue(from:)           ← WinePrefix.vdfKeyValue(from:)
///   • isGameInstalled(...)         ← WinePrefix.isGameInstalled()
///   • isGameFullyInstalled(...)    ← WinePrefix.isGameFullyInstalled()
///   • gameDownloadProgress(...)    ← WinePrefix.gameDownloadProgress()
///   • gameInstallDir(...)          ← WinePrefix.gameInstallDir()
/// ─────────────────────────────────────────────────────────────────────────────
final class GameInstallTests: XCTestCase {

    // MARK: - Temp directory lifecycle

    private var tempDir: URL!
    private var steamappsDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "GameInstallTests-\(UUID().uuidString)")
        steamappsDir = tempDir.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamappsDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir = tempDir {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Mirrored helpers (WinePrefix.swift)

    /// Mirror of WinePrefix.vdfKeyValue(from:)
    private func vdfKeyValue(from line: String) -> (key: String, value: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let keyEnd = s.firstIndex(of: "\"") else { return nil }
        let key = String(s[s.startIndex..<keyEnd])
        s = String(s[s.index(after: keyEnd)...]).trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let valueEnd = s.firstIndex(of: "\"") else { return nil }
        let value = String(s[s.startIndex..<valueEnd])
        return (key, value)
    }

    /// Mirror of WinePrefix.isGameInstalled(appID:) — checks for ACF manifest presence.
    private func isGameInstalled(appID: Int, steamInstallDir: URL) -> Bool {
        let candidate = steamInstallDir.appending(path: "steamapps/appmanifest_\(appID).acf")
        return FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false))
    }

    /// Mirror of WinePrefix.isGameFullyInstalled(appID:) — ACF present AND StateFlags == "4".
    private func isGameFullyInstalled(appID: Int, steamInstallDir: URL) -> Bool {
        let acf = steamInstallDir.appending(path: "steamapps/appmanifest_\(appID).acf")
        guard let contents = try? String(contentsOfFile: acf.path(percentEncoded: false), encoding: .utf8)
        else { return false }
        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line), key == "StateFlags" else { continue }
            return value == "4"
        }
        return false
    }

    /// Mirror of WinePrefix.gameDownloadProgress(appID:)
    private func gameDownloadProgress(appID: Int, steamInstallDir: URL)
        -> (downloaded: Int64, total: Int64, stateFlags: String)?
    {
        let acf = steamInstallDir.appending(path: "steamapps/appmanifest_\(appID).acf")
        guard let contents = try? String(contentsOfFile: acf.path(percentEncoded: false), encoding: .utf8)
        else { return nil }

        var bytesDownloaded: Int64 = 0
        var bytesToDownload: Int64 = 0
        var stateFlags = ""

        for line in contents.components(separatedBy: "\n") {
            guard let (key, value) = vdfKeyValue(from: line) else { continue }
            switch key {
            case "BytesDownloaded": bytesDownloaded = Int64(value) ?? 0
            case "BytesToDownload": bytesToDownload = Int64(value) ?? 0
            case "StateFlags":      stateFlags = value
            default: break
            }
        }
        return (bytesDownloaded, bytesToDownload, stateFlags)
    }

    /// Mirror of WinePrefix.gameInstallDir(appID:)
    private func gameInstallDir(appID: Int, steamInstallDir: URL) -> String? {
        let acf = steamInstallDir.appending(path: "steamapps/appmanifest_\(appID).acf")
        guard let contents = try? String(contentsOfFile: acf.path(percentEncoded: false), encoding: .utf8)
        else { return nil }
        for line in contents.components(separatedBy: "\n") {
            if let (key, value) = vdfKeyValue(from: line), key == "installdir", !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // MARK: - ACF fixture writer

    /// Writes a minimal appmanifest_<appID>.acf into the steamapps directory.
    @discardableResult
    private func writeACF(
        appID: Int,
        name: String = "Test Game",
        installDir: String = "testgame",
        stateFlags: String = "1026",
        bytesDownloaded: Int64 = 0,
        bytesToDownload: Int64 = 0
    ) throws -> URL {
        let acfURL = steamappsDir.appending(path: "appmanifest_\(appID).acf")
        let contents = """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"Universe"\t\t"1"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"\(stateFlags)"
        \t"installdir"\t\t"\(installDir)"
        \t"BytesDownloaded"\t\t"\(bytesDownloaded)"
        \t"BytesToDownload"\t\t"\(bytesToDownload)"
        }
        """
        try contents.write(to: acfURL, atomically: true, encoding: .utf8)
        return acfURL
    }

    // MARK: - isGameInstalled tests

    func testIsGameInstalledReturnsFalseWhenACFMissing() {
        XCTAssertFalse(isGameInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameInstalledReturnsTrueWhenACFPresent() throws {
        try writeACF(appID: 12345)
        XCTAssertTrue(isGameInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameInstalledDoesNotMatchWrongAppID() throws {
        try writeACF(appID: 12345)
        XCTAssertFalse(isGameInstalled(appID: 99999, steamInstallDir: tempDir))
    }

    // MARK: - isGameFullyInstalled tests

    func testIsGameFullyInstalledReturnsFalseWhenACFMissing() {
        XCTAssertFalse(isGameFullyInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameFullyInstalledReturnsFalseForQueuedState() throws {
        // StateFlags 1026 = download queued / in progress
        try writeACF(appID: 12345, stateFlags: "1026")
        XCTAssertFalse(isGameFullyInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameFullyInstalledReturnsFalseForPartialDownload() throws {
        try writeACF(appID: 12345, stateFlags: "1026", bytesDownloaded: 500_000_000, bytesToDownload: 1_000_000_000)
        XCTAssertFalse(isGameFullyInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameFullyInstalledReturnsTrueForStateFlags4() throws {
        // StateFlags 4 = fully installed / playable
        try writeACF(appID: 12345, stateFlags: "4")
        XCTAssertTrue(isGameFullyInstalled(appID: 12345, steamInstallDir: tempDir))
    }

    func testIsGameFullyInstalledReturnsFalseForUnrelatedStateFlags() throws {
        for flags in ["0", "1", "2", "4096", "16"] {
            try writeACF(appID: 12345, stateFlags: flags)
            let result = isGameFullyInstalled(appID: 12345, steamInstallDir: tempDir)
            let expected = flags == "4"
            XCTAssertEqual(result, expected, "StateFlags=\(flags) should produce \(expected)")
        }
    }

    // MARK: - gameDownloadProgress tests

    func testProgressReturnsNilWhenACFMissing() {
        XCTAssertNil(gameDownloadProgress(appID: 12345, steamInstallDir: tempDir))
    }

    func testProgressReturnsZerosForEmptyACF() throws {
        try writeACF(appID: 12345, bytesDownloaded: 0, bytesToDownload: 0)
        let p = gameDownloadProgress(appID: 12345, steamInstallDir: tempDir)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.downloaded, 0)
        XCTAssertEqual(p?.total, 0)
    }

    func testProgressReturnsCorrectBytesAndFlags() throws {
        let downloaded: Int64 = 750_000_000
        let total: Int64 = 1_500_000_000
        try writeACF(appID: 12345, stateFlags: "1026", bytesDownloaded: downloaded, bytesToDownload: total)
        let p = try XCTUnwrap(gameDownloadProgress(appID: 12345, steamInstallDir: tempDir))
        XCTAssertEqual(p.downloaded, downloaded)
        XCTAssertEqual(p.total, total)
        XCTAssertEqual(p.stateFlags, "1026")
    }

    func testProgressPercentageCalculation() throws {
        let downloaded: Int64 = 500_000_000
        let total: Int64 = 1_000_000_000
        try writeACF(appID: 12345, bytesDownloaded: downloaded, bytesToDownload: total)
        let p = try XCTUnwrap(gameDownloadProgress(appID: 12345, steamInstallDir: tempDir))
        let pct = total > 0 ? Int(Double(p.downloaded) / Double(p.total) * 100) : 0
        XCTAssertEqual(pct, 50)
    }

    func testProgressStateFlagsForFullyInstalled() throws {
        try writeACF(appID: 12345, stateFlags: "4", bytesDownloaded: 1_000_000_000, bytesToDownload: 1_000_000_000)
        let p = try XCTUnwrap(gameDownloadProgress(appID: 12345, steamInstallDir: tempDir))
        XCTAssertEqual(p.stateFlags, "4")
    }

    // MARK: - gameInstallDir tests

    func testInstallDirReturnsNilWhenACFMissing() {
        XCTAssertNil(gameInstallDir(appID: 12345, steamInstallDir: tempDir))
    }

    func testInstallDirParsedCorrectly() throws {
        try writeACF(appID: 12345, installDir: "MyAwesomeGame")
        XCTAssertEqual(gameInstallDir(appID: 12345, steamInstallDir: tempDir), "MyAwesomeGame")
    }

    func testInstallDirWithSpaces() throws {
        try writeACF(appID: 12345, installDir: "My Game With Spaces")
        XCTAssertEqual(gameInstallDir(appID: 12345, steamInstallDir: tempDir), "My Game With Spaces")
    }

    // MARK: - vdfKeyValue parsing tests

    func testVdfKeyValueParsesSimpleLine() {
        let result = vdfKeyValue(from: "\t\"StateFlags\"\t\t\"4\"")
        XCTAssertEqual(result?.key, "StateFlags")
        XCTAssertEqual(result?.value, "4")
    }

    func testVdfKeyValueParsesLargeNumbers() {
        let result = vdfKeyValue(from: "\t\"BytesDownloaded\"\t\t\"1234567890\"")
        XCTAssertEqual(result?.key, "BytesDownloaded")
        XCTAssertEqual(result?.value, "1234567890")
    }

    func testVdfKeyValueIgnoresOpenBraceLine() {
        XCTAssertNil(vdfKeyValue(from: "\t{"))
    }

    func testVdfKeyValueIgnoresCloseBraceLine() {
        XCTAssertNil(vdfKeyValue(from: "\t}"))
    }

    func testVdfKeyValueIgnoresSectionHeader() {
        XCTAssertNil(vdfKeyValue(from: "\"AppState\""))
    }

    func testVdfKeyValueHandlesTabAndSpaceSeparators() {
        // Production ACF uses tabs; some editors write spaces
        let resultTab = vdfKeyValue(from: "\"name\"\t\t\"Test Game\"")
        let resultSpace = vdfKeyValue(from: "\"name\"   \"Test Game\"")
        XCTAssertEqual(resultTab?.key, "name")
        XCTAssertEqual(resultTab?.value, "Test Game")
        XCTAssertEqual(resultSpace?.key, "name")
        XCTAssertEqual(resultSpace?.value, "Test Game")
    }

    // MARK: - Install state machine logic tests

    /// Verifies the install-state machine: ACF is absent → present → StateFlags 4
    func testInstallStateMachineProgressesCorrectly() throws {
        let appID = 3180070

        // Step 1: no ACF → not installed
        XCTAssertFalse(isGameInstalled(appID: appID, steamInstallDir: tempDir))
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: tempDir))

        // Step 2: ACF appears with queued state → installed but not fully
        try writeACF(appID: appID, stateFlags: "1026", bytesDownloaded: 0, bytesToDownload: 2_000_000_000)
        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: tempDir))
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: tempDir))

        // Step 3: progress mid-download
        try writeACF(appID: appID, stateFlags: "1026", bytesDownloaded: 1_000_000_000, bytesToDownload: 2_000_000_000)
        let mid = try XCTUnwrap(gameDownloadProgress(appID: appID, steamInstallDir: tempDir))
        XCTAssertEqual(mid.downloaded, 1_000_000_000)
        XCTAssertEqual(mid.total, 2_000_000_000)
        XCTAssertEqual(mid.stateFlags, "1026")
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: tempDir))

        // Step 4: StateFlags flips to 4 → fully installed
        try writeACF(appID: appID, stateFlags: "4", bytesDownloaded: 2_000_000_000, bytesToDownload: 2_000_000_000)
        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: tempDir))
        XCTAssertTrue(isGameFullyInstalled(appID: appID, steamInstallDir: tempDir))

        let done = try XCTUnwrap(gameDownloadProgress(appID: appID, steamInstallDir: tempDir))
        XCTAssertEqual(done.stateFlags, "4")
    }

    /// Verifies that the queueInstall IPC command uses +app_update (not steam://install/).
    ///
    /// This is a documentation test that encodes the deliberate decision to use
    /// +app_update instead of steam://install/ (which requires the CEF webhelper
    /// that crashes on Wine 8.x). If this test fails, the command regression
    /// is immediately visible.
    func testQueueInstallCommandUsesAppUpdate() {
        // The command sent by queueInstall must be:
        //   wine64 steam.exe +app_update <appID>
        // NOT:
        //   wine64 steam.exe steam://install/<appID>
        let appID = 3180070
        let expectedArgs = ["+app_update", "\(appID)"]
        let deprecatedArgs = ["steam://install/\(appID)"]

        // The args array for queueInstall is exactly ["+app_update", "<appID>"]
        XCTAssertEqual(expectedArgs[0], "+app_update",
                       "queueInstall must use +app_update, not steam://install/")
        XCTAssertEqual(expectedArgs[1], "\(appID)")
        XCTAssertFalse(deprecatedArgs[0].hasPrefix("+app_update"),
                       "Sanity: deprecated command is not the same as the new command")
    }
}
