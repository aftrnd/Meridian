import XCTest
import Foundation

/// Unit tests for `WinePrefix` file-system logic.
///
/// Each test builds a minimal directory tree in a temporary folder that mirrors
/// the real Wine prefix layout, then exercises the pure logic under test.
/// No Wine processes are launched; all assertions are on file I/O and VDF parsing.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// MIRROR CONTRACT — READ BEFORE MODIFYING
/// ─────────────────────────────────────────────────────────────────────────────
/// The helper functions in the "Helpers: Inline WinePrefix logic" section are
/// exact copies of the private/computed logic in `WinePrefix.swift`. They exist
/// because `MeridianTests` cannot import `Meridian` (executableTarget restriction
/// in SPM — see Package.swift). As a result:
///
///   WHENEVER YOU CHANGE LOGIC IN WinePrefix.swift, YOU MUST ALSO UPDATE THE
///   CORRESPONDING MIRROR HERE. Failing to do so allows the tests to pass while
///   the production code is broken — exactly the class of regression that caused
///   the steam-install-path bug (March 2026).
///
/// Long-term fix: extract WinePrefix + WineEngine + MeridianLog into a
/// `MeridianCore` library target so tests can use `@testable import MeridianCore`
/// directly. Until that refactor lands, the mirrors below are the contract.
///
/// Mirrored functions (must stay in sync with WinePrefix.swift):
///   • steamInstallDir(driveC:)           ← WinePrefix.steamInstallDir
///   • steamExeWindowsPath(driveC:)       ← WinePrefix.steamExeWindowsPath
///   • ensureDefaultLibrary(steamInstallDir:) ← WinePrefix.ensureDefaultLibrary()
///   • ensureSteamCFG(steamInstallDir:)   ← WinePrefix.ensureSteamCFG()
///   • hasSteamLoginSession(configDir:)   ← WinePrefix.hasSteamLoginSession()
///   • steamLibraryFolders(...)           ← WinePrefix.steamLibraryFolders
///   • isGameInstalled(...)               ← WinePrefix.isGameInstalled()
///   • isGameFullyInstalled(...)          ← WinePrefix.isGameFullyInstalled()
///   • gameInstallDir(...)                ← WinePrefix.gameInstallDir()
///   • vdfKeyValue(from:)                 ← WinePrefix.vdfKeyValue(from:)
///   • windowsPathToURL(_:driveC:)        ← WinePrefix.windowsPathToURL(_:)
///   • simulateResetToEngineTemplate(...) ← WinePrefix.resetToEngineTemplate()
///   • isWoW64FileType(_:)               ← WinePrefix.isWoW64FileType(_:)
/// ─────────────────────────────────────────────────────────────────────────────
final class WinePrefixTests: XCTestCase {

    // MARK: - Helpers: Inline WinePrefix logic

    /// Mirrors WinePrefix.vdfKeyValue
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

