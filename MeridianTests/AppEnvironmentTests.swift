import XCTest
@testable import Meridian

/// Per-game environment variables (engine patch 0008, engine-research Pattern 56)
/// and the engine updater's rule that it never replaces a newer local engine.
final class AppEnvironmentTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - The .reg file

    /// The key is deleted first, so a variable the profile dropped does not
    /// linger, and each variable lands both as is (Windows side) and with
    /// `__CX_UNIX_` (Unix side, where Wine reads WINEDLLOVERRIDES).
    func testRegFileClearsTheKeyThenWritesBothForms() throws {
        let reg = WinePrefix.appEnvironmentRegFile(
            executable: "FarFarWest.exe", variables: ["DXMT_ENABLE_NVEXT": "1"]
        )
        let key = #"HKEY_CURRENT_USER\Software\Wine\AppDefaults\FarFarWest.exe\Environment"#
        XCTAssertTrue(reg.hasPrefix("\u{FEFF}Windows Registry Editor Version 5.00"))
        let delete = try XCTUnwrap(reg.range(of: "[-\(key)]"))
        let set = try XCTUnwrap(reg.range(of: "\r\n[\(key)]"))
        XCTAssertLessThan(delete.lowerBound, set.lowerBound)
        XCTAssertTrue(reg.contains(#""DXMT_ENABLE_NVEXT"="1""#))
        XCTAssertTrue(reg.contains(#""__CX_UNIX_DXMT_ENABLE_NVEXT"="1""#))
    }

    func testRegFileWithNoVariablesOnlyClearsTheKey() {
        let reg = WinePrefix.appEnvironmentRegFile(executable: "Game.exe", variables: [:])
        XCTAssertTrue(reg.contains(#"[-HKEY_CURRENT_USER\Software\Wine\AppDefaults\Game.exe\Environment]"#))
        XCTAssertFalse(reg.contains("\r\n[HKEY_CURRENT_USER"))
    }

    /// reg.exe round-tripped this value intact (CLI, Oct 20 2026).
    func testRegFileEscapesBackslashesAndQuotes() {
        let reg = WinePrefix.appEnvironmentRegFile(executable: "Game.exe", variables: ["X": #"a "b" C:\c"#])
        XCTAssertTrue(reg.contains(#""X"="a \"b\" C:\\c""#))
    }

    // MARK: - Launch wiring

    /// Steam starts the game with steam.exe's environment, so the game's own
    /// variables must be in the registry before the -applaunch dispatch.
    func testLauncherStoresTheGameEnvironmentBeforeLaunchingThroughSteam() throws {
        let source = try readSource("Meridian/Launch/Launcher.swift")
        let apply = try XCTUnwrap(source.range(of: "await applyGameEnvironment(for: game, session: session, engine: engine)"))
        let launch = try XCTUnwrap(source.range(of: "try session.launchGameViaSteam("))
        XCTAssertLessThan(apply.lowerBound, launch.lowerBound)
    }

    func testEngineCarriesThePerAppEnvironmentPatch() throws {
        let patch = try readSource("Scripts/engine/patches/wine/0008-kernelbase-per-app-environment.patch")
        XCTAssertTrue(patch.contains("create_app_environment"))
        XCTAssertTrue(patch.contains(#"L"Software\\Wine\\AppDefaults\\""#))
        XCTAssertTrue(patch.contains(#"L"\\Environment""#))
    }

    // MARK: - Engine updater

    /// A locally installed v4.1.1 was replaced by the v4.1.0 release on the
    /// next launch while the check was "tag differs" (Oct 20 2026).
    func testEngineUpdaterOnlyMovesToANewerRelease() {
        XCTAssertFalse(AppUpdateChecker.isNewerEngine("v4.1.0-engine", than: "v4.1.1-engine"))
        XCTAssertFalse(AppUpdateChecker.isNewerEngine("v4.1.0-engine", than: "v4.1.0-engine"))
        XCTAssertTrue(AppUpdateChecker.isNewerEngine("v4.2.0-engine", than: "v4.1.1-engine"))
        XCTAssertTrue(AppUpdateChecker.isNewerEngine("v4.1.10-engine", than: "v4.1.9-engine"))
    }

    func testEngineDownloaderSkipsUnlessTheReleaseIsNewer() throws {
        let source = try readSource("Meridian/Engine/EngineDownloader.swift")
        XCTAssertTrue(source.contains("!AppUpdateChecker.isNewerEngine(asset.releaseTag, than: installedTag)"))
        XCTAssertFalse(source.contains("installedTag == asset.releaseTag"))
    }
}
