import XCTest

/// Guard tests for Phase B1 — msync (Mach-semaphore NT-sync) enablement.
///
/// CX Wine ships marzent's msync patch. `WINEMSYNC=1` must be set on BOTH the
/// game env (`WineEngine.environment(for:)`) and the admin/steam.exe env
/// (`WineEngine.steamCMDEnvironment(for:)`) so every process attaching to the
/// shared wineserver agrees — the msync client aborts (`exit(1)`) if it
/// attaches to a wineserver started with a different msync setting.
final class MsyncEnvironmentTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testAppSettings_msyncDefaultsOn() throws {
        let src = try readSource("Meridian/Models/AppSettings.swift")
        XCTAssertTrue(src.contains("var msyncEnabled"),
                      "AppSettings must expose msyncEnabled.")
        // Absent-key default must be true (opt-out, not opt-in).
        XCTAssertTrue(src.contains(#"object(forKey: "msyncEnabled") == nil ? true"#),
                      "msyncEnabled must default to true when the key is unset.")
    }

    func testBothEnvBuildersSetWineMsyncConsistently() throws {
        let src = try readSource("Meridian/Engine/WineEngine.swift")

        // Both env builders must gate WINEMSYNC on the same setting.
        let occurrences = src.components(separatedBy: #"env["WINEMSYNC"] = "1""#).count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2,
            "WINEMSYNC=1 must be set in BOTH environment(for:) and steamCMDEnvironment(for:) so the shared wineserver is consistent (msync aborts on mismatch).")

        XCTAssertTrue(src.contains("settings.msyncEnabled"),
                      "Both env builders must gate WINEMSYNC on AppSettings.msyncEnabled.")
    }

    func testSettingsUI_exposesMsyncToggle() throws {
        let src = try readSource("Meridian/Views/Settings/SettingsView.swift")
        XCTAssertTrue(src.contains("settings.msyncEnabled"),
                      "SettingsView must expose the msync toggle.")
    }
}