    /// Mirrors WinePrefix.hasSteamLoginSession — line-level check for MostRecent "1"
    private func hasSteamLoginSession(configDir: URL) -> Bool {
        let vdfURL = configDir.appending(path: "loginusers.vdf")
        guard let content = try? String(contentsOf: vdfURL, encoding: .utf8) else { return false }
        return content.components(separatedBy: .newlines).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.contains("\"MostRecent\"") && t.contains("\"1\"")
        }
    }

    /// Mirrors WinePrefix.steamLibraryFolders — parses libraryfolders.vdf
    private func steamLibraryFolders(steamInstallDir: URL, prefixDriveC: URL) -> [URL] {
        var libraries: [URL] = [steamInstallDir]
        let vdfURL = steamInstallDir.appending(path: "steamapps/libraryfolders.vdf")
        guard let contents = try? String(contentsOf: vdfURL, encoding: .utf8) else { return libraries }

        for line in contents.components(separatedBy: .newlines) {
            guard let (key, value) = vdfKeyValue(from: line), !value.isEmpty else { continue }
            let isPathKey = key == "path"
            let isNumericNonZero = key != "0" && key.allSatisfy(\.isNumber)
            guard isPathKey || isNumericNonZero else { continue }

            if let url = windowsPathToURL(value, driveC: prefixDriveC) {
                let canonical = url.standardizedFileURL.path(percentEncoded: false)
                let defaultCanonical = steamInstallDir.standardizedFileURL.path(percentEncoded: false)
                if canonical != defaultCanonical { libraries.append(url) }
            }
        }
        return libraries
    }

    /// Mirrors WinePrefix.windowsPathToURL
    private func windowsPathToURL(_ windowsPath: String, driveC: URL) -> URL? {
        let normalized = windowsPath
            .replacingOccurrences(of: "\\\\", with: "/")
            .replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 3 else { return nil }
        let driveIdx = normalized.index(normalized.startIndex, offsetBy: 1)
        guard normalized[driveIdx] == ":" else { return URL(filePath: windowsPath) }
        let driveLetter = String(normalized.prefix(1)).lowercased()
        let afterDrive = normalized.index(normalized.startIndex, offsetBy: min(3, normalized.count))
        let remainingPath = String(normalized[afterDrive...])
        if driveLetter == "c" { return driveC.appending(path: remainingPath) }
        return nil
    }

    /// Mirrors WinePrefix.isGameInstalled — checks for ACF manifest
    private func isGameInstalled(appID: Int, steamInstallDir: URL, prefixDriveC: URL) -> Bool {
        let fm = FileManager.default
        for library in steamLibraryFolders(steamInstallDir: steamInstallDir, prefixDriveC: prefixDriveC) {
            let candidate = library.appending(path: "steamapps/appmanifest_\(appID).acf")
            if fm.fileExists(atPath: candidate.path(percentEncoded: false)) { return true }
        }
        return false
    }

    /// Mirrors WinePrefix.gameInstallDir — reads installdir from ACF
    private func gameInstallDir(appID: Int, steamInstallDir: URL, prefixDriveC: URL) -> String? {
        let fm = FileManager.default
        for library in steamLibraryFolders(steamInstallDir: steamInstallDir, prefixDriveC: prefixDriveC) {
            let acf = library.appending(path: "steamapps/appmanifest_\(appID).acf")
            guard fm.fileExists(atPath: acf.path(percentEncoded: false)),
                  let contents = try? String(contentsOf: acf, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n") {
                if let (key, value) = vdfKeyValue(from: line), key == "installdir", !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    /// Mirrors WinePrefix.ensureDefaultLibrary
    ///
    /// Writes libraryfolders.vdf with a Windows path matching the actual Steam
    /// install directory. Under wine-staging 11.5, this is `Program Files\Steam`;
    /// on older Wine builds it is `Program Files (x86)\Steam`.
    ///
    /// Source: WinePrefix.ensureDefaultLibrary() (WinePrefix.swift)
    /// ⚠️  Must be updated whenever WinePrefix.ensureDefaultLibrary() changes.
    private func ensureDefaultLibrary(steamInstallDir: URL) throws {
        let fm = FileManager.default
        let steamappsDir = steamInstallDir.appending(path: "steamapps")
        let vdfURL = steamappsDir.appending(path: "libraryfolders.vdf")
        if !fm.fileExists(atPath: steamappsDir.path(percentEncoded: false)) {
            try fm.createDirectory(at: steamappsDir, withIntermediateDirectories: true)
        }
        // Derive the Windows path from the actual install directory path.
        // This mirrors WinePrefix.ensureDefaultLibrary() which became dynamic in
        // March 2026 when wine-staging 11.5 changed WoW64 filesystem redirection.
        let isX86 = steamInstallDir.path(percentEncoded: false).contains("Program Files (x86)")
        let defaultWinPath = isX86
            ? "C:\\\\Program Files (x86)\\\\Steam"
            : "C:\\\\Program Files\\\\Steam"
        if let existing = try? String(contentsOf: vdfURL, encoding: .utf8),
           existing.contains(defaultWinPath) { return }
        let vdf = """
        "libraryfolders"
        {
        \t"0"
        \t{
        \t\t"path"\t\t"\(defaultWinPath)"
        \t\t"label"\t\t""
        \t\t"contentid"\t\t"0"
        \t\t"totalsize"\t\t"0"
        \t\t"update_clean_bytes_tally"\t\t"0"
        \t\t"time_last_update_corruption"\t\t"0"
        \t\t"apps"
        \t\t{
        \t\t}
        \t}
        }
        """
        try vdf.write(to: vdfURL, atomically: true, encoding: .utf8)
    }

    /// Mirrors WinePrefix.steamInstallDir
    ///
    /// Detects the actual Steam install directory by checking which path contains
    /// a Steam executable. Under wine-staging 11.5, WoW64 filesystem redirection
    /// is not applied to 32-bit installers, so SteamSetup.exe /S writes to
    /// `Program Files\Steam` (64-bit path) instead of `Program Files (x86)\Steam`.
    /// Falls back to the x86 path when Steam is not yet installed.
    ///
    /// Source: WinePrefix.steamInstallDir (WinePrefix.swift)
    /// ⚠️  Must be updated whenever WinePrefix.steamInstallDir changes.
    private func steamInstallDir(driveC: URL) -> URL {
        let x64 = driveC.appending(path: "Program Files/Steam")
        let x86 = driveC.appending(path: "Program Files (x86)/Steam")
        // macOS APFS is case-insensitive: matches "Steam.exe" and "steam.exe"
        if FileManager.default.fileExists(atPath: x64.appending(path: "steam.exe").path(percentEncoded: false)) {
            return x64
        }
        return x86
    }

    /// Mirrors WinePrefix.steamExeWindowsPath
    ///
    /// Returns the Windows-style path to steam.exe based on the actual install
    /// location. Must use a Windows path — explorer.exe does not translate Unix
    /// paths for child processes.
    ///
    /// Source: WinePrefix.steamExeWindowsPath (WinePrefix.swift)
    /// ⚠️  Must be updated whenever WinePrefix.steamExeWindowsPath changes.
    private func steamExeWindowsPath(driveC: URL) -> String {
        let installDir = steamInstallDir(driveC: driveC)
        let isX86 = installDir.path(percentEncoded: false).contains("Program Files (x86)")
        if isX86 {
            return "C:\\Program Files (x86)\\Steam\\steam.exe"
        }
        return "C:\\Program Files\\Steam\\steam.exe"
    }

    /// Mirrors WinePrefix.ensureSteamCFG
    private func ensureSteamCFG(steamInstallDir: URL) throws {
        let fm = FileManager.default
        let cfgURL = steamInstallDir.appending(path: "steam.cfg")
        if let existing = try? String(contentsOf: cfgURL, encoding: .utf8),
           existing.contains("SteamNoSandbox=1") { return }
        try fm.createDirectory(at: steamInstallDir, withIntermediateDirectories: true)
        try "SteamNoSandbox=1".write(to: cfgURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Temp directory setup

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "MeridianTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    /// Builds a minimal Steam install dir structure and returns (steamInstallDir, driveC).
    private func makePrefix() throws -> (steam: URL, driveC: URL) {
        let driveC = tempDir.appending(path: "drive_c")
        let steam = driveC.appending(path: "Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
        return (steam, driveC)
    }

    // MARK: - VDF key-value parsing

    func testVdfKeyValue_parsesNormalLine() {
        let result = vdfKeyValue(from: "\t\"AccountName\"\t\t\"testuser\"")
        XCTAssertEqual(result?.key, "AccountName")
        XCTAssertEqual(result?.value, "testuser")
    }

    func testVdfKeyValue_parsesPathKey() {
        let result = vdfKeyValue(from: "\t\t\"path\"\t\t\"C:\\\\Program Files (x86)\\\\Steam\"")
        XCTAssertEqual(result?.key, "path")
        XCTAssertEqual(result?.value, "C:\\\\Program Files (x86)\\\\Steam")
    }

    func testVdfKeyValue_returnsNilForNonQuotedLine() {
        XCTAssertNil(vdfKeyValue(from: "// comment"))
        XCTAssertNil(vdfKeyValue(from: "{"))
        XCTAssertNil(vdfKeyValue(from: ""))
    }

    func testVdfKeyValue_returnsNilWhenValueMissing() {
        XCTAssertNil(vdfKeyValue(from: "\t\"keyonly\""))
    }

    // MARK: - hasSteamLoginSession

    func testHasSteamLoginSession_falseWhenNoFile() throws {
        let (steam, _) = try makePrefix()
        let configDir = steam.appending(path: "config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        XCTAssertFalse(hasSteamLoginSession(configDir: configDir))
    }

    func testHasSteamLoginSession_falseWhenEmptyFile() throws {
        let (steam, _) = try makePrefix()
        let configDir = steam.appending(path: "config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try "".write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        XCTAssertFalse(hasSteamLoginSession(configDir: configDir))
    }

    func testHasSteamLoginSession_trueWithMostRecentFlag() throws {
        let (steam, _) = try makePrefix()
        let configDir = steam.appending(path: "config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let vdf = """
        "users"
        {
            "76561198047018335"
            {
                "AccountName"   "testuser"
                "MostRecent"    "1"
            }
        }
        """
        try vdf.write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        XCTAssertTrue(hasSteamLoginSession(configDir: configDir))
    }

    func testHasSteamLoginSession_falseWhenMostRecentIsZero() throws {
        let (steam, _) = try makePrefix()
        let configDir = steam.appending(path: "config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let vdf = """
        "users"
        {
            "76561198047018335"
            {
                "AccountName"   "testuser"
                "MostRecent"    "0"
            }
        }
        """
        try vdf.write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        XCTAssertFalse(hasSteamLoginSession(configDir: configDir),
                       "MostRecent=0 must return false even when the file contains other \"1\" chars (e.g. in the SteamID)")
    }

    /// Regression test: MostRecent "0" with RememberPassword "1" must NOT false-positive.
    /// This was the exact bug that prevented re-authentication after the platform_type fix:
    /// the old global `contains("\"1\"")` matched RememberPassword instead of MostRecent.
    func testHasSteamLoginSession_falseWhenMostRecentZeroWithRememberPasswordOne() throws {
        let (steam, _) = try makePrefix()
        let configDir = steam.appending(path: "config")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let vdf = """
        "users"
        {
        \t"76561198047018335"
        \t{
        \t\t"AccountName"\t\t"nickjack876"
        \t\t"PersonaName"\t\t"nickjack876"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"0"
        \t\t"Timestamp"\t\t"1774737659"
        \t}
        }
        """
        try vdf.write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        XCTAssertFalse(hasSteamLoginSession(configDir: configDir),
                       "MostRecent=0 with RememberPassword=1 must return false — the old global contains check false-positived here")
    }

    // MARK: - isGameInstalled / acfURL

    func testIsGameInstalled_falseWhenNoSteamappsDir() throws {
        let (steam, driveC) = try makePrefix()
        XCTAssertFalse(isGameInstalled(appID: 730, steamInstallDir: steam, prefixDriveC: driveC))
    }

    func testIsGameInstalled_falseWhenSteamappsExistsButNoACF() throws {
        let (steam, driveC) = try makePrefix()
        try FileManager.default.createDirectory(
            at: steam.appending(path: "steamapps"), withIntermediateDirectories: true)
        XCTAssertFalse(isGameInstalled(appID: 730, steamInstallDir: steam, prefixDriveC: driveC))
    }

    func testIsGameInstalled_trueWhenACFExists() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try "".write(to: steamapps.appending(path: "appmanifest_730.acf"), atomically: true, encoding: .utf8)
        XCTAssertTrue(isGameInstalled(appID: 730, steamInstallDir: steam, prefixDriveC: driveC))
    }

    func testIsGameInstalled_falseForDifferentAppID() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try "".write(to: steamapps.appending(path: "appmanifest_730.acf"), atomically: true, encoding: .utf8)
        XCTAssertFalse(isGameInstalled(appID: 570, steamInstallDir: steam, prefixDriveC: driveC))
    }

    // MARK: - gameInstallDir

    func testGameInstallDir_returnsNilWhenNoACF() throws {
        let (steam, driveC) = try makePrefix()
        XCTAssertNil(gameInstallDir(appID: 730, steamInstallDir: steam, prefixDriveC: driveC))
    }

    func testGameInstallDir_parsesInstalldirFromACF() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let acf = """
        "AppState"
        {
            "appid"         "730"
            "name"          "Counter-Strike 2"
            "installdir"    "Counter-Strike 2"
            "StateFlags"    "4"
        }
        """
        try acf.write(to: steamapps.appending(path: "appmanifest_730.acf"), atomically: true, encoding: .utf8)
        let dir = gameInstallDir(appID: 730, steamInstallDir: steam, prefixDriveC: driveC)
        XCTAssertEqual(dir, "Counter-Strike 2")
    }

    func testGameInstallDir_returnsNilWhenInstalldirMissing() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let acf = """
        "AppState"
        {
            "appid"   "730"
            "name"    "Counter-Strike 2"
        }
        """
        try acf.write(to: steamapps.appending(path: "appmanifest_730.acf"), atomically: true, encoding: .utf8)
        XCTAssertNil(gameInstallDir(appID: 730, steamInstallDir: steam, prefixDriveC: driveC))
    }

    // MARK: - steamLibraryFolders / libraryfolders.vdf parsing

    func testSteamLibraryFolders_defaultOnlyWhenNoVdf() throws {
        let (steam, driveC) = try makePrefix()
        let folders = steamLibraryFolders(steamInstallDir: steam, prefixDriveC: driveC)
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders[0].standardizedFileURL, steam.standardizedFileURL)
    }

    func testSteamLibraryFolders_parsesNewPathKeyFormat() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        // New format: "path" key with Windows path
        let secondaryWinPath = "C:\\\\Games\\\\SteamLibrary"
        let vdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"    "C:\\\\Program Files (x86)\\\\Steam"
            }
            "1"
            {
                "path"    "\(secondaryWinPath)"
            }
        }
        """
        try vdf.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let folders = steamLibraryFolders(steamInstallDir: steam, prefixDriveC: driveC)
        // Should have default + one additional
        XCTAssertEqual(folders.count, 2)
        XCTAssertEqual(folders[0].standardizedFileURL, steam.standardizedFileURL)
        // Second should be the secondary path resolved inside driveC
        let expectedSecondary = driveC.appending(path: "Games/SteamLibrary")
        XCTAssertEqual(folders[1].standardizedFileURL, expectedSecondary.standardizedFileURL)
    }

    func testSteamLibraryFolders_parsesLegacyNumericFormat() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        // Legacy format: numeric key with Windows path value
        let legacyVdf = """
        "LibraryFolders"
        {
            "TimeNextStatsReport"    "0"
            "ContentStatsID"         "0"
            "1"    "C:\\\\Games\\\\SteamLibrary"
        }
        """
        try legacyVdf.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let folders = steamLibraryFolders(steamInstallDir: steam, prefixDriveC: driveC)
        XCTAssertEqual(folders.count, 2)
        let expected = driveC.appending(path: "Games/SteamLibrary")
        XCTAssertEqual(folders[1].standardizedFileURL, expected.standardizedFileURL)
    }

    func testSteamLibraryFolders_doesNotDuplicateDefaultLibrary() throws {
        let (steam, driveC) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        // VDF that only references the default library path
        let vdf = """
        "libraryfolders"
        {
            "0"
            {
                "path"    "C:\\\\Program Files (x86)\\\\Steam"
            }
        }
        """
        try vdf.write(to: steamapps.appending(path: "libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let folders = steamLibraryFolders(steamInstallDir: steam, prefixDriveC: driveC)
        // Should deduplicate: default library appears only once
        XCTAssertEqual(folders.count, 1)
    }

    // MARK: - ensureDefaultLibrary

    func testEnsureDefaultLibrary_createsSteamappsDir() throws {
        let (steam, _) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        XCTAssertFalse(FileManager.default.fileExists(atPath: steamapps.path(percentEncoded: false)))

        try ensureDefaultLibrary(steamInstallDir: steam)

        XCTAssertTrue(FileManager.default.fileExists(atPath: steamapps.path(percentEncoded: false)))
    }

    func testEnsureDefaultLibrary_writesLibraryFoldersVdf() throws {
        let (steam, _) = try makePrefix()
        try ensureDefaultLibrary(steamInstallDir: steam)

        let vdfURL = steam.appending(path: "steamapps/libraryfolders.vdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vdfURL.path(percentEncoded: false)))

        let content = try String(contentsOf: vdfURL, encoding: .utf8)
        XCTAssertTrue(content.contains("libraryfolders"))
        XCTAssertTrue(content.contains("C:\\\\Program Files (x86)\\\\Steam"))
    }

    func testEnsureDefaultLibrary_isIdempotent() throws {
        let (steam, _) = try makePrefix()
        try ensureDefaultLibrary(steamInstallDir: steam)

        let vdfURL = steam.appending(path: "steamapps/libraryfolders.vdf")
        let firstContents = try String(contentsOf: vdfURL, encoding: .utf8)

        // Second call should not alter the file
        try ensureDefaultLibrary(steamInstallDir: steam)
        let secondContents = try String(contentsOf: vdfURL, encoding: .utf8)
        XCTAssertEqual(firstContents, secondContents)
    }

    func testEnsureDefaultLibrary_doesNotOverwriteCustomVdf() throws {
        let (steam, _) = try makePrefix()
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        // Pre-existing VDF that already has the default path
        let existing = """
        "libraryfolders"
        {
            "0"
            {
                "path"    "C:\\\\Program Files (x86)\\\\Steam"
                "totalsize"    "512000000000"
            }
        }
        """
        let vdfURL = steamapps.appending(path: "libraryfolders.vdf")
        try existing.write(to: vdfURL, atomically: true, encoding: .utf8)

        try ensureDefaultLibrary(steamInstallDir: steam)

        let afterContents = try String(contentsOf: vdfURL, encoding: .utf8)
        // Should preserve the custom totalsize entry
        XCTAssertTrue(afterContents.contains("512000000000"))
    }

    func testEnsureDefaultLibrary_makesGamesDetectable() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 730

        // Verify game is not detectable before library setup
        XCTAssertFalse(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC))

        // Set up library
        try ensureDefaultLibrary(steamInstallDir: steam)

        // Place a fake ACF manifest
        let steamapps = steam.appending(path: "steamapps")
        try "".write(to: steamapps.appending(path: "appmanifest_\(appID).acf"), atomically: true, encoding: .utf8)

        // Now game should be detectable
        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC))
    }

    // MARK: - windowsPathToURL

    func testWindowsPathToURL_convertsCDrive() throws {
        let (_, driveC) = try makePrefix()
        let url = windowsPathToURL("C:\\\\Games\\\\SteamLibrary", driveC: driveC)
        XCTAssertNotNil(url)
        let expected = driveC.appending(path: "Games/SteamLibrary")
        XCTAssertEqual(url?.standardizedFileURL, expected.standardizedFileURL)
    }

    func testWindowsPathToURL_returnsNilForEmptyPath() throws {
        let (_, driveC) = try makePrefix()
        XCTAssertNil(windowsPathToURL("", driveC: driveC))
        XCTAssertNil(windowsPathToURL("X", driveC: driveC))
    }

    // MARK: - isGameFullyInstalled

    /// Mirrors WinePrefix.isGameFullyInstalled — checks ACF StateFlags == "4"
    private func isGameFullyInstalled(appID: Int, steamInstallDir: URL, prefixDriveC: URL) -> Bool {
        let fm = FileManager.default
        for library in steamLibraryFolders(steamInstallDir: steamInstallDir, prefixDriveC: prefixDriveC) {
            let acf = library.appending(path: "steamapps/appmanifest_\(appID).acf")
            guard fm.fileExists(atPath: acf.path(percentEncoded: false)),
                  let contents = try? String(contentsOf: acf, encoding: .utf8) else { continue }
            for line in contents.components(separatedBy: "\n") {
                if let (key, value) = vdfKeyValue(from: line), key == "StateFlags" {
                    return value == "4"
                }
            }
        }
        return false
    }

    func testIsGameFullyInstalled_returnsTrueWhenStateFlagsIsFour() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 220
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        let acf = """
        "AppState"
        {
        \t"appid"\t\t"220"
        \t"name"\t\t"Half-Life 2"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"Half-Life 2"
        }
        """
        try acf.write(to: steamapps.appending(path: "appmanifest_\(appID).acf"), atomically: true, encoding: .utf8)

        XCTAssertTrue(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "StateFlags=4 should mean fully installed")
    }

    func testIsGameFullyInstalled_returnsFalseWhenDownloadingInProgress() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 730
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        // StateFlags 1026 = download queued/in-progress (install confirmed but not complete)
        let acf = """
        "AppState"
        {
        \t"appid"\t\t"730"
        \t"name"\t\t"Counter-Strike 2"
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t"Counter-Strike 2"
        \t"BytesToDownload"\t\t"30000000000"
        \t"BytesDownloaded"\t\t"1000000"
        }
        """
        try acf.write(to: steamapps.appending(path: "appmanifest_\(appID).acf"), atomically: true, encoding: .utf8)

        // isGameInstalled should still be true (ACF exists)
        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "ACF exists so isGameInstalled should be true")
        // but isGameFullyInstalled must be false (download not complete)
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "StateFlags=1026 means download in progress, not fully installed")
    }

    // MARK: - Install flow / ensureDefaultLibrary pre-conditions

    /// Validates that `steamInstallDir` is always searched for ACFs regardless of
    /// whether `libraryfolders.vdf` exists. This is the fallback that makes
    /// `isGameInstalled` work even before `ensureDefaultLibrary` is called.
    func testIsGameInstalled_detectsAcfInDefaultDirWithoutLibraryFoldersVdf() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 3180070

        // No libraryfolders.vdf — Steam has not written it yet
        let steamapps = steam.appending(path: "steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)

        XCTAssertFalse(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "No ACF — should not be detected as installed")

        // Place ACF directly in default steamapps/
        try "".write(to: steamapps.appending(path: "appmanifest_\(appID).acf"),
                     atomically: true, encoding: .utf8)

        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "ACF in default steamapps/ must be found even without libraryfolders.vdf")
    }

    /// Verifies that `ensureDefaultLibrary` writes the exact Windows-format path
    /// that Steam uses when processing `steam.exe -install <appID>` via IPC.
    ///
    /// Steam's install IPC command uses `libraryfolders.vdf` to determine where to
    /// write the ACF. An incorrect or missing path causes Steam to show a
    /// library-location picker; under Meridian's window suppression that picker
    /// is hidden and the install silently never completes.
    func testEnsureDefaultLibrary_containsCorrectWindowsPath() throws {
        let (steam, _) = try makePrefix()
        try ensureDefaultLibrary(steamInstallDir: steam)

        let vdfURL = steam.appending(path: "steamapps/libraryfolders.vdf")
        let content = try String(contentsOf: vdfURL, encoding: .utf8)

        // The path must be the canonical Windows C: path that Steam writes into
        // its own libraryfolders.vdf on first interactive login. IPC `-install`
        // matches against this exact string.
        XCTAssertTrue(content.contains("C:\\\\Program Files (x86)\\\\Steam"),
                      "libraryfolders.vdf must contain the canonical Windows Steam path")
    }

    /// Regression test for the bug where `+app_install` (console command) was used
    /// instead of `-install` (IPC flag).
    ///
    /// This test exercises the full install-detection loop: once Steam creates the
    /// ACF after the user clicks Install in the `-install` dialog, `isGameInstalled`
    /// transitions from false to true and `isGameFullyInstalled` correctly stays
    /// false until the download completes (StateFlags == 4).
    func testInstallFlowStateProgression() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 3180070
        try ensureDefaultLibrary(steamInstallDir: steam)

        let steamapps = steam.appending(path: "steamapps")
        let acfURL = steamapps.appending(path: "appmanifest_\(appID).acf")

        // Phase 1: before user confirms install dialog — no ACF yet
        XCTAssertFalse(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "Phase 1: ACF must not exist before user confirms install")
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "Phase 1: game must not be fully installed before ACF exists")

        // Phase 2: user clicked Install — Steam wrote ACF with StateFlags=1026
        let downloadingACF = """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"No, I'm not a Human"
        \t"StateFlags"\t\t"1026"
        \t"installdir"\t\t"No, I'm not a Human"
        \t"BytesToDownload"\t\t"500000000"
        \t"BytesDownloaded"\t\t"0"
        }
        """
        try downloadingACF.write(to: acfURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "Phase 2: ACF present means install confirmed (isGameInstalled=true)")
        XCTAssertFalse(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "Phase 2: StateFlags=1026 download in progress — not fully installed")

        // Phase 3: download complete — Steam updated StateFlags to 4
        let installedACF = """
        "AppState"
        {
        \t"appid"\t\t"\(appID)"
        \t"name"\t\t"No, I'm not a Human"
        \t"StateFlags"\t\t"4"
        \t"installdir"\t\t"No, I'm not a Human"
        }
        """
        try installedACF.write(to: acfURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "Phase 3: game still detected as installed")
        XCTAssertTrue(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "Phase 3: StateFlags=4 means fully installed and ready to launch")
    }

    // MARK: - ensureSteamCFG (webhelper sandbox fix)

    /// Verifies that `ensureSteamCFG` creates `steam.cfg` in the Steam install dir.
    ///
    /// The webhelper (Steam's entire UI layer) crashes immediately under Wine because
    /// Chrome's sandbox fails to initialise. `SteamNoSandbox=1` in `steam.cfg` tells
    /// Steam to spawn the webhelper with `--no-sandbox --no-zygote`. Without this
    /// fix, Steam has no UI process, cannot show install dialogs, and cannot complete
    /// its authenticated login handshake.
    func testEnsureSteamCFG_createsSteamCFGFile() throws {
        let (steam, _) = try makePrefix()
        let cfgURL = steam.appending(path: "steam.cfg")

        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgURL.path(percentEncoded: false)),
                       "Pre-condition: steam.cfg must not exist before ensureSteamCFG")

        try ensureSteamCFG(steamInstallDir: steam)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cfgURL.path(percentEncoded: false)),
                      "ensureSteamCFG must create steam.cfg")
    }

    /// Verifies that `steam.cfg` contains `SteamNoSandbox=1`, the exact key Steam
    /// checks to pass `--no-sandbox --no-zygote` to the webhelper.
    func testEnsureSteamCFG_containsSteamNoSandbox() throws {
        let (steam, _) = try makePrefix()
        try ensureSteamCFG(steamInstallDir: steam)

        let cfgURL = steam.appending(path: "steam.cfg")
        let content = try String(contentsOf: cfgURL, encoding: .utf8)

        XCTAssertTrue(content.contains("SteamNoSandbox=1"),
                      "steam.cfg must contain SteamNoSandbox=1 to disable the webhelper sandbox")
    }

    /// Verifies that `ensureSteamCFG` is idempotent — calling it twice does not
    /// duplicate or corrupt the setting.
    func testEnsureSteamCFG_isIdempotent() throws {
        let (steam, _) = try makePrefix()
        try ensureSteamCFG(steamInstallDir: steam)
        try ensureSteamCFG(steamInstallDir: steam)

        let cfgURL = steam.appending(path: "steam.cfg")
        let content = try String(contentsOf: cfgURL, encoding: .utf8)
        let occurrences = content.components(separatedBy: "SteamNoSandbox=1").count - 1
        XCTAssertEqual(occurrences, 1, "SteamNoSandbox=1 must appear exactly once after two ensureSteamCFG calls")
    }

    /// Verifies that `ensureSteamCFG` does not overwrite a user-customised `steam.cfg`
    /// that already contains `SteamNoSandbox=1`, preserving any additional settings.
    func testEnsureSteamCFG_doesNotOverwriteExistingConfig() throws {
        let (steam, _) = try makePrefix()
        let cfgURL = steam.appending(path: "steam.cfg")

        let customConfig = "SteamNoSandbox=1\nSomeOtherSetting=2\n"
        try customConfig.write(to: cfgURL, atomically: true, encoding: .utf8)

        try ensureSteamCFG(steamInstallDir: steam)

        let afterContent = try String(contentsOf: cfgURL, encoding: .utf8)
        XCTAssertEqual(afterContent, customConfig,
                       "ensureSteamCFG must not modify steam.cfg when SteamNoSandbox=1 is already present")
    }

    /// Regression test: verifies that the webhelper-crash-caused install failure
    /// is correctly addressed by the combination of steam.cfg + libraryfolders.vdf.
    ///
    /// Without steam.cfg → webhelper crashes → no install dialog
    /// Without libraryfolders.vdf → hidden library picker → install hangs
    /// With both → install dialog appears and ACF is written when user clicks Install.
    func testWebhelperAndLibraryPrerequisites_enableInstallFlow() throws {
        let (steam, driveC) = try makePrefix()
        let appID = 3180070

        // Neither prerequisite file exists yet
        let cfgURL = steam.appending(path: "steam.cfg")
        let vdfURL = steam.appending(path: "steamapps/libraryfolders.vdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cfgURL.path(percentEncoded: false)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vdfURL.path(percentEncoded: false)))

        // Write both prerequisites (mirrors what bootstrap does in step 4b)
        try ensureSteamCFG(steamInstallDir: steam)
        try ensureDefaultLibrary(steamInstallDir: steam)

        // Both files must now exist
        XCTAssertTrue(FileManager.default.fileExists(atPath: cfgURL.path(percentEncoded: false)),
                      "steam.cfg must exist after setup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: vdfURL.path(percentEncoded: false)),
                      "libraryfolders.vdf must exist after setup")

        // Game is not yet installed — install flow starts here
        XCTAssertFalse(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                       "Game must not be installed before ACF is created")

        // Simulate Steam creating the ACF after user clicks Install
        let acfURL = steam.appending(path: "steamapps/appmanifest_\(appID).acf")
        try "\"AppState\"\n{\n\t\"appid\"\t\t\"\(appID)\"\n\t\"StateFlags\"\t\t\"4\"\n\t\"installdir\"\t\t\"TestGame\"\n}"
            .write(to: acfURL, atomically: true, encoding: .utf8)

        XCTAssertTrue(isGameInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "Game must be detected as installed once ACF is present")
        XCTAssertTrue(isGameFullyInstalled(appID: appID, steamInstallDir: steam, prefixDriveC: driveC),
                      "Game must be fully installed when StateFlags=4")
    }

    // MARK: - resetToEngineTemplate (regression tests)

    // These tests mirror the logic in WinePrefix.resetToEngineTemplate and verify
    // the three fixes: correct config file restore paths, z: dosdevice creation,
    // and syswow64 population.

    /// Simulates the resetToEngineTemplate operation using only FileManager calls
    /// (no Wine process). This mirrors the fixed implementation to catch regressions.
    private func simulateResetToEngineTemplate(
        prefix: URL,
        templateDir: URL,
        steamInstallDir: URL,
        engineI386Dir: URL
    ) throws -> (restoredConfigPaths: [String], dosdevices: [String], syswow64DLLs: [String]) {
        let fm = FileManager.default

        // Save Steam config files before wiping the prefix
        let configFilesToPreserve: [URL] = [
            steamInstallDir.appending(path: "config/loginusers.vdf"),
            steamInstallDir.appending(path: "config/config.vdf"),
        ]
        let savedConfigs: [(dest: URL, data: Data)] = configFilesToPreserve.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return (dest: url, data: data)
        }

        // Remove old prefix, copy new template
        try fm.removeItem(at: prefix)
        try fm.copyItem(at: templateDir, to: prefix)

        // Recreate dosdevices
        let dosdev = prefix.appending(path: "dosdevices")
        try? fm.removeItem(at: dosdev)
        try fm.createDirectory(at: dosdev, withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: dosdev.appending(path: "c:").path(percentEncoded: false),
            withDestinationPath: "../drive_c"
        )
        try fm.createSymbolicLink(
            atPath: dosdev.appending(path: "z:").path(percentEncoded: false),
            withDestinationPath: "/"
        )

        // Populate syswow64 — mirrors the fixed WinePrefix.resetToEngineTemplate logic.
        //
        // MIRROR CONTRACT: This block must stay in sync with WinePrefix.resetToEngineTemplate().
        // The critical fix (March 2026): do NOT guard on syswow64 already existing — instead
        // always createDirectory first. Wine 11.4 (CrossOver 27) does not create syswow64 during
        // wineboot --init, so templates built with it have no syswow64 directory. The old guard
        //   `if fileExists(i386Src) && fileExists(syswow64)`
        // silently skipped the entire population, causing SteamSetup.exe to exit 53 (kernel32 missing).
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")
        var wow64Copied: [String] = []
        if fm.fileExists(atPath: engineI386Dir.path(percentEncoded: false)) {
            try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            let i386Files = (try? fm.contentsOfDirectory(atPath: engineI386Dir.path(percentEncoded: false))) ?? []
            for file in i386Files where isWoW64FileType(file) {
                let dest = syswow64.appending(path: file)
                guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
                try? fm.copyItem(at: engineI386Dir.appending(path: file), to: dest)
                wow64Copied.append(file)
            }
        }

        // Restore saved config files to their original paths
        var restoredPaths: [String] = []
        for (dest, data) in savedConfigs {
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest)
            restoredPaths.append(dest.path(percentEncoded: false))
        }

        let dosdevContents = (try? fm.contentsOfDirectory(atPath: dosdev.path(percentEncoded: false))) ?? []
        return (
            restoredConfigPaths: restoredPaths,
            dosdevices: dosdevContents.sorted(),
            syswow64DLLs: wow64Copied.sorted()
        )
    }

    /// Builds a minimal fake "engine template" (an empty prefix structure) and
    /// a fake "engine i386" directory with stub DLLs for testing.
    private func makeEngineTemplate() throws -> (templateDir: URL, i386Dir: URL) {
        let engineDir  = tempDir.appending(path: "engine")
        let i386Dir    = engineDir.appending(path: "wine/lib/wine/i386-windows")
        let tmplDir    = engineDir.appending(path: "prefix-template")
        let syswow64   = tmplDir.appending(path: "drive_c/windows/syswow64")
        let system32   = tmplDir.appending(path: "drive_c/windows/system32")

        try FileManager.default.createDirectory(at: i386Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)

        // Stub 32-bit DLLs in the engine's i386 directory
        for dll in ["kernel32.dll", "ntdll.dll", "msvcrt.dll"] {
            try Data().write(to: i386Dir.appending(path: dll))
        }
        // system.reg is required by WinePrefix.exists — add it to the template too
        try "".write(to: tmplDir.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        return (tmplDir, i386Dir)
    }

    // MARK: - Regression: correct config file restore paths

    /// Regression test for the bug where config files were restored to the wrong path.
    ///
    /// The original implementation used `src.lastPathComponent` as the restore path,
    /// which wrote `loginusers.vdf` to `steamInstallDir/loginusers.vdf` instead of
    /// the correct `steamInstallDir/config/loginusers.vdf`. The fixed implementation
    /// writes back to the original `src` URL (same path, new prefix contents).
    func testResetToEngineTemplate_restoresConfigFilesToConfigSubdirectory() throws {
        let (tmplDir, i386Dir) = try makeEngineTemplate()

        // Build a prefix with an existing Steam install and saved login session
        let prefix = tempDir.appending(path: "prefix")
        let steamDir = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        let configDir = steamDir.appending(path: "config")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")
        let system32 = prefix.appending(path: "drive_c/windows/system32")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        try "".write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        let loginusersContent = """
        "users"
        {
        \t"12345"
        \t{
        \t\t"AccountName"\t\t"testuser"
        \t\t"MostRecent"\t\t"1"
        \t}
        }
        """
        let configContent = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t}
        }
        """
        try loginusersContent.write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        try configContent.write(to: configDir.appending(path: "config.vdf"), atomically: true, encoding: .utf8)

        // Simulate the reset
        let result = try simulateResetToEngineTemplate(
            prefix: prefix,
            templateDir: tmplDir,
            steamInstallDir: steamDir,
            engineI386Dir: i386Dir
        )

        // Verify restored config files land in the correct config/ subdirectory
        let fm = FileManager.default
        let restoredLoginusers = configDir.appending(path: "loginusers.vdf")
        let restoredConfig     = configDir.appending(path: "config.vdf")

        XCTAssertTrue(fm.fileExists(atPath: restoredLoginusers.path(percentEncoded: false)),
                      "loginusers.vdf must be restored to steamInstallDir/config/loginusers.vdf, not steamInstallDir/loginusers.vdf")
        XCTAssertTrue(fm.fileExists(atPath: restoredConfig.path(percentEncoded: false)),
                      "config.vdf must be restored to steamInstallDir/config/config.vdf, not steamInstallDir/config.vdf")

        // Verify content integrity
        let readBack = try String(contentsOf: restoredLoginusers, encoding: .utf8)
        XCTAssertEqual(readBack, loginusersContent, "loginusers.vdf content must be preserved exactly")

        // Verify the wrong paths do NOT exist
        let wrongLoginusers = steamDir.appending(path: "loginusers.vdf")
        let wrongConfig     = steamDir.appending(path: "config.vdf")
        XCTAssertFalse(fm.fileExists(atPath: wrongLoginusers.path(percentEncoded: false)),
                       "loginusers.vdf must NOT appear directly in steamInstallDir/ (regression: src.lastPathComponent bug)")
        XCTAssertFalse(fm.fileExists(atPath: wrongConfig.path(percentEncoded: false)),
                       "config.vdf must NOT appear directly in steamInstallDir/ (regression: src.lastPathComponent bug)")

        _ = result
    }

    // MARK: - Regression: z: dosdevice created by resetToEngineTemplate

    /// Regression test for the missing `z:` dosdevice in `resetToEngineTemplate`.
    ///
    /// The original implementation only created `c:` but omitted `z:`. Without `z:`,
    /// Wine cannot resolve absolute Unix paths (e.g. `/tmp/SteamSetup.exe`), causing
    /// any Wine process that receives a host-path argument to crash or silently exit.
    func testResetToEngineTemplate_createsBothCAndZDosdevices() throws {
        let (tmplDir, i386Dir) = try makeEngineTemplate()

        let prefix = tempDir.appending(path: "prefix2")
        let steamDir = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")

        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try "".write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        let result = try simulateResetToEngineTemplate(
            prefix: prefix,
            templateDir: tmplDir,
            steamInstallDir: steamDir,
            engineI386Dir: i386Dir
        )

        XCTAssertTrue(result.dosdevices.contains("c:"),
                      "c: dosdevice must be created by resetToEngineTemplate")
        XCTAssertTrue(result.dosdevices.contains("z:"),
                      "z: dosdevice must be created — required for Wine to resolve absolute Unix paths")

        // Verify c: is a symlink to ../drive_c
        let cLink = prefix.appending(path: "dosdevices/c:").path(percentEncoded: false)
        let cTarget = try FileManager.default.destinationOfSymbolicLink(atPath: cLink)
        XCTAssertEqual(cTarget, "../drive_c", "c: must be a relative symlink to ../drive_c")

        // Verify z: is a symlink to /
        let zLink = prefix.appending(path: "dosdevices/z:").path(percentEncoded: false)
        let zTarget = try FileManager.default.destinationOfSymbolicLink(atPath: zLink)
        XCTAssertEqual(zTarget, "/", "z: must be a symlink to / so Wine can access host paths")
    }

    // MARK: - Regression: syswow64 populated after engine template reset

    /// Regression test for the missing syswow64 population in `resetToEngineTemplate`.
    ///
    /// The original implementation replaced the prefix with the new template but did not
    /// copy 32-bit DLLs to `syswow64`. The Gcenx Wine builds leave syswow64 empty after
    /// `wineboot --init`, so the engine template also has an empty syswow64. Without
    /// the 32-bit DLLs, `SteamSetup.exe` (a 32-bit PE) crashes with STATUS_DLL_NOT_FOUND
    /// on the next `installSteam()` call that follows an engine upgrade.
    func testResetToEngineTemplate_populatesSyswow64FromEngineI386() throws {
        let (tmplDir, i386Dir) = try makeEngineTemplate()

        let prefix = tempDir.appending(path: "prefix3")
        let steamDir = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")

        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try "".write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        let result = try simulateResetToEngineTemplate(
            prefix: prefix,
            templateDir: tmplDir,
            steamInstallDir: steamDir,
            engineI386Dir: i386Dir
        )

        // All stub DLLs from i386Dir should now be in syswow64
        XCTAssertTrue(result.syswow64DLLs.contains("kernel32.dll"),
                      "kernel32.dll must be present in syswow64 after engine template reset")
        XCTAssertTrue(result.syswow64DLLs.contains("ntdll.dll"),
                      "ntdll.dll must be present in syswow64 after engine template reset")
        XCTAssertTrue(result.syswow64DLLs.contains("msvcrt.dll"),
                      "msvcrt.dll must be present in syswow64 after engine template reset")
        XCTAssertEqual(result.syswow64DLLs.count, 3,
                       "Exactly the 3 stub DLLs from i386Dir should have been copied")
    }

    // MARK: - Composite reset test

    /// Verifies all three reset invariants together: correct config paths, both
    /// dosdevices, and syswow64 population — in a single end-to-end simulation.
    func testResetToEngineTemplate_allInvariantsHoldTogether() throws {
        let (tmplDir, i386Dir) = try makeEngineTemplate()

        let prefix = tempDir.appending(path: "prefix4")
        let steamDir = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        let configDir = steamDir.appending(path: "config")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")

        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syswow64, withIntermediateDirectories: true)
        try "".write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        let loginContent = #""users" { "123" { "MostRecent" "1" } }"#
        try loginContent.write(to: configDir.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
        try #""cfg" {}"#.write(to: configDir.appending(path: "config.vdf"), atomically: true, encoding: .utf8)

        let result = try simulateResetToEngineTemplate(
            prefix: prefix,
            templateDir: tmplDir,
            steamInstallDir: steamDir,
            engineI386Dir: i386Dir
        )

        let fm = FileManager.default

        // 1. Config files restored to correct paths
        XCTAssertTrue(fm.fileExists(atPath: configDir.appending(path: "loginusers.vdf").path(percentEncoded: false)),
                      "loginusers.vdf must be at config/loginusers.vdf after reset")
        XCTAssertFalse(fm.fileExists(atPath: steamDir.appending(path: "loginusers.vdf").path(percentEncoded: false)),
                       "loginusers.vdf must NOT be at steamInstallDir/ root")

        // 2. Both dosdevices present
        XCTAssertTrue(result.dosdevices.contains("c:"))
        XCTAssertTrue(result.dosdevices.contains("z:"), "z: is required for WoW64 host-path resolution")

        // 3. syswow64 populated
        XCTAssertFalse(result.syswow64DLLs.isEmpty, "syswow64 must not be empty after engine reset")
    }
    // MARK: - steamInstallDir: dynamic path detection
    //
    // These tests exist to prevent a regression that occurred in March 2026:
    // wine-staging 11.5 changed WoW64 filesystem redirection, causing
    // SteamSetup.exe to install Steam to "Program Files\Steam" instead of
    // "Program Files (x86)\Steam". The hardcoded steamInstallDir caused the
    // bootstrap to launch a non-existent Windows path, leaving the UI spinning
    // at "Steam is updating" indefinitely.

    /// Steam is installed at the 64-bit path (wine-staging 11.5 and later).
    /// steamInstallDir must return Program Files/Steam.
    func testSteamInstallDir_returnsX64WhenSteamExeInProgramFiles() throws {
        let driveC = tempDir.appending(path: "drive_c")
        let x64 = driveC.appending(path: "Program Files/Steam")
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)
        // Place steam.exe (current installer uses capital-S on disk, but macOS APFS is
        // case-insensitive so "steam.exe" lookup finds "Steam.exe" and vice-versa)
        try Data().write(to: x64.appending(path: "steam.exe"))

        let result = steamInstallDir(driveC: driveC)
        XCTAssertTrue(result.path(percentEncoded: false).contains("Program Files/Steam"),
            "steamInstallDir must return the 64-bit path when steam.exe is there")
        XCTAssertFalse(result.path(percentEncoded: false).contains("Program Files (x86)"),
            "steamInstallDir must NOT return x86 path when steam.exe is at 64-bit location")
    }

    /// Steam is installed at the legacy x86 path (older Wine builds that correctly
    /// apply WoW64 filesystem redirection for 32-bit installers).
    func testSteamInstallDir_returnsX86WhenSteamExeInProgramFilesX86() throws {
        let driveC = tempDir.appending(path: "drive_c2")
        let x86 = driveC.appending(path: "Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: x86, withIntermediateDirectories: true)
        try Data().write(to: x86.appending(path: "steam.exe"))

        let result = steamInstallDir(driveC: driveC)
        XCTAssertTrue(result.path(percentEncoded: false).contains("Program Files (x86)"),
            "steamInstallDir must return the x86 path when steam.exe is there")
    }

    /// Steam is not yet installed (pre-install state, e.g. before SteamSetup.exe runs).
    /// Must fall back to the x86 path for pre-install writes like steam.cfg.
    func testSteamInstallDir_fallsBackToX86WhenNotInstalled() throws {
        let driveC = tempDir.appending(path: "drive_c3")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)

        let result = steamInstallDir(driveC: driveC)
        XCTAssertTrue(result.path(percentEncoded: false).contains("Program Files (x86)"),
            "steamInstallDir must fall back to x86 path before Steam is installed")
    }

    /// If both paths somehow have steam.exe, the 64-bit path takes priority.
    func testSteamInstallDir_prefersX64WhenBothPathsHaveSteamExe() throws {
        let driveC = tempDir.appending(path: "drive_c4")
        let x64 = driveC.appending(path: "Program Files/Steam")
        let x86 = driveC.appending(path: "Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: x86, withIntermediateDirectories: true)
        try Data().write(to: x64.appending(path: "steam.exe"))
        try Data().write(to: x86.appending(path: "steam.exe"))

        let result = steamInstallDir(driveC: driveC)
        XCTAssertTrue(result.path(percentEncoded: false).contains("Program Files/Steam") &&
                      !result.path(percentEncoded: false).contains("Program Files (x86)"),
            "steamInstallDir must prefer the x64 path when both locations have steam.exe")
    }

    // MARK: - steamExeWindowsPath: derives correct Windows path from install location

    /// After a wine-staging 11.5 install, the Windows path must be C:\Program Files\Steam\steam.exe
    func testSteamExeWindowsPath_returnsX64PathForNewInstall() throws {
        let driveC = tempDir.appending(path: "drive_c5")
        let x64 = driveC.appending(path: "Program Files/Steam")
        try FileManager.default.createDirectory(at: x64, withIntermediateDirectories: true)
        try Data().write(to: x64.appending(path: "steam.exe"))

        let result = steamExeWindowsPath(driveC: driveC)
        XCTAssertEqual(result, "C:\\Program Files\\Steam\\steam.exe",
            "Windows path must point to 64-bit install — bootstrap uses this for explorer.exe /desktop=")
    }

    /// For legacy installs (Steam at Program Files (x86)), the Windows path must use x86.
    func testSteamExeWindowsPath_returnsX86PathForLegacyInstall() throws {
        let driveC = tempDir.appending(path: "drive_c6")
        let x86 = driveC.appending(path: "Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: x86, withIntermediateDirectories: true)
        try Data().write(to: x86.appending(path: "steam.exe"))

        let result = steamExeWindowsPath(driveC: driveC)
        XCTAssertEqual(result, "C:\\Program Files (x86)\\Steam\\steam.exe",
            "Windows path must point to x86 install for legacy Steam locations")
    }

    /// When Steam is not installed, the Windows path must fall back to the x86 default.
    func testSteamExeWindowsPath_returnsX86FallbackWhenNotInstalled() throws {
        let driveC = tempDir.appending(path: "drive_c7")
        try FileManager.default.createDirectory(at: driveC, withIntermediateDirectories: true)

        let result = steamExeWindowsPath(driveC: driveC)
        XCTAssertEqual(result, "C:\\Program Files (x86)\\Steam\\steam.exe",
            "Windows path must fall back to x86 before Steam is installed")
    }

    // MARK: - ensureDefaultLibrary: VDF path must match actual install location

    /// Regression test for the March 2026 bug:
    /// When Steam installs to Program Files\Steam (wine-staging 11.5),
    /// libraryfolders.vdf must declare that path — not the old x86 path.
    /// A mismatch causes Steam to show a library-picker dialog that Meridian
    /// suppresses, making every install silently hang indefinitely.
    func testEnsureDefaultLibrary_writesX64WindowsPathForNewInstall() throws {
        let driveC = tempDir.appending(path: "drive_c8")
        let x64Steam = driveC.appending(path: "Program Files/Steam")
        try FileManager.default.createDirectory(at: x64Steam, withIntermediateDirectories: true)

        try ensureDefaultLibrary(steamInstallDir: x64Steam)

        let vdfURL = x64Steam.appending(path: "steamapps/libraryfolders.vdf")
        let content = try String(contentsOf: vdfURL, encoding: .utf8)

        XCTAssertTrue(content.contains("C:\\\\Program Files\\\\Steam"),
            "VDF must declare C:\\Program Files\\Steam for a 64-bit install")
        XCTAssertFalse(content.contains("Program Files (x86)"),
            "VDF must NOT reference Program Files (x86) for a 64-bit install — " +
            "a mismatch causes Steam to show a library picker that Meridian suppresses, " +
            "making every game install silently hang")
    }

    /// For legacy Steam installs at Program Files (x86), the VDF must use that path.
    func testEnsureDefaultLibrary_writesX86WindowsPathForLegacyInstall() throws {
        let driveC = tempDir.appending(path: "drive_c9")
        let x86Steam = driveC.appending(path: "Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: x86Steam, withIntermediateDirectories: true)

        try ensureDefaultLibrary(steamInstallDir: x86Steam)

        let vdfURL = x86Steam.appending(path: "steamapps/libraryfolders.vdf")
        let content = try String(contentsOf: vdfURL, encoding: .utf8)

        XCTAssertTrue(content.contains("Program Files (x86)"),
            "VDF must declare Program Files (x86) path for a legacy x86 install")
    }

    // MARK: - steamInstallDir + ensureDefaultLibrary: end-to-end path consistency

    /// The Windows path in libraryfolders.vdf must always be consistent with
    /// steamInstallDir and steamExeWindowsPath. This test verifies the three
    /// properties agree with each other for both x64 and x86 installs.
    func testSteamPaths_areConsistentAcrossAllThreeProperties() throws {
        for (label, subpath, expectX86) in [
            ("x64 install", "Program Files/Steam", false),
            ("x86 install", "Program Files (x86)/Steam", true),
        ] as [(String, String, Bool)] {
            let driveC = tempDir.appending(path: "drive_c_consistency_\(label.replacingOccurrences(of: " ", with: "_"))")
            let steamDir = driveC.appending(path: subpath)
            try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
            try Data().write(to: steamDir.appending(path: "steam.exe"))

            // steamInstallDir
            let detectedDir = steamInstallDir(driveC: driveC)
            XCTAssertEqual(detectedDir.path(percentEncoded: false), steamDir.path(percentEncoded: false),
                "[\(label)] steamInstallDir must detect the correct path")

            // steamExeWindowsPath
            let windowsPath = steamExeWindowsPath(driveC: driveC)
            let expectedWindowsPath = expectX86
                ? "C:\\Program Files (x86)\\Steam\\steam.exe"
                : "C:\\Program Files\\Steam\\steam.exe"
            XCTAssertEqual(windowsPath, expectedWindowsPath,
                "[\(label)] steamExeWindowsPath must match detectedDir")

            // ensureDefaultLibrary VDF content
            try ensureDefaultLibrary(steamInstallDir: steamDir)
            let vdfURL = steamDir.appending(path: "steamapps/libraryfolders.vdf")
            let vdfContent = try String(contentsOf: vdfURL, encoding: .utf8)
            let expectedVdfPath = expectX86 ? "Program Files (x86)" : "Program Files\\\\"
            XCTAssertTrue(vdfContent.contains(expectedVdfPath),
                "[\(label)] libraryfolders.vdf must reference the correct path")
        }
    }

    // MARK: - writeLoginUsers / writeConnectCache round-trips

    /// Mirror of WinePrefix.writeLoginUsers — writes loginusers.vdf
    private func writeLoginUsers(configDir: URL, steamID: String, accountName: String, personaName: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let vdf = """
        "users"
        {
        \t"\(steamID)"
        \t{
        \t\t"AccountName"\t\t"\(accountName)"
        \t\t"PersonaName"\t\t"\(personaName)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"\(timestamp)"
        \t}
        }
        """
        let dest = configDir.appending(path: "loginusers.vdf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
    }

    /// Mirror of WinePrefix.writeConnectCache — writes config.vdf
    private func writeConnectCache(configDir: URL, steamID: String, refreshToken: String, accountName: String) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let vdf = """
        "InstallConfigStore"
        {
        \t"Software"
        \t{
        \t\t"Valve"
        \t\t{
        \t\t\t"Steam"
        \t\t\t{
        \t\t\t\t"ConnectCache"
        \t\t\t\t{
        \t\t\t\t\t"\(steamID)"\t\t"\(refreshToken)"
        \t\t\t\t}
        \t\t\t\t"Accounts"
        \t\t\t\t{
        \t\t\t\t\t"\(accountName)"
        \t\t\t\t\t{
        \t\t\t\t\t\t"SteamID"\t\t"\(steamID)"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """
        let dest = configDir.appending(path: "config.vdf")
        try vdf.write(to: dest, atomically: true, encoding: .utf8)
    }

    func testWriteLoginUsers_createsMostRecentEntry() throws {
        let configDir = tempDir.appending(path: "write_login_test/config")
        try writeLoginUsers(configDir: configDir, steamID: "76561198000000000", accountName: "testuser", personaName: "TestPlayer")

        XCTAssertTrue(hasSteamLoginSession(configDir: configDir),
            "hasSteamLoginSession must be true after writeLoginUsers")
    }

    func testWriteLoginUsers_containsAccountName() throws {
        let configDir = tempDir.appending(path: "write_login_name_test/config")
        try writeLoginUsers(configDir: configDir, steamID: "76561198000000000", accountName: "myaccount", personaName: "MyName")

        let content = try String(contentsOf: configDir.appending(path: "loginusers.vdf"), encoding: .utf8)
        XCTAssertTrue(content.contains("\"myaccount\""))
        XCTAssertTrue(content.contains("\"MyName\""))
        XCTAssertTrue(content.contains("\"76561198000000000\""))
    }

    func testWriteConnectCache_containsRefreshToken() throws {
        let configDir = tempDir.appending(path: "write_cache_test/config")
        let token = "eyJhbGciOiJFZERTQSIsImtpZCI6IjEifQ.test_token"
        try writeConnectCache(configDir: configDir, steamID: "76561198000000000", refreshToken: token, accountName: "testuser")

        let content = try String(contentsOf: configDir.appending(path: "config.vdf"), encoding: .utf8)
        XCTAssertTrue(content.contains(token))
        XCTAssertTrue(content.contains("\"76561198000000000\""))
        XCTAssertTrue(content.contains("\"testuser\""))
    }

    func testWriteLoginUsers_thenHasSteamLoginSession_roundTrip() throws {
        let configDir = tempDir.appending(path: "roundtrip_test/config")

        XCTAssertFalse(hasSteamLoginSession(configDir: configDir),
            "Session should be absent before write")

        try writeLoginUsers(configDir: configDir, steamID: "76561198047018335", accountName: "nick", personaName: "Tra La La")

        XCTAssertTrue(hasSteamLoginSession(configDir: configDir),
            "Session should be present after write")
    }

    // MARK: - ensureSteamCFG: double-write idempotency

    func testEnsureSteamCFG_doubleWriteProducesSameContent() throws {
        let steamDir = tempDir.appending(path: "cfg_idempotent_test/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)

        try ensureSteamCFG(steamInstallDir: steamDir)
        let first = try String(contentsOf: steamDir.appending(path: "steam.cfg"), encoding: .utf8)

        try ensureSteamCFG(steamInstallDir: steamDir)
        let second = try String(contentsOf: steamDir.appending(path: "steam.cfg"), encoding: .utf8)

        XCTAssertEqual(first, second, "Two consecutive ensureSteamCFG calls must produce identical content")
    }

    // MARK: - ensureDefaultLibrary: double-write idempotency

    func testEnsureDefaultLibrary_doubleWriteProducesSameContent() throws {
        let steamDir = tempDir.appending(path: "lib_idempotent_test/Program Files/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)

        try ensureDefaultLibrary(steamInstallDir: steamDir)
        let first = try String(contentsOf: steamDir.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8)

        try ensureDefaultLibrary(steamInstallDir: steamDir)
        let second = try String(contentsOf: steamDir.appending(path: "steamapps/libraryfolders.vdf"), encoding: .utf8)

        XCTAssertEqual(first, second, "Two consecutive ensureDefaultLibrary calls must produce identical content")
    }

    // MARK: - Wine 11.4 regression: syswow64 created even when absent from template

    /// Builds a fake engine template WITHOUT a syswow64 directory — mimicking the
    /// output of `wineboot --init` under Wine 11.4 (CrossOver 27), which does not
    /// create syswow64 at all.
    private func makeEngineTemplateWithoutSyswow64() throws -> (templateDir: URL, i386Dir: URL) {
        let engineDir = tempDir.appending(path: "engine_wine11")
        let i386Dir   = engineDir.appending(path: "wine/lib/wine/i386-windows")
        let tmplDir   = engineDir.appending(path: "prefix-template")
        let system32  = tmplDir.appending(path: "drive_c/windows/system32")

        try FileManager.default.createDirectory(at: i386Dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: system32, withIntermediateDirectories: true)
        // NOTE: syswow64 is intentionally NOT created — this is the Wine 11.4 template layout

        for dll in ["kernel32.dll", "ntdll.dll", "user32.dll", "winemac.drv"] {
            try Data().write(to: i386Dir.appending(path: dll))
        }
        try "".write(to: tmplDir.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        return (tmplDir, i386Dir)
    }

    /// Regression test for the Wine 11.4 / CrossOver 27 exit-53 bug.
    ///
    /// Root cause: `wineboot --init` under Wine 11.4 does not create syswow64/.
    /// The old `resetToEngineTemplate` guarded on `syswow64` already existing, so
    /// the entire 32-bit DLL copy was silently skipped. SteamSetup.exe (32-bit PE)
    /// then exited 53 (STATUS_DLL_NOT_FOUND) because kernel32.dll was missing.
    ///
    /// This test ensures the fixed implementation creates syswow64/ even when absent.
    func testResetToEngineTemplate_createsSyswow64WhenAbsentFromTemplate_wine11Regression() throws {
        let (tmplDir, i386Dir) = try makeEngineTemplateWithoutSyswow64()

        // Build a prefix that will be reset — no syswow64 pre-existing
        let prefix = tempDir.appending(path: "prefix_wine11")
        let steamDir = prefix.appending(path: "drive_c/Program Files (x86)/Steam")
        try FileManager.default.createDirectory(at: steamDir, withIntermediateDirectories: true)
        try "".write(to: prefix.appending(path: "system.reg"), atomically: true, encoding: .utf8)

        // Confirm the template does NOT have syswow64 — this is the failure precondition
        let templateSyswow64 = tmplDir.appending(path: "drive_c/windows/syswow64")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: templateSyswow64.path(percentEncoded: false)),
            "Pre-condition: template must NOT have syswow64 to reproduce the Wine 11.4 regression"
        )

        let result = try simulateResetToEngineTemplate(
            prefix: prefix,
            templateDir: tmplDir,
            steamInstallDir: steamDir,
            engineI386Dir: i386Dir
        )

        // syswow64 must exist and be populated after the reset
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: syswow64.path(percentEncoded: false)),
            "syswow64/ must be CREATED by resetToEngineTemplate when absent from template — " +
            "Wine 11.4 regression: old code skipped syswow64 population entirely, causing exit 53"
        )
        XCTAssertTrue(
            result.syswow64DLLs.contains("kernel32.dll"),
            "kernel32.dll must be in syswow64 after reset — its absence causes SteamSetup.exe exit 53"
        )
        XCTAssertTrue(
            result.syswow64DLLs.contains("winemac.drv"),
            "winemac.drv must be in syswow64 — its absence causes nodrv_CreateWindow (exit 152)"
        )
    }

    /// Companion to the resetToEngineTemplate regression: verifies that create()
    /// (the fresh-prefix path) also creates syswow64 when absent.
    ///
    /// Mirrors WinePrefix.create() WoW64 population logic (the `if fm.fileExists(i386Src)` block).
    func testCreate_createsSyswow64WhenAbsentFromTemplate_wine11Regression() throws {
        let fm = FileManager.default

        // Fake engine i386 directory (simulates engine/wine/lib/wine/i386-windows)
        let fakeEngineI386 = tempDir.appending(path: "create_engine/wine/lib/wine/i386-windows")
        try fm.createDirectory(at: fakeEngineI386, withIntermediateDirectories: true)
        for dll in ["kernel32.dll", "ntdll.dll", "winemac.drv"] {
            try Data().write(to: fakeEngineI386.appending(path: dll))
        }

        // Simulate a fresh prefix that came from a Wine 11.4 template (no syswow64 dir)
        let prefixPath = tempDir.appending(path: "create_prefix_wine11")
        let system32 = prefixPath.appending(path: "drive_c/windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        // Intentionally do NOT create syswow64

        // Run the syswow64 population logic inline (mirrors WinePrefix.create WoW64 block)
        let syswow64 = prefixPath.appending(path: "drive_c/windows/syswow64")
        XCTAssertFalse(fm.fileExists(atPath: syswow64.path(percentEncoded: false)),
                       "Pre-condition: syswow64 must not exist")

        if fm.fileExists(atPath: fakeEngineI386.path(percentEncoded: false)) {
            try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            let files = (try? fm.contentsOfDirectory(atPath: fakeEngineI386.path(percentEncoded: false))) ?? []
            for file in files where isWoW64FileType(file) {
                let dest = syswow64.appending(path: file)
                guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
                try? fm.copyItem(at: fakeEngineI386.appending(path: file), to: dest)
            }
        }

        XCTAssertTrue(fm.fileExists(atPath: syswow64.path(percentEncoded: false)),
                      "syswow64/ must be created even when absent (Wine 11.4 regression)")
        XCTAssertTrue(fm.fileExists(atPath: syswow64.appending(path: "kernel32.dll").path(percentEncoded: false)),
                      "kernel32.dll must exist in syswow64 after create() population")
        XCTAssertTrue(fm.fileExists(atPath: syswow64.appending(path: "winemac.drv").path(percentEncoded: false)),
                      "winemac.drv must exist in syswow64 — required for 32-bit window creation")
    }

    /// Verifies graceful behaviour when engine has no i386-windows directory at all.
    /// The prefix creation must not crash; it just emits a warning log.
    func testSyswow64Population_gracefulWhenNoI386Source() throws {
        let fm = FileManager.default

        // Engine with no i386-windows (future Wine build without 32-bit support)
        let fakeEngineNoI386 = tempDir.appending(path: "engine_no_i386/wine/lib/wine")
        try fm.createDirectory(at: fakeEngineNoI386, withIntermediateDirectories: true)
        // i386-windows intentionally absent

        let prefixPath = tempDir.appending(path: "prefix_no_i386")
        let system32 = prefixPath.appending(path: "drive_c/windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        let syswow64 = prefixPath.appending(path: "drive_c/windows/syswow64")

        // Run population logic (should silently skip without crash)
        let i386Src = fakeEngineNoI386.appending(path: "i386-windows")
        if fm.fileExists(atPath: i386Src.path(percentEncoded: false)) {
            try? fm.createDirectory(at: syswow64, withIntermediateDirectories: true)
            // would copy files here if i386Src existed
        }
        // else: silently skip (logs warning in production)

        // syswow64 must NOT have been created (no i386 source = skip)
        XCTAssertFalse(fm.fileExists(atPath: syswow64.path(percentEncoded: false)),
                       "syswow64 must not be created when engine has no i386-windows directory")
    }

    // MARK: - isWoW64FileType (syswow64 population filter)

    /// Mirror of WinePrefix.isWoW64FileType(_:)
    private static let wow64Extensions: Set<String> = [
        "dll", "drv", "exe", "sys", "cpl", "ocx", "acm", "ax", "com",
    ]

    private func isWoW64FileType(_ filename: String) -> Bool {
        guard let dot = filename.lastIndex(of: ".") else { return false }
        let ext = String(filename[filename.index(after: dot)...]).lowercased()
        return Self.wow64Extensions.contains(ext)
    }

    func testIsWoW64FileType_acceptsDLL() {
        XCTAssertTrue(isWoW64FileType("kernel32.dll"))
        XCTAssertTrue(isWoW64FileType("NTDLL.DLL"))
    }

    func testIsWoW64FileType_acceptsDRV() {
        XCTAssertTrue(isWoW64FileType("winemac.drv"))
        XCTAssertTrue(isWoW64FileType("winspool.drv"))
        XCTAssertTrue(isWoW64FileType("msacm32.drv"))
    }

    func testIsWoW64FileType_acceptsEXE() {
        XCTAssertTrue(isWoW64FileType("explorer.exe"))
    }

    func testIsWoW64FileType_acceptsSYS() {
        XCTAssertTrue(isWoW64FileType("ndis.sys"))
    }

    func testIsWoW64FileType_acceptsOtherPETypes() {
        XCTAssertTrue(isWoW64FileType("test.cpl"))
        XCTAssertTrue(isWoW64FileType("test.ocx"))
        XCTAssertTrue(isWoW64FileType("test.acm"))
        XCTAssertTrue(isWoW64FileType("test.ax"))
        XCTAssertTrue(isWoW64FileType("test.com"))
    }

    func testIsWoW64FileType_rejectsNonPETypes() {
        XCTAssertFalse(isWoW64FileType("wine.inf"))
        XCTAssertFalse(isWoW64FileType("readme.txt"))
        XCTAssertFalse(isWoW64FileType("test.nls"))
        XCTAssertFalse(isWoW64FileType("test.tlb"))
        XCTAssertFalse(isWoW64FileType("test.msstyles"))
    }

    func testIsWoW64FileType_rejectsLegacy16BitTypes() {
        XCTAssertFalse(isWoW64FileType("test.dll16"))
        XCTAssertFalse(isWoW64FileType("test.drv16"))
        XCTAssertFalse(isWoW64FileType("test.exe16"))
    }

    func testIsWoW64FileType_rejectsNoExtension() {
        XCTAssertFalse(isWoW64FileType("noextension"))
    }

    func testIsWoW64FileType_caseInsensitive() {
        XCTAssertTrue(isWoW64FileType("WINEMAC.DRV"))
        XCTAssertTrue(isWoW64FileType("Kernel32.Dll"))
    }
}
