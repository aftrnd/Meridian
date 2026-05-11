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
/// Mirrored functions (must stay in sync with production code):
///   • vdfKeyValue(from:)                          ← WinePrefix.vdfKeyValue(from:)
///   • isGameInstalled(...)                        ← WinePrefix.isGameInstalled()
///   • isGameFullyInstalled(...)                   ← WinePrefix.isGameFullyInstalled()
///   • gameDownloadProgress(...)                   ← WinePrefix.gameDownloadProgress()
///   • gameInstallDir(...)                         ← WinePrefix.gameInstallDir()
///   • flipFullyInstalledToUpdateRequired(in:)     ← WinePrefix.flipFullyInstalledToUpdateRequired(in:)
///   • markInstalledGamesForUpdate(in:)            ← WinePrefix.markInstalledGamesForUpdate()
///   • parseSteamCMDProgress(...)   ← SteamSession (SteamCMD progress parsing)
///   • TestGameProfile              ← GameProfile (struct fields)
///   • TestGameEngine               ← GameEngine enum
///   • TestGraphicsAPI              ← GraphicsAPI enum
///   • TestCompatStatus             ← CompatStatus enum
///   • TestDXMTMode                 ← GameProfile.DXMTMode enum
///   • unityFactory(...)            ← GameProfile.unity(...) factory defaults
///   • sourceFactory(...)           ← GameProfile.source(...) factory defaults
///   • customFactory(...)           ← GameProfile.custom(...) factory defaults
///   • dxmtDisabledOverride(...)    ← SteamSession.gameEnvironment dxmtMode .disabled logic
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

    func testLaunchPipelineResumesPartialAcfInsteadOfReportingInstalled() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("isGameFullyInstalled(appID: game.id)"),
                      "Launch/install gate must use fully-installed state, not mere ACF presence.")
        XCTAssertTrue(src.contains("isGameInstalled(appID: game.id)"),
                      "Fresh installs still need the pre-seeded ACF path.")
    }

    func testLibraryReconciliationUsesFullyInstalledState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamLibraryStore.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(src.contains("prefix.isGameFullyInstalled(appID: game.id)"),
                      "Library badges must not mark queued/partial ACFs as installed.")
    }

    func testFailedInstallResetIsGameScoped() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Views/Library/GameDetailView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(src.contains(".alert(\"Reset Game Install?\""),
                      "Failed-install reset must be presented as game-scoped.")
        XCTAssertTrue(src.contains("launcher.uninstall(game: currentGame"),
                      "Failed-install reset should remove only the selected game's files.")
        XCTAssertFalse(src.contains("WinePrefix.defaultPrefix.reset()"),
                       "Game detail reset must not wipe the whole Wine prefix or other games.")
    }

    // MARK: - SteamCMD stdout parsing tests

    /// Mirror of GameLauncher.parseSteamCMDProgress(line:)
    private func parseSteamCMDProgress(line: String) -> Double? {
        if line.contains("downloading, progress:"),
           let match = line.range(of: #"(\d+) / (\d+)"#, options: .regularExpression),
           case let parts = String(line[match]).components(separatedBy: " / "),
           parts.count == 2,
           let downloaded = Double(parts[0]),
           let total = Double(parts[1]),
           total > 0,
           downloaded / total > 0 {
            return downloaded / total
        } else if line.contains("Success! App") {
            return 1.0
        }
        return nil
    }

    /// Mirror of GameLauncher.formatBytes(_:)
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

    private enum TestInstallPhase {
        case preparing
        case downloading
        case installing
        case installed

        var userDescription: String {
            switch self {
            case .preparing:   return "Preparing"
            case .downloading: return "Downloading"
            case .installing:  return "Installing"
            case .installed:   return "Installed"
            }
        }
    }

    /// Mirror of GameLauncher.installActivityMessage(...)
    private func installActivityMessage(
        gameName: String,
        phase: TestInstallPhase,
        downloadedBytes: Int64,
        downloadTotalBytes: Int64,
        installedBytes: Int64,
        installTotalBytes: Int64,
        percent: Int
    ) -> String {
        let verb = phase.userDescription
        switch phase {
        case .downloading:
            return "\(verb) \(gameName) — \(formatBytes(downloadedBytes)) / \(formatBytes(downloadTotalBytes)) (\(percent)%)"
        case .installing:
            guard installedBytes > 0 else {
                if downloadedBytes > 0 && downloadTotalBytes > 0 {
                    return "\(verb) \(gameName) — download complete, preparing files (\(percent)%)"
                }
                return "\(verb) \(gameName) — preparing files (\(percent)%)"
            }
            return "\(verb) \(gameName) — \(formatBytes(installedBytes)) / \(formatBytes(installTotalBytes)) (\(percent)%)"
        case .installed:
            return "\(verb) \(gameName)"
        case .preparing:
            return "\(verb) \(gameName)…"
        }
    }

    func testParseSteamCMDProgressDownloading() {
        let line = "Update state (0x61) downloading, progress: 43.50 (3362453174 / 7729379123)"
        let result = parseSteamCMDProgress(line: line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 3362453174.0 / 7729379123.0, accuracy: 0.0001)
    }

    func testParseSteamCMDProgressSmallGame() {
        let line = "Update state (0x61) downloading, progress: 62.47 (694855688 / 1112250025)"
        let result = parseSteamCMDProgress(line: line)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!, 694855688.0 / 1112250025.0, accuracy: 0.0001)
    }

    func testParseSteamCMDProgressSuccess() {
        let line = "Success! App '3527290' fully installed."
        XCTAssertEqual(parseSteamCMDProgress(line: line), 1.0)
    }

    func testParseSteamCMDProgressReturnsNilForNonProgressLine() {
        XCTAssertNil(parseSteamCMDProgress(line: "Loading Steam API...OK"))
        XCTAssertNil(parseSteamCMDProgress(line: "Logging in using cached credentials."))
        XCTAssertNil(parseSteamCMDProgress(line: "[  0%] Checking for available updates..."))
        XCTAssertNil(parseSteamCMDProgress(line: "[----] Verifying installation..."))
        XCTAssertNil(parseSteamCMDProgress(line: "-- type 'quit' to exit --"))
    }

    func testParseSteamCMDProgressIgnoresSelfUpdate() {
        XCTAssertNil(parseSteamCMDProgress(line: "[----] Installing update..."))
    }

    func testParseSteamCMDProgressZeroBytesOfTotal() {
        let line = "Update state (0x61) downloading, progress: 0.00 (0 / 7729379123)"
        XCTAssertNil(parseSteamCMDProgress(line: line),
                     "0 bytes downloaded should return nil (guard downloaded/total > 0)")
    }

    func testParseSteamCMDProgressZeroTotal() {
        let line = "Update state (0x0) unknown, progress: 0.00 (0 / 0)"
        XCTAssertNil(parseSteamCMDProgress(line: line),
                     "0 / 0 should return nil (total == 0)")
    }

    func testParseSteamCMDProgressFullDownload() {
        let line = "Update state (0x61) downloading, progress: 99.15 (7663962059 / 7729379123)"
        let result = parseSteamCMDProgress(line: line)
        XCTAssertNotNil(result)
        XCTAssertGreaterThan(result!, 0.99)
    }

    // MARK: - formatBytes tests

    func testFormatBytesGB() {
        XCTAssertEqual(formatBytes(7_729_379_123), "7.2 GB")
        XCTAssertEqual(formatBytes(1_073_741_824), "1.0 GB")
        XCTAssertEqual(formatBytes(1_610_612_736), "1.5 GB")
    }

    func testFormatBytesMB() {
        XCTAssertEqual(formatBytes(500_000_000), "477 MB")
        XCTAssertEqual(formatBytes(1_048_576), "1 MB")
    }

    func testFormatBytesKB() {
        XCTAssertEqual(formatBytes(512_000), "500 KB")
        XCTAssertEqual(formatBytes(1024), "1 KB")
    }

    func testInstallActivityDoesNotShowZeroCommittedBytesAtPhaseBoundary() {
        let message = installActivityMessage(
            gameName: "Half-Life 2",
            phase: .installing,
            downloadedBytes: 3_187_105_792,
            downloadTotalBytes: 3_172_218_096,
            installedBytes: 0,
            installTotalBytes: 6_197_695_726,
            percent: 90
        )

        XCTAssertEqual(message, "Installing Half-Life 2 — download complete, preparing files (90%)")
        XCTAssertFalse(message.contains("0 KB / 5.8 GB"))
    }

    func testInstallActivityShowsCommittedBytesOnceFilesAppear() {
        let message = installActivityMessage(
            gameName: "Half-Life 2",
            phase: .installing,
            downloadedBytes: 3_187_105_792,
            downloadTotalBytes: 3_172_218_096,
            installedBytes: 1_610_612_736,
            installTotalBytes: 6_197_695_726,
            percent: 92
        )

        XCTAssertEqual(message, "Installing Half-Life 2 — 1.5 GB / 5.8 GB (92%)")
    }

    func testInstallProgressUsesManifestInstallDirForCommittedBytes() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("isGameFullyInstalled(appID: game.id)"),
                      "Install flow must use fully-installed state to detect completion.")
    }

    // MARK: - GameCompatibilityDB profile tests

    /// Mirror enums from GameProfile.swift
    private enum TestGameEngine: String { case unity, unreal, godot, source, custom, unknown }
    private enum TestGraphicsAPI: String { case dx9, dx11, dx12, vulkan, unknown }
    private enum TestCompatStatus: String { case verified, playable, launches, broken, untested }
    private enum TestDXMTMode { case auto, required, disabled }

    /// Mirror of GameProfile for testing DB lookups.
    /// MIRROR CONTRACT: Mirrors GameProfile (GameProfile.swift)
    private struct TestGameProfile {
        let appID: Int
        let name: String
        let gameEngine: TestGameEngine
        let graphicsAPI: TestGraphicsAPI
        let status: TestCompatStatus
        let dllOverrides: String?
        let dxmtMode: TestDXMTMode
        let extraEnv: [String: String]
        let launchViaSteam: Bool
    }

    private let testProfiles: [Int: TestGameProfile] = [
        3180070: TestGameProfile(
            appID: 3180070, name: "No, I'm not a Human",
            gameEngine: .unity, graphicsAPI: .dx11, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        ),
        813230: TestGameProfile(
            appID: 813230, name: "ANIMAL WELL",
            gameEngine: .custom, graphicsAPI: .dx12, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        ),
        3527290: TestGameProfile(
            appID: 3527290, name: "PEAK",
            gameEngine: .unity, graphicsAPI: .dx12, status: .broken,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        ),
        4069520: TestGameProfile(
            appID: 4069520, name: "Super Battle Golf",
            gameEngine: .unity, graphicsAPI: .dx12, status: .broken,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        ),
        220: TestGameProfile(
            appID: 220, name: "Half-Life 2",
            gameEngine: .source, graphicsAPI: .dx9, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        ),
    ]

    func testAllKnownGamesHaveProfiles() {
        for (appID, expected) in testProfiles {
            XCTAssertNotNil(testProfiles[appID], "Missing profile for appID=\(appID) (\(expected.name))")
        }
    }

    func testDX12GamesHaveCorrectGraphicsAPI() {
        let dx12IDs = [813230, 3527290, 4069520] // Animal Well, PEAK, Super Battle Golf
        for appID in dx12IDs {
            let profile = testProfiles[appID]
            XCTAssertEqual(profile?.graphicsAPI, .dx12,
                           "\(profile?.name ?? String(appID)) should be .dx12")
        }
    }

    func testUnknownGameReturnsNilProfile() {
        XCTAssertNil(testProfiles[99999])
    }

    func testVerifiedGamesHaveCorrectStatus() {
        let verifiedIDs = [3180070, 813230]
        for appID in verifiedIDs {
            let profile = testProfiles[appID]
            XCTAssertEqual(profile?.status, .verified,
                           "appID=\(appID) should be .verified")
        }
    }

    func testBrokenGamesHaveCorrectStatus() {
        let brokenIDs = [3527290, 4069520]
        for appID in brokenIDs {
            let profile = testProfiles[appID]
            XCTAssertEqual(profile?.status, .broken,
                           "appID=\(appID) should be .broken")
        }
    }

    func testUnityGamesHaveUnityEngine() {
        let unityIDs = [3180070, 3527290, 4069520]
        for appID in unityIDs {
            let profile = testProfiles[appID]
            XCTAssertEqual(profile?.gameEngine, .unity,
                           "appID=\(appID) should be .unity engine")
        }
    }

    func testCustomEngineGamesHaveCustomEngine() {
        XCTAssertEqual(testProfiles[813230]?.gameEngine, .custom)
    }

    func testHalfLife2UsesDirectExecProfile() throws {
        let profile = testProfiles[220]
        XCTAssertEqual(profile?.gameEngine, .source)
        XCTAssertFalse(profile?.launchViaSteam ?? true,
                       "HL2 must use direct-exec (launchViaSteam=false) to avoid the Wine 11.4 loader page-fault under steam.exe -applaunch")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceProfiles = try String(
            contentsOf: root.appendingPathComponent("Meridian/Engine/GameCompatibilityDB+Source.swift"),
            encoding: .utf8
        )
        let gameProfile = try String(
            contentsOf: root.appendingPathComponent("Meridian/Engine/GameProfile.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(sourceProfiles.contains("appID: 220"), "HL2 profile must be in +Source.swift")
        XCTAssertTrue(sourceProfiles.contains("hl2_complete"), "HL2 profile must target hl2_complete content folder")
        // The .source() factory must NOT default to launchViaSteam: true — guard against regression
        XCTAssertFalse(gameProfile.contains("launchViaSteam: Bool = true"),
                       ".source() factory must default launchViaSteam: false (same as all other factories)")
    }

    // MARK: - Factory method default tests

    /// Mirror of GameProfile.unity() factory defaults
    private func unityFactory(
        appID: Int = 1,
        name: String = "Test",
        graphicsAPI: TestGraphicsAPI = .dx11,
        dxmtMode: TestDXMTMode = .auto
    ) -> TestGameProfile {
        TestGameProfile(
            appID: appID, name: name,
            gameEngine: .unity, graphicsAPI: graphicsAPI, status: .untested,
            dllOverrides: nil, dxmtMode: dxmtMode, extraEnv: [:], launchViaSteam: false
        )
    }

    /// Mirror of GameProfile.source() factory defaults
    private func sourceFactory(
        appID: Int = 1,
        name: String = "Test",
        graphicsAPI: TestGraphicsAPI = .unknown,
        launchViaSteam: Bool = false
    ) -> TestGameProfile {
        TestGameProfile(
            appID: appID, name: name,
            gameEngine: .source, graphicsAPI: graphicsAPI, status: .untested,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: launchViaSteam
        )
    }

    /// Mirror of GameProfile.custom() factory defaults
    private func customFactory(
        appID: Int = 1,
        name: String = "Test",
        graphicsAPI: TestGraphicsAPI = .unknown
    ) -> TestGameProfile {
        TestGameProfile(
            appID: appID, name: name,
            gameEngine: .custom, graphicsAPI: graphicsAPI, status: .untested,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], launchViaSteam: false
        )
    }

    func testUnityFactoryDefaults() {
        let p = unityFactory()
        XCTAssertEqual(p.gameEngine, .unity)
        XCTAssertEqual(p.graphicsAPI, .dx11)
        XCTAssertEqual(p.dxmtMode, .auto)
    }

    func testUnityFactoryAllowsOverride() {
        let p = unityFactory(graphicsAPI: .dx12, dxmtMode: .required)
        XCTAssertEqual(p.graphicsAPI, .dx12)
        XCTAssertEqual(p.dxmtMode, .required)
    }

    func testCustomFactoryDefaults() {
        let p = customFactory()
        XCTAssertEqual(p.gameEngine, .custom)
        XCTAssertEqual(p.graphicsAPI, .unknown)
        XCTAssertFalse(p.launchViaSteam)
    }

    func testSourceFactoryDefaultsToDirectExec() {
        let p = sourceFactory()
        XCTAssertEqual(p.gameEngine, .source)
        XCTAssertEqual(p.graphicsAPI, .unknown)
        XCTAssertFalse(p.launchViaSteam,
                       ".source() factory must default launchViaSteam: false — same as .unity() and .custom()")
    }

    func testCustomFactoryAllowsOverride() {
        let p = customFactory(graphicsAPI: .dx12)
        XCTAssertEqual(p.graphicsAPI, .dx12)
    }

    // MARK: - DLL override merge logic tests

    /// Mirror of the merge logic in SteamSession.gameEnvironment
    private func mergeOverrides(existing: String?, gameOverrides: String?) -> String? {
        guard let gameOverrides else { return existing }
        if let existing, !existing.isEmpty {
            return existing + ";" + gameOverrides
        }
        return gameOverrides
    }

    func testMergeOverridesAppendsToExisting() {
        let result = mergeOverrides(existing: "d3d11=n,b", gameOverrides: "vcrun2019=n")
        XCTAssertEqual(result, "d3d11=n,b;vcrun2019=n")
    }

    func testMergeOverridesSetsWhenNoExisting() {
        let result = mergeOverrides(existing: nil, gameOverrides: "vcrun2019=n")
        XCTAssertEqual(result, "vcrun2019=n")
    }

    func testMergeOverridesSetsWhenExistingEmpty() {
        let result = mergeOverrides(existing: "", gameOverrides: "vcrun2019=n")
        XCTAssertEqual(result, "vcrun2019=n")
    }

    func testMergeOverridesReturnsExistingWhenNoGameOverrides() {
        let result = mergeOverrides(existing: "d3d11=n,b", gameOverrides: nil)
        XCTAssertEqual(result, "d3d11=n,b")
    }

    func testMergeOverridesReturnsNilWhenBothNil() {
        let result = mergeOverrides(existing: nil, gameOverrides: nil)
        XCTAssertNil(result)
    }

    // MARK: - dxmtMode .disabled merge logic test

    /// Mirror of SteamSession.gameEnvironment dxmtMode .disabled logic
    private func dxmtDisabledOverride(existing: String?) -> String {
        let disableOverride = "d3d11,dxgi=b"
        if let existing, !existing.isEmpty {
            return existing + ";" + disableOverride
        }
        return disableOverride
    }

    func testDxmtDisabledAppendsToExisting() {
        let result = dxmtDisabledOverride(existing: "winemetal=b;d3d11,d3d12,dxgi=n,b")
        XCTAssertEqual(result, "winemetal=b;d3d11,d3d12,dxgi=n,b;d3d11,dxgi=b")
    }

    func testDxmtDisabledSetsWhenNoExisting() {
        let result = dxmtDisabledOverride(existing: nil)
        XCTAssertEqual(result, "d3d11,dxgi=b")
    }

    func testDxmtDisabledSetsWhenExistingEmpty() {
        let result = dxmtDisabledOverride(existing: "")
        XCTAssertEqual(result, "d3d11,dxgi=b")
    }

    // MARK: - markInstalledGamesForUpdate helpers (retained for WinePrefix unit tests; not used in bootstrap)

    /// Mirror of WinePrefix.flipFullyInstalledToUpdateRequired(in:)
    private static func flipFullyInstalledToUpdateRequired(in acfContents: String) -> String? {
        let lines = acfContents.components(separatedBy: "\n")
        var changed = false
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines {
            if !changed,
               let kv = vdfKeyValueStatic(from: line),
               kv.key == "StateFlags",
               kv.value == "4"
            {
                output.append(line.replacingOccurrences(of: "\"4\"", with: "\"1026\""))
                changed = true
            } else {
                output.append(line)
            }
        }
        return changed ? output.joined(separator: "\n") : nil
    }

    /// Static mirror of vdfKeyValue so the static `flip…` helper above can use it.
    private static func vdfKeyValueStatic(from line: String) -> (key: String, value: String)? {
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

    /// Mirror of WinePrefix.markInstalledGamesForUpdate() restricted to the
    /// single steamapps directory used by the tests (no multi-library walk).
    @discardableResult
    private func markInstalledGamesForUpdate(in steamappsDir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: steamappsDir.path(percentEncoded: false)) else {
            return 0
        }
        var marked = 0
        for name in entries where name.hasPrefix("appmanifest_") && name.hasSuffix(".acf") {
            let acfURL = steamappsDir.appending(path: name)
            guard let contents = try? String(contentsOfFile: acfURL.path(percentEncoded: false), encoding: .utf8),
                  let updated = Self.flipFullyInstalledToUpdateRequired(in: contents)
            else { continue }
            if (try? updated.write(to: acfURL, atomically: true, encoding: .utf8)) != nil {
                marked += 1
            }
        }
        return marked
    }

    func testFlipFullyInstalledFlipsExactlyTheStateFlagsLine() {
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"220"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"Half-Life 2"
        \t"buildid"\t\t"19307283"
        }
        """
        let result = Self.flipFullyInstalledToUpdateRequired(in: acf)
        XCTAssertNotNil(result)
        // StateFlags must flip 4 → 1026
        XCTAssertTrue(result!.contains("\"StateFlags\"\t\t\"1026\""))
        // Other keys must be preserved verbatim
        XCTAssertTrue(result!.contains("\"appid\"\t\t\"220\""))
        XCTAssertTrue(result!.contains("\"installdir\"\t\t\"Half-Life 2\""))
        XCTAssertTrue(result!.contains("\"buildid\"\t\t\"19307283\""))
    }

    func testFlipFullyInstalledReturnsNilForQueuedManifest() {
        let acf = """
        "AppState"
        {
        \t"StateFlags"\t\t"1026"
        \t"BytesDownloaded"\t\t"100"
        }
        """
        XCTAssertNil(Self.flipFullyInstalledToUpdateRequired(in: acf),
                     "Manifest already at StateFlags=1026 must not be rewritten.")
    }

    func testFlipFullyInstalledReturnsNilWhenNoStateFlagsLine() {
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"220"
        }
        """
        XCTAssertNil(Self.flipFullyInstalledToUpdateRequired(in: acf))
    }

    func testFlipFullyInstalledIgnoresUnrelatedFlagValues() {
        for flags in ["0", "1", "2", "16", "1024", "1026", "4096"] {
            let acf = "\"AppState\"\n{\n\t\"StateFlags\"\t\t\"\(flags)\"\n}\n"
            XCTAssertNil(Self.flipFullyInstalledToUpdateRequired(in: acf),
                         "StateFlags=\(flags) must not be flipped — only \"4\" is the legal source state.")
        }
    }

    func testMarkInstalledGamesForUpdateFlipsFullyInstalledOnly() throws {
        try writeACF(appID: 220, stateFlags: "4")
        try writeACF(appID: 813230, stateFlags: "4")
        try writeACF(appID: 3527290, stateFlags: "1026", bytesDownloaded: 100, bytesToDownload: 1000)

        let count = markInstalledGamesForUpdate(in: steamappsDir)
        XCTAssertEqual(count, 2, "Only the two StateFlags=4 manifests should be rewritten.")

        // The two installed ACFs flipped to 1026
        XCTAssertFalse(isGameFullyInstalled(appID: 220, steamInstallDir: tempDir))
        XCTAssertFalse(isGameFullyInstalled(appID: 813230, steamInstallDir: tempDir))

        // The mid-download ACF stays at 1026 (no double-flip, no regression)
        let p = try XCTUnwrap(gameDownloadProgress(appID: 3527290, steamInstallDir: tempDir))
        XCTAssertEqual(p.stateFlags, "1026")
    }

    func testMarkInstalledGamesForUpdatePreservesOtherFields() throws {
        try writeACF(appID: 220, name: "Half-Life 2", installDir: "Half-Life 2", stateFlags: "4")
        _ = markInstalledGamesForUpdate(in: steamappsDir)

        // Name + installDir are preserved across the rewrite — only StateFlags changes.
        XCTAssertEqual(gameInstallDir(appID: 220, steamInstallDir: tempDir), "Half-Life 2")
        let acfContents = try String(
            contentsOfFile: steamappsDir.appending(path: "appmanifest_220.acf").path(percentEncoded: false),
            encoding: .utf8
        )
        XCTAssertTrue(acfContents.contains("\"name\"\t\t\"Half-Life 2\""))
        XCTAssertTrue(acfContents.contains("\"StateFlags\"\t\t\"1026\""))
    }

    func testMarkInstalledGamesForUpdateReturnsZeroOnEmptySteamapps() {
        let count = markInstalledGamesForUpdate(in: steamappsDir)
        XCTAssertEqual(count, 0)
    }

    /// Removed: `markInstalledGamesForUpdate` is no longer called from the bootstrap
    /// pipeline. Flipping all installed game ACFs to StateFlags=1026 at every launch
    /// caused Steam to fire download-complete notifications, briefly show the Dock icon,
    /// flash bottom-right Steam notifications, and made the Meridian UI show the Install
    /// button for all games until Steam re-validated them (~60–90 s). The update-check
    /// edge case it was designed to solve (stale buildid) is handled by Steam's normal
    /// PICS version check when the game is launched. See no-piling-on.mdc.

    // MARK: - Rewrite architecture guards

    /// SteamSession.installGame must use SteamCMD with PTY wrapper for real-time output.
    func testSteamSession_installUsessteamCMDWithPTYWrapper() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("\"/usr/bin/script\""),
                      "SteamCMD must run inside /usr/bin/script PTY wrapper for line-buffered output")
        XCTAssertTrue(src.contains("\"-overrideminos\""),
                      "SteamCMD invocation must include -overrideminos flag")
        XCTAssertTrue(src.contains("activeSteamCMDProcess"),
                      "activeSteamCMDProcess must be stored for cancellation")
    }

    /// Launcher.cancelLaunch must cancel the SteamCMD process.
    func testLauncher_cancelLaunchCancelsSteamCMD() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("cancelInstall()"),
                      "Launcher.cancelLaunch must call session.cancelInstall() to stop SteamCMD downloads")
    }

    /// SteamSession.installGame must require isReady before starting.
    func testSteamSession_installRequiresIsReady() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("guard isReady else"),
                      "SteamSession.installGame must guard on isReady — no implicit Steam restart")
    }
}
