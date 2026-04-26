import XCTest

/// Regression tests for `SteamExeSignIn`'s pure log-parsing logic.
///
/// MIRROR CONTRACT:
///   - `extractSteamID(from:)` mirrors `SteamExeSignIn.extractSteamID(from:)`.
///     Update both whenever Steam's `connection_log.txt` line format changes.
///
/// We mirror rather than `@testable import` because Meridian is an
/// executableTarget — see testing-standards.mdc → "Why Inlined Logic".
final class SteamExeSignInTests: XCTestCase {

    // MARK: - extractSteamID

    func testExtractSteamID_fromTypicalLogonLine() {
        let line = "[2026-04-25 18:07:15] [Logged On, 4, 7] [U:1:86752607] Logging on"
        XCTAssertEqual(extractSteamID(from: line), "76561198047018335")
    }

    func testExtractSteamID_picksLogonLine_notEarlyConnectingZero() {
        // Real connection_log starts with `[U:1:0]` lines (U:1:0 is the
        // "no user yet" placeholder Steam logs during the connect phase).
        // The parser must skip those and only read the U:1:N after `[Logged On, `.
        let log = """
        [2026-04-25 18:07:11] [Connecting, 4, 0] [U:1:0] PingWebSocketCM() starting...
        [2026-04-25 18:07:11] [Connecting, 4, 0] [U:1:0] Connect() starting connection
        [2026-04-25 18:07:15] [Connected, 4, 7] [U:1:0] Logging on [U:1:0]
        [2026-04-25 18:07:15] [Logged On, 4, 7] [U:1:86752607] Logging on
        [2026-04-25 18:07:15] [Logged On, 4, 7] [U:1:86752607] Some later line
        """
        XCTAssertEqual(extractSteamID(from: log), "76561198047018335")
    }

    func testExtractSteamID_returnsNil_whenNoLoggedOnLine() {
        let log = """
        [2026-04-25 18:07:11] [Connecting, 4, 0] [U:1:0] PingWebSocketCM() starting...
        [2026-04-25 18:07:11] [Connecting, 4, 0] [U:1:0] Connect() starting connection
        """
        XCTAssertNil(extractSteamID(from: log))
    }

    func testExtractSteamID_returnsNil_whenLoggedOnLineHasZeroAccount() {
        // Defensive: U:1:0 after Logged On would be Steam's anonymous placeholder.
        // Should return nil rather than producing the public-universe base value.
        let line = "[Logged On, 4, 7] [U:1:0] something"
        XCTAssertNil(extractSteamID(from: line))
    }

    // MARK: - Mirror of SteamExeSignIn.extractSteamID

    /// Mirror of `SteamExeSignIn.extractSteamID(from:)`. Update both together.
    private func extractSteamID(from log: String) -> String? {
        guard let logonRange = log.range(of: "[Logged On, ") else { return nil }
        let after = log[logonRange.upperBound...]
        guard let startIdx = after.range(of: "[U:1:") else { return nil }
        let tail = after[startIdx.upperBound...]
        var accountID: UInt64 = 0
        for ch in tail {
            if let d = ch.hexDigitValue, ch.isNumber {
                accountID = accountID * 10 + UInt64(d)
            } else {
                break
            }
        }
        guard accountID > 0 else { return nil }
        let steamID64 = accountID + 76561197960265728
        return String(steamID64)
    }
}
