import XCTest

/// Source-invariant guard tests for proactive OAuth refresh-token renewal and
/// the session-expiry re-auth fallback.
///
/// Background: installs run through the DepotDownloader fork authenticated by the
/// persisted OAuth `refresh_token`. That token was previously captured once at
/// sign-in and reused forever, so when Valve eventually rotated/expired it the
/// next install failed with `REFRESH_TOKEN_INVALID` and silently reverted to the
/// Install button. The fix renews the token on startup
/// (`SteamCredentialAuth.renewRefreshToken` → `GenerateAccessTokenForApp`) and,
/// when renewal genuinely fails, routes the user to re-auth instead of
/// dead-ending.
///
/// The `Meridian` target is an executableTarget (no `@testable import`), so these
/// read the production sources as text and assert the wiring/contract holds.
final class TokenRenewalTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - SteamCredentialAuth.renewRefreshToken

    func testRenewRefreshToken_usesGenerateAccessTokenEndpoint() throws {
        let src = try readSource("Meridian/Steam/SteamCredentialAuth.swift")
        XCTAssertTrue(src.contains("func renewRefreshToken("),
                      "SteamCredentialAuth must expose renewRefreshToken")
        XCTAssertTrue(src.contains("IAuthenticationService/GenerateAccessTokenForApp/v1/"),
                      "renewal must hit the GenerateAccessTokenForApp endpoint")
        // CLI-verified request shape: form POST steamid + refresh_token + renewal_type=1.
        XCTAssertTrue(src.contains("\"refresh_token\": refreshToken"),
                      "must send refresh_token form field")
        XCTAssertTrue(src.contains("\"renewal_type\":  \"1\"") || src.contains("\"renewal_type\": \"1\""),
                      "must request renewal_type=1 (Allow) so Valve rotates the token")
    }

    func testRenewRefreshToken_distinguishesNetworkFromInvalid() throws {
        let src = try readSource("Meridian/Steam/SteamCredentialAuth.swift")
        // Outcome enum must separate a dead token from a transient network failure
        // so callers never discard a good token while offline.
        XCTAssertTrue(src.contains("enum RenewalOutcome"),
                      "must define a RenewalOutcome")
        for outcome in ["case renewed(", "case valid", "case invalid", "case networkError("] {
            XCTAssertTrue(src.contains(outcome), "RenewalOutcome must include \(outcome)")
        }
        // 5xx / transport failures are networkError (token preserved); 200-empty
        // and other 4xx are invalid (token dead).
        XCTAssertTrue(src.contains("http.statusCode >= 500"),
                      "5xx must map to networkError, not invalid")
    }

    // MARK: - SteamAuthService startup renewal + expiry

    func testAuthService_renewsTokenOnStartup() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        XCTAssertTrue(src.contains("func renewSessionIfNeeded()"),
                      "SteamAuthService must expose renewSessionIfNeeded")
        XCTAssertTrue(src.contains("await renewSessionIfNeeded()"),
                      "restoreSession must kick off renewal at startup")
        XCTAssertTrue(src.contains("SteamCredentialAuth.renewRefreshToken("),
                      "renewSessionIfNeeded must call the renewal API")
    }

    func testAuthService_persistsRotatedToken() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        // On .renewed the new token MUST be persisted (extends lifetime).
        XCTAssertTrue(src.contains("case .renewed(let newToken):"),
                      "must handle the renewed outcome")
        XCTAssertTrue(src.contains("AppSettings.shared.steamCredentialRefreshToken = newToken"),
                      "must persist the rotated refresh token")
    }

    func testAuthService_networkErrorDoesNotExpireSession() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        // The .networkError branch must NOT call markSessionExpired — a transient
        // outage must never nuke a valid token. Verify the branch only logs.
        guard let range = src.range(of: "case .networkError(let msg):") else {
            return XCTFail("renewSessionIfNeeded must handle .networkError explicitly")
        }
        let tail = String(src[range.lowerBound...].prefix(220))
        XCTAssertFalse(tail.contains("markSessionExpired"),
                       "networkError must not expire the session (token state unknown)")
    }

    func testMarkSessionExpired_preservesApiKey() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        XCTAssertTrue(src.contains("func markSessionExpired()"),
                      "must expose markSessionExpired")
        guard let range = src.range(of: "func markSessionExpired()") else { return }
        let body = String(src[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("isAuthenticated = false"),
                      "markSessionExpired must drop isAuthenticated to surface the sheet")
        XCTAssertTrue(body.contains("steamCredentialRefreshToken = \"\""),
                      "markSessionExpired must clear the dead token")
        // Unlike signOut, it must NOT wipe the Web API key.
        XCTAssertFalse(body.contains("deleteSecret(key: KeychainKey.apiKey)"),
                       "markSessionExpired must preserve the API key (library keeps working)")
    }

    func testAuthService_observesSessionExpiredNotification() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        XCTAssertTrue(src.contains(".meridianSteamSessionExpired"),
                      "must observe the session-expired notification")
        XCTAssertTrue(src.contains("markSessionExpired()"),
                      "the observer must call markSessionExpired")
    }

    // MARK: - Launcher fallback on dead token

    func testLauncher_routesToReauthOnRefreshTokenInvalid() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("case .refreshTokenInvalid = dd"),
                      "Launcher must special-case DepotDownloader refreshTokenInvalid")
        XCTAssertTrue(src.contains("NotificationCenter.default.post(name: .meridianSteamSessionExpired"),
                      "Launcher must post the session-expired notification to trigger re-auth")
    }

    func testNotificationName_declared() throws {
        let src = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertTrue(src.contains("static let meridianSteamSessionExpired"),
                      "the session-expired notification name must be declared")
    }
}
