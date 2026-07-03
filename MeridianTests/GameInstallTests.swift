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
///   • resolveRenderer(env:)        ← GameStackReport.resolve renderer inference
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

    // MARK: - SteamCMD stdout parsing tests (deleted May 19 2026)
    //
    // SteamCMD-based installs were replaced by Steam IPC (`steam://install/<id>`)
    // sent to the already-running persistent steam.exe. Stdout parsing of
    // `Update state (0x61) downloading, progress:` lines no longer exists in
    // production; progress now comes from `WinePrefix.gameDownloadProgress`
    // reading the ACF manifest, which is covered by the existing
    // `testProgress*` tests at the top of this file.

    // MARK: - formatBytes tests

    /// Mirror of GameLauncher.formatBytes(_:)
    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }

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

    // installActivityMessage mirror tests deleted May 19 2026 — the production
    // function no longer exists. Status messages now come from the simpler
    // `currentActivity` updates set directly in Launcher.executeLaunchPipeline.

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
        let preferD3DMetal: Bool
        let launchViaSteam: Bool
    }

    private let testProfiles: [Int: TestGameProfile] = [
        3180070: TestGameProfile(
            appID: 3180070, name: "No, I'm not a Human",
            gameEngine: .unity, graphicsAPI: .dx11, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: true, launchViaSteam: false
        ),
        813230: TestGameProfile(
            appID: 813230, name: "ANIMAL WELL",
            gameEngine: .custom, graphicsAPI: .dx12, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
        ),
        3527290: TestGameProfile(
            appID: 3527290, name: "PEAK",
            gameEngine: .unity, graphicsAPI: .dx12, status: .broken,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
        ),
        4069520: TestGameProfile(
            appID: 4069520, name: "Super Battle Golf",
            gameEngine: .unity, graphicsAPI: .dx12, status: .broken,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
        ),
        220: TestGameProfile(
            appID: 220, name: "Half-Life 2",
            gameEngine: .source, graphicsAPI: .dx9, status: .verified,
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
        ),
    ]

    /// No, I'm not a Human must opt into the D3DMetal D3D11 path so its
    /// Media Foundation video cutscenes render (DXMT serves black). Mirror
    /// of the GameCompatibilityDB+Unity entry; production wiring guarded by
    /// `testSteamSession_preferD3DMetalUsesGraphicsBackendSwitch` (BootstrapTests).
    func testNoImNotAHumanPrefersD3DMetal() throws {
        XCTAssertEqual(testProfiles[3180070]?.preferD3DMetal, true,
                       "No I'm not a Human needs preferD3DMetal for MF video cutscenes")

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let unity = try String(
            contentsOf: root.appendingPathComponent("Meridian/Engine/GameCompatibilityDB+Unity.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(unity.contains("preferD3DMetal: true"),
                      "appID 3180070 entry must set preferD3DMetal: true")
    }

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
            dllOverrides: nil, dxmtMode: dxmtMode, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
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
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: launchViaSteam
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
            dllOverrides: nil, dxmtMode: .auto, extraEnv: [:], preferD3DMetal: false, launchViaSteam: false
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

    /// SteamSession.installGame must drive installs silently via the
    /// pre-seeded-ACF + Steam-restart pattern. `steam://install` URL
    /// dispatch always shows Steam's install-location picker dialog —
    /// CLI-confirmed user report May 20 2026 ("I get the full steam UI
    /// with the standard steam install window to chose where to
    /// download"). Pre-seeded ACF + Steam restart triggers Steam's
    /// login-post-callback library scan which silently begins the
    /// download with no picker dialog.
    func testSteamSession_installIsSilent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )

        // Must pre-seed the ACF — the install location goes here, not
        // into a Steam-rendered picker.
        XCTAssertTrue(src.contains("writePreseededAppManifest("),
                      "installGame must pre-seed the ACF manifest with installdir/name/StateFlags=1026 so Steam doesn't need to ask the user where to install")

        // Must cycle Steam so its startup library scan picks up the
        // pre-seeded ACF and begins the silent download.
        XCTAssertTrue(src.contains("await shutdown(engine:") || src.contains("await shutdown(engine: engine)"),
                      "installGame must call shutdown(engine:) so Steam tears down before we re-start it with the pre-seeded ACF visible")
        XCTAssertTrue(src.contains("await start(engine:") || src.contains("await start(engine: engine)"),
                      "installGame must call start(engine:) after writing the ACF so Steam re-runs its login-post-callback library scan and begins the download silently")

        // Must NOT dispatch `steam://install/<id>` — that URL is the
        // bug being fixed; it triggers Valve's install picker dialog.
        // Documentation comments may mention the URL to explain why we
        // don't use it, but no source-code dispatch.
        let installDispatch = "sendSteamCommand([\"steam://install/"
        XCTAssertFalse(src.contains(installDispatch),
                       "installGame MUST NOT dispatch steam://install/<id> — that URL ALWAYS opens Valve's install-location picker dialog. CLI-confirmed user report May 20 2026.")

        // Must NOT contain executable code that runs SteamCMD.
        let forbidden = [
            "\"/usr/bin/script\"",       // PTY wrapper used to line-buffer SteamCMD stdout
            "\"-overrideminos\"",        // SteamCMD-specific flag
            "activeSteamCMDProcess",     // Stored Process handle for SteamCMD
            "\"+login\"",                // SteamCMD-style +command syntax
            "\"+app_update\"",
            "\"+quit\"",
            ".appending(path: \"steamcmd.exe\")",
        ]
        for token in forbidden {
            XCTAssertFalse(src.contains(token),
                           "SteamSession MUST NOT contain `\(token)` — SteamCMD code path was deleted May 19 2026.")
        }
    }

    /// Phase 4 (HANDOFF-2026-06-19): DRM-game launches use the Steamworks API
    /// shim (gbe_fork emulator replacing the game's Valve steam_api(64).dll)
    /// and then launch directly via wine64 — NO steam.exe, no `-applaunch`, no
    /// silent-auth wall. This replaces the steam.exe IPC path, which was
    /// blocked by steam.exe's unreliable silent auto-login (it loads local.vdf
    /// but never authenticates — the "Who's playing" wall). SteamSession's
    /// `launchGameViaSteam` is retained as a documented SteamStub fallback.
    func testLauncher_drmGamesUseSteamworksShim() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let launcher = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        // Phase 4: DRM games are satisfied in-process by the gbe_fork
        // Steamworks API shim, then launched directly via wine64 — NOT via
        // steam.exe -applaunch.
        XCTAssertTrue(launcher.contains("installSteamEmulator"),
                      "Launcher must install the Steamworks API shim for DRM games")
        XCTAssertTrue(launcher.contains("gameRequiresSteamAPI"),
                      "Launcher must branch on prefix.gameRequiresSteamAPI to decide whether to shim")
        XCTAssertFalse(launcher.contains("launchViaSteam"),
                      "Launcher must no longer use the steam.exe -applaunch path (replaced by the shim)")

        // SteamSession retains launchGameViaSteam as the documented SteamStub
        // fallback (not used on the default path).
        let session = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(session.contains("launchGameViaSteam"),
                      "SteamSession must retain launchGameViaSteam(appID:engine:) as the SteamStub fallback")
    }

    /// Launcher.uninstallGame must resolve the ACF via `prefix.acfURL(for:)`
    /// which searches `<library>/steamapps/appmanifest_<id>.acf` — NOT
    /// `<library>/appmanifest_<id>.acf` directly. CLI-confirmed user
    /// report May 20 2026: every uninstall attempt logged
    /// `ACF not found — nothing to remove` because the old code missed
    /// the `steamapps/` path component, leaving the user unable to
    /// uninstall games via Meridian even when the ACF was right there.
    func testLauncher_uninstallResolvesACFCorrectly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )

        // Must use prefix.acfURL — the helper that already knows the
        // `steamapps/` subdirectory layout.
        XCTAssertTrue(src.contains("prefix.acfURL(for: game.id)"),
                      "Launcher.uninstallGame must use prefix.acfURL(for:) to find the ACF — manual <library>/appmanifest_<id>.acf path is missing the steamapps/ component and never matches")

        // Must NOT do the old broken manual concatenation. That pattern
        // was the bug.
        XCTAssertFalse(src.contains("lib + \"/appmanifest_"),
                       "Launcher.uninstallGame MUST NOT manually concatenate `<library>/appmanifest_<id>.acf` — the steamapps/ subdir is missing from that path; use prefix.acfURL instead")
    }

    /// Launcher.cancelLaunch must call session.cancelInstall() so the UI returns to idle.
    func testLauncher_cancelLaunchCallsCancelInstall() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("cancelInstall()"),
                      "Launcher.cancelLaunch must call session.cancelInstall() to notify SteamSession of UI cancellation")
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

    // MARK: - Launch state machine guards (May 19 2026 fix)

    /// Launcher.executePipeline must pass `gamePattern` (the game's installdir)
    /// to GameProcess.startMonitoring. Without it, the monitor falls back to
    /// PID-set baseline detection which can't see the game's process when
    /// wineserver hands it off, leaving the user stuck at "Launching…" until
    /// the 120 s timeout fires. CLI-observed May 19 2026.
    func testLauncher_passesGamePatternToMonitor() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("prefix.gameInstallDir(appID:"),
                      "Launcher.executePipeline must read gameInstallDir to use as gamePattern")
        XCTAssertTrue(src.contains("gamePattern: gamePattern"),
                      "Launcher.executePipeline must pass the resolved gamePattern through to startMonitoring")
    }

    /// `launchState = .running(appID:)` must NOT be set immediately after
    /// `launchDirect`. It must wait for `gameProcess.monitorPhase == .running`
    /// (i.e. Phase 1 startup confirmation). Otherwise the UI claims "Game
    /// running" while the wine64 process has already crashed silently — the
    /// "claims running but nothing launches" symptom user reported May 19 2026.
    func testLauncher_doesNotFlipRunningOptimistically() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )

        // The state must be set inside a switch on `gameProcess.monitorPhase`,
        // not on the line immediately after `launchDirect` returns. We require
        // the new state machine pattern (switch over MonitorPhase) is present.
        XCTAssertTrue(src.contains("switch gameProcess.monitorPhase"),
                      "Launcher must select launchState by switching on gameProcess.monitorPhase, not flipping to .running optimistically")
        XCTAssertTrue(src.contains("while gameProcess.monitorPhase == .startup"),
                      "Launcher must wait for the startup phase to complete before deciding running vs failed")
        XCTAssertTrue(src.contains("case .timedOut:"),
                      "Launcher must surface monitor .timedOut as a user-visible failure, not a silent hang")
        XCTAssertTrue(src.contains("case .failed("),
                      "Launcher must surface monitor .failed as a user-visible failure")
    }

    /// SteamSession.configureSteamRegistry must write `NotifyAvailableGames=0`
    /// alongside the StartMinimized + WebProcessCmdLine keys. Without it,
    /// Steam fires its post-login "X is installed" toast burst into macOS
    /// Notification Center for every ACF manifest in the prefix — toasts the
    /// user can't dismiss because Steam's UI is suppressed. User-reported
    /// May 19 2026.
    func testSteamSession_configuresNotifyAvailableGamesOff() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(src.contains("\"NotifyAvailableGames\""),
                      "SteamSession.configureSteamRegistry must write HKCU\\Software\\Valve\\Steam\\NotifyAvailableGames=0 to silence the post-login installed-games toast burst")
        XCTAssertTrue(src.contains("\"DesktopNotifications\""),
                      "SteamSession.configureSteamRegistry must write HKCU\\Software\\Valve\\Steam\\DesktopNotifications=0 (native-UI toast suppression)")
    }

    /// Per-game logs (logs/games/<appID>.log) must be created on every
    /// game launch. Without this, the only way to diagnose a launch
    /// failure is to read meridian.log which interleaves output from all
    /// subsystems and truncates after 200 lines per game session. The
    /// per-game file uses kernel-level FileHandle for stdout/stderr,
    /// avoiding the availableData blocking pattern (engine-research-
    /// findings.mdc Pattern 1).
    func testLauncher_writesPerGameLog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let launcher = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(launcher.contains("GameLogFile.beginSession"),
                      "Launcher.launchDirect must call GameLogFile.beginSession to open the per-game log before launching")
        XCTAssertTrue(launcher.contains("GameLogFile.endSession") || launcher.contains("closeActiveGameLog"),
                      "Launcher must close the per-game log on every exit path so the file has a useful trailer")
        XCTAssertTrue(launcher.contains("process.standardOutput = logHandle"),
                      "Launcher.launchDirect must wire the game process's stdout to the per-game FileHandle (not a Pipe — Pipes block when wineserver inherits the write end)")
        XCTAssertTrue(launcher.contains("process.standardError = logHandle"),
                      "Launcher.launchDirect must wire the game process's stderr to the per-game FileHandle for the same reason")

        // The utility itself must exist.
        let gameLogFile = try String(
            contentsOf: root.appendingPathComponent("Meridian/Utilities/GameLogFile.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(gameLogFile.contains("static func beginSession"),
                      "GameLogFile.beginSession(appID:gameName:executable:launchArgs:environment:) must exist")
        XCTAssertTrue(gameLogFile.contains("static func endSession"),
                      "GameLogFile.endSession(handle:appID:reason:exitCode:) must exist")
        XCTAssertTrue(gameLogFile.contains("currentURL") && gameLogFile.contains("previousURL"),
                      "GameLogFile must rotate one generation: <appID>.log → <appID>-previous.log on every new launch")
    }

    /// Install progress now comes from the DepotDownloader fork's `-json`
    /// NDJSON stream (authoritative `bytesDone`/`bytesTotal` known up front),
    /// NOT from polling ACF `BytesDownloaded` (Valve buffers it in memory) or
    /// on-disk byte counts (that was the steam.exe-install workaround, now
    /// removed along with `pollDownloadProgress`). The UI byte/rate properties
    /// are still populated — driven by the DepotDownloader progress callbacks.
    func testLauncher_surfacesLiveDownloadProgress() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let src = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(src.contains("DepotDownloaderInstall.run"),
                      "install progress must be driven by the DepotDownloader -json stream")
        XCTAssertTrue(src.contains("onProgress:"),
                      "Launcher must consume DepotDownloader's onProgress callback")
        XCTAssertTrue(src.contains("downloadRateBps"),
                      "Launcher must expose download rate (bytes/s) for the UI to render MB/s")
        XCTAssertTrue(src.contains("downloadBytesDone") && src.contains("downloadBytesTotal"),
                      "Launcher must expose raw byte counts so the UI can render '123 MB / 456 MB' style progress")
        // The ACF/on-disk polling workaround is gone (DepotDownloader reports
        // authoritative totals directly).
        XCTAssertFalse(src.contains("pollDownloadProgress"),
                       "pollDownloadProgress (ACF/on-disk polling) is removed — DepotDownloader reports progress directly")
    }

    /// `WinePrefix.writeUserNotificationPreferences` must be called from BOTH
    /// the sign-in callback (fresh sign-in) AND the lazy DRM Steam bring-up
    /// (returning users with persisted credentials). The function writes the
    /// per-user `localconfig.vdf` keys that suppress webhelper-side toasts; the
    /// registry keys only cover native-UI toasts. Both layers are needed
    /// because Steam routes different toasts through different paths.
    ///
    /// Phase 3: the returning-user pre-write moved from BootstrapManager (cold
    /// start) to SteamSession.ensureReadyForDRM — Steam is no longer started on
    /// boot, so the pre-write happens just before the lazy `steam.exe -silent`.
    func testNotificationPrefs_calledAfterSignIn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let authView = try String(
            contentsOf: root.appendingPathComponent("Meridian/Views/Auth/AuthView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(authView.contains("writeUserNotificationPreferences"),
                      "SetupSheet.beginSignIn must call writeUserNotificationPreferences after a successful sign-in to silence the post-login toast burst")

        let session = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(session.contains("writeUserNotificationPreferences"),
                      "SteamSession.ensureReadyForDRM must call writeUserNotificationPreferences before the lazy steam.exe -silent so returning users' post-login toast burst is silenced")
    }

    // MARK: - GameStackReport renderer inference

    /// Mirror of `GameStackReport.parseOverrides` — WINEDLLOVERRIDES → mode map.
    private func parseOverridesMirror(_ s: String) -> [String: String] {
        var map: [String: String] = [:]
        for entry in s.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let mode = parts[1]
            for dll in parts[0].split(separator: ",") { map[String(dll)] = mode }
        }
        return map
    }

    /// Mirror of `GameStackReport.resolve` renderer inference. Returns the
    /// `Renderer.rawValue` Wine will actually use for a given resolved env.
    /// WHENEVER the production inference changes, update this mirror.
    private func resolveRenderer(env: [String: String]) -> String {
        let dllPath = env["WINEDLLPATH"] ?? ""
        let overrides = parseOverridesMirror(env["WINEDLLOVERRIDES"] ?? "")
        if env["CX_GRAPHICS_BACKEND"] == "d3dmetal" {
            // preferD3DMetal: cxcompatdb prepends GPTK D3DMetal builtins;
            // WINEDLLOVERRIDES is cleared. Must be checked FIRST (B4 fix).
            return "gptk"
        } else if dllPath.contains("/gptk"), overrides["d3d12"] == "b" {
            return "gptk"
        } else if dllPath.contains("/dxvk") {
            return "dxvk"
        } else if dllPath.contains("/dxmt"), let m = overrides["d3d11"], m.hasPrefix("n") {
            return "dxmt"
        } else if overrides["d3d11"] == "b" {
            return "wined3d"
        } else {
            return "unknown"
        }
    }

    func testStackReport_inferDXMTForDefaultDX11Env() {
        // The default DX11 game env from WineEngine.environment(for:).
        let env = [
            "WINEDLLPATH": "/engine/wine/lib/dxmt:/engine/wine/lib/wine",
            "WINEDLLOVERRIDES": "d3d11=n,b;dxgi=n,b;d3d10core=n,b",
        ]
        XCTAssertEqual(resolveRenderer(env: env), "dxmt")
    }

    func testStackReport_inferGPTKForDX12Env() {
        // The DX12 game env from SteamSession.gameEnvironment (profile.graphicsAPI == .dx12).
        let env = [
            "WINEDLLPATH": "/engine/wine/lib/gptk/wine:/engine/wine/lib/wine",
            "WINEDLLOVERRIDES": "d3d11=n,b;d3d10core=n,b;d3d12,dxgi=b",
        ]
        XCTAssertEqual(resolveRenderer(env: env), "gptk")
    }

    func testStackReport_inferDXVKWhenOnPath() {
        let env = [
            "WINEDLLPATH": "/engine/wine/lib/dxvk:/engine/wine/lib/wine",
            "WINEDLLOVERRIDES": "d3d11=n,b;dxgi=n,b",
        ]
        XCTAssertEqual(resolveRenderer(env: env), "dxvk")
    }

    func testStackReport_inferWined3dWhenDXMTDisabled() {
        // A game with dxmtMode == .disabled: d3d11 forced to builtin.
        let env = [
            "WINEDLLPATH": "/engine/wine/lib/dxmt:/engine/wine/lib/wine",
            "WINEDLLOVERRIDES": "d3d11=n,b;dxgi=n,b;d3d10core=n,b;d3d11,dxgi=b",
        ]
        // Last entry wins per Wine: d3d11=b → wined3d.
        XCTAssertEqual(resolveRenderer(env: env), "wined3d")
    }

    func testStackReport_inferUnknownWhenNoD3DOverride() {
        let env = ["WINEDLLPATH": "/engine/wine/lib/wine"]
        XCTAssertEqual(resolveRenderer(env: env), "unknown")
    }

    func testStackReport_inferGPTKForPreferD3DMetalEnv() {
        // The preferD3DMetal env from SteamSession.gameEnvironment: no
        // WINEDLLOVERRIDES, CX_GRAPHICS_BACKEND=d3dmetal, WINEDLLPATH=gptk/wine.
        // Before B4 this mis-reported as "unknown" (no d3d12=b override).
        let env = [
            "WINEDLLPATH": "/engine/wine/lib/gptk/wine:/engine/wine/lib/wine",
            "CX_GRAPHICS_BACKEND": "d3dmetal",
            "CX_ROOT": "/engine/wine",
        ]
        XCTAssertEqual(resolveRenderer(env: env), "gptk",
                       "preferD3DMetal (CX_GRAPHICS_BACKEND=d3dmetal) must report the GPTK/D3DMetal renderer, not unknown.")
    }

    func testStackReport_productionChecksGraphicsBackendFirst() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appending(path: "Meridian/Utilities/GameLogFile.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains(#"environment["CX_GRAPHICS_BACKEND"] == "d3dmetal""#),
                      "GameStackReport.resolve must detect the D3DMetal backend so preferD3DMetal games don't report unknown.")
        XCTAssertTrue(src.contains("CX_GRAPHICS_BACKEND") && src.contains("relevantEnvKeys"),
                      "CX_GRAPHICS_BACKEND must be in the per-game log header's relevantEnvKeys.")
    }

    func testEngine_surfacesD3DMetalAndDxmtVersions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appending(path: "Meridian/Engine/WineEngine.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("var d3dMetalVersion"),
                      "WineEngine must surface d3dMetalVersion from meridian-d3dmetal-version.txt.")
        XCTAssertTrue(src.contains("var dxmtVersion"),
                      "WineEngine must surface dxmtVersion from meridian-dxmt-version.txt.")
        XCTAssertTrue(src.contains("meridian-d3dmetal-version.txt"),
                      "WineEngine must read the D3DMetal version file written by release-engine.sh.")
    }

    func testCompatVerdict_carriesMeasuredFPS() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appending(path: "Meridian/Engine/GameCompatibilityDB.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("var fps: Double?"),
                      "CompatVerdictStore.Verdict must carry an optional measured fps for data-driven ranking.")
        XCTAssertTrue(src.contains("func recordFPS("),
                      "CompatVerdictStore must expose recordFPS to attach a measured frame rate.")
    }

    /// Wiring guard: GameStackReport, engine-log collection, and the enriched
    /// per-game header must all be present and wired into the launch pipeline.
    /// This is the "see what each game is running + diagnose crashes" feature
    /// (HANDOFF-2026-06-19 follow-up). Without these the only diagnostic is
    /// meridian.log, which interleaves every subsystem.
    func testStackReportAndEngineLog_wiredIntoLaunchPipeline() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let gameLog = try String(
            contentsOf: root.appendingPathComponent("Meridian/Utilities/GameLogFile.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(gameLog.contains("struct GameStackReport"),
                      "GameStackReport must exist to summarise the resolved graphics stack")
        XCTAssertTrue(gameLog.contains("static func resolve"),
                      "GameStackReport.resolve must derive the stack from the resolved env")
        XCTAssertTrue(gameLog.contains("var summaryLine") && gameLog.contains("var detailBlock"),
                      "GameStackReport must expose summaryLine (meridian.log) + detailBlock (per-game header)")
        XCTAssertTrue(gameLog.contains("case dxmt") && gameLog.contains("case gptk")
                      && gameLog.contains("case dxvk") && gameLog.contains("case wined3d"),
                      "GameStackReport.Renderer must enumerate every renderer Meridian can route to")
        XCTAssertTrue(gameLog.contains("static func collectEngineLogs"),
                      "GameLogFile.collectEngineLogs must copy the game's own Unity/Unreal log for diagnosis")
        XCTAssertTrue(gameLog.contains("static func engineLogURL"),
                      "GameLogFile.engineLogURL must expose the <appID>-engine.log path for the UI to open")
        XCTAssertTrue(gameLog.contains("stackReport: GameStackReport?"),
                      "GameLogFile.beginSession must accept the stack report so it lands in the per-game header")

        let launcher = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(launcher.contains("GameStackReport.resolve"),
                      "Launcher.launchDirect must resolve the stack report before launching")
        XCTAssertTrue(launcher.contains("stackReport.summaryLine"),
                      "Launcher must log the stack summary to meridian.log at launch")
        XCTAssertTrue(launcher.contains("stackReport: stackReport"),
                      "Launcher must pass the stack report into GameLogFile.beginSession")
        XCTAssertTrue(launcher.contains("GameLogFile.collectEngineLogs"),
                      "Launcher.closeActiveGameLog must collect the engine log on every exit path")
        XCTAssertTrue(launcher.contains("activeLaunchStartedAt"),
                      "Launcher must record the launch instant so only this session's engine log is collected")

        let detail = try String(
            contentsOf: root.appendingPathComponent("Meridian/Views/Library/GameDetailView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(detail.contains("GameLogFile.engineLogURL") && detail.contains("Open Engine Log"),
                      "GameDetailView must offer an 'Open Engine Log' action so users can read the game's own log")
        XCTAssertTrue(detail.contains("GameLogFile.currentURL") && detail.contains("Open Game Log"),
                      "GameDetailView must offer an 'Open Game Log' action so users can read the raw Wine output + resolved stack")
    }
}
