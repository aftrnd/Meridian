import XCTest

/// Source-invariant guards for SteamSessionBridge.
///
/// The main app target is an executable, so these tests read the production
/// source directly rather than importing it.
final class SteamSessionBridgeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testCredentialTokenStrategyWritesLocalVdfBeforeSelfManagedFallback() throws {
        let src = try readSource("Meridian/Steam/SteamSessionBridge.swift")

        XCTAssertTrue(
            src.contains("settings.hasSteamCredentials"),
            "SteamSessionBridge must prefer the durable persisted refresh token path when one is available."
        )
        XCTAssertTrue(
            src.contains("writeSteamSessionLocalVdf"),
            "SteamSessionBridge must rewrite DPAPI local.vdf from the persisted refresh token on launch."
        )
        XCTAssertTrue(
            src.contains("strategy=credentialAuth"),
            "A successfully written local.vdf should be reported as the credentialAuth strategy."
        )
        XCTAssertTrue(
            src.contains("settings.steamSelfManagedSession = false"),
            "SteamSessionBridge must clear the legacy self-managed flag once the durable token path is active."
        )
    }

    func testSelfManagedSessionWithoutLocalVdfClearsFlagAndFallsBack() throws {
        let src = try readSource("Meridian/Steam/SteamSessionBridge.swift")

        XCTAssertTrue(
            src.contains("steamSelfManaged session has no local.vdf after restore"),
            "SteamSessionBridge must detect a stale self-managed preference when local.vdf is missing after restore."
        )
        XCTAssertTrue(
            src.contains("settings.steamSelfManagedSession = false"),
            "SteamSessionBridge must clear steamSelfManagedSession when no usable on-disk Steam session exists."
        )
        XCTAssertTrue(
            src.contains("falling back to session discovery"),
            "SteamSessionBridge should fall through to macOS Steam/session discovery instead of pretending credentialAuth succeeded."
        )
    }
}
