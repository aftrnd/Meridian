import XCTest

/// Guard tests for Phase A3 — per-game Offline (gbe_fork) vs Online
/// (real steam.exe `-applaunch`) launch modes.
///
/// Offline is the default (proven, seamless, no cloud/multiplayer). Online is
/// an opt-in that brings the real Steam client online in the background so
/// cloud saves, online multiplayer, EULAs, and genuine DRM work.
final class LaunchModeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - AppSettings persistence contract

    func testAppSettings_defaultsToOfflineAndPersistsOnlineOptIn() throws {
        let src = try readSource("Meridian/Models/AppSettings.swift")
        XCTAssertTrue(src.contains("enum LaunchMode"),
                      "AppSettings must define a LaunchMode enum.")
        XCTAssertTrue(src.contains("case offline") && src.contains("case online"),
                      "LaunchMode must have offline + online cases.")
        XCTAssertTrue(src.contains("func launchMode(appID:"),
                      "AppSettings must expose launchMode(appID:).")
        XCTAssertTrue(src.contains("func setLaunchMode("),
                      "AppSettings must expose setLaunchMode(_:appID:).")
        // Default must be Offline: the getter returns .online ONLY when the
        // appID is in the opt-in set, else .offline.
        XCTAssertTrue(src.contains("onlineModeAppIDs.contains(appID) ? .online : .offline"),
                      "launchMode must default to .offline (Online is opt-in only).")
    }

    // MARK: - Launcher wiring

    func testLauncher_branchesOnLaunchMode() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("AppSettings.shared.launchMode(appID:"),
                      "Launcher must consult AppSettings.launchMode to pick Offline vs Online.")
        XCTAssertTrue(src.contains("func launchOnline("),
                      "Launcher must implement the Online-mode launch path.")
        XCTAssertTrue(src.contains("== .online"),
                      "Launcher must branch to Online when launchMode == .online.")
    }

    func testOnlineMode_usesSteamApplaunchNotGbeFork() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "func launchOnline(") else {
            return XCTFail("launchOnline must exist")
        }
        // Bound the search to the launchOnline body (up to the next `// MARK:`).
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(through: after.range(of: "// MARK:")?.lowerBound ?? after.endIndex))

        XCTAssertTrue(body.contains("ensureReadyForDRM"),
                      "Online mode must bring the real Steam client online via ensureReadyForDRM.")
        XCTAssertTrue(body.contains("launchGameViaSteam"),
                      "Online mode must dispatch -applaunch via session.launchGameViaSteam.")
        XCTAssertFalse(body.contains("installSteamEmulator"),
                       "Online mode must NOT install the gbe_fork shim — the game must talk to Valve, not a local emulator.")
        XCTAssertFalse(body.contains("launchDirect("),
                       "Online mode must NOT launchDirect — Steam owns the launch (avoids the custom-args dialog, Pattern 20).")
    }

    func testOfflineMode_remainsGbeForkDefault() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        // The default (non-online) path must still use the gbe_fork shim +
        // direct exec that is proven reliable today.
        XCTAssertTrue(src.contains("installSteamEmulator"),
                      "Offline (default) path must keep the gbe_fork Steamworks shim.")
        XCTAssertTrue(src.contains("launchDirect("),
                      "Offline (default) path must keep direct wine64 exec.")
    }

    // MARK: - UI toggle

    func testGameDetail_exposesLaunchModePicker() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("launchModeBinding"),
                      "GameDetailView must bind a launch-mode picker to AppSettings.")
        XCTAssertTrue(src.contains("AppSettings.LaunchMode.offline")
                      && src.contains("AppSettings.LaunchMode.online"),
                      "GameDetailView picker must offer both Offline and Online.")
    }
}
