import XCTest

/// Guard tests for the OAuth refresh-token renewal + AccessDenied handling
/// (Pattern 23 / HANDOFF-2026-06-19-v6 / HANDOFF-2026-06-20).
///
/// The main target is an executable, so `@testable import` is unavailable.
/// These are source-scan guards that assert the renewal machinery exists and
/// is wired correctly. The classification LOGIC is exercised by the inlined
/// mirror below, kept in lock-step with
/// `SteamCredentialAuth.renewRefreshToken` (testing-standards mirror contract).
final class TokenRenewalTests: XCTestCase {

    // MARK: - Inlined mirror of renewRefreshToken's classification
    //
    // Mirror of SteamCredentialAuth.renewRefreshToken's decision table. The
    // real function performs the HTTPS call; this mirror takes the already-
    // parsed inputs (HTTP status, x-eresult header, rotated token, access
    // token) and applies the SAME classification rules. Keep in sync.

    private enum RenewalOutcome: Equatable {
        case renewed(String)
        case valid
        case invalid
        case accessDenied
        case networkError
    }

    /// Mirror of the classification in `renewRefreshToken`.
    private func classify(
        httpStatus: Int,
        xEResult: Int?,
        rotatedToken: String?,
        accessToken: String?,
        transportError: Bool = false
    ) -> RenewalOutcome {
        if transportError { return .networkError }
        if (500...599).contains(httpStatus) { return .networkError }
        if let rotated = rotatedToken, !rotated.isEmpty { return .renewed(rotated) }
        if let access = accessToken, !access.isEmpty { return .valid }
        if xEResult == 15 { return .accessDenied }
        return .invalid
    }

    // MARK: - Classification cases

    func testRenewRefreshToken_distinguishesAccessDeniedFromInvalid() {
        // Empty body + x-eresult 15 → AccessDenied (keep token, stay signed in).
        XCTAssertEqual(
            classify(httpStatus: 200, xEResult: 15, rotatedToken: nil, accessToken: nil),
            .accessDenied,
            "x-eresult 15 on an empty exchange must classify as .accessDenied, NOT .invalid — re-minting feeds the anti-abuse lockout (Pattern 23)."
        )
        // Empty body + any other eresult → genuinely dead token.
        XCTAssertEqual(
            classify(httpStatus: 200, xEResult: 63, rotatedToken: nil, accessToken: nil),
            .invalid,
            "Empty exchange with a non-15 eresult means the token is dead → re-auth."
        )
        XCTAssertEqual(
            classify(httpStatus: 200, xEResult: nil, rotatedToken: nil, accessToken: nil),
            .invalid,
            "Empty exchange with no eresult header must be treated as dead → re-auth."
        )
    }

    func testRenewRefreshToken_rotatedTokenIsRenewed() {
        XCTAssertEqual(
            classify(httpStatus: 200, xEResult: 1, rotatedToken: "NEWTOKEN", accessToken: "acc"),
            .renewed("NEWTOKEN"),
            "A rotated refresh_token in the body must be persisted via .renewed."
        )
    }

    func testRenewRefreshToken_accessTokenOnlyIsValid() {
        XCTAssertEqual(
            classify(httpStatus: 200, xEResult: 1, rotatedToken: nil, accessToken: "acc"),
            .valid,
            "An access_token with no rotation means the stored token is still valid."
        )
    }

    func testRenewRefreshToken_serverErrorsPreserveToken() {
        for status in [500, 502, 503, 599] {
            XCTAssertEqual(
                classify(httpStatus: status, xEResult: nil, rotatedToken: nil, accessToken: nil),
                .networkError,
                "HTTP \(status) must be .networkError so the token is preserved and retried."
            )
        }
        XCTAssertEqual(
            classify(httpStatus: 0, xEResult: nil, rotatedToken: nil, accessToken: nil, transportError: true),
            .networkError,
            "A transport error must be .networkError (offline-safe), never .invalid."
        )
    }

    // MARK: - Source-scan wiring guards

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    func testSteamCredentialAuth_declaresNonisolatedRenewRefreshToken() throws {
        let src = try readSource("Meridian/Steam/SteamCredentialAuth.swift")
        XCTAssertTrue(src.contains("nonisolated static func renewRefreshToken("),
                      "renewRefreshToken must be nonisolated static so startup + install paths can await it.")
        XCTAssertTrue(src.contains("case accessDenied"),
                      "RenewalOutcome must have an .accessDenied case distinct from .invalid (Pattern 23).")
        XCTAssertTrue(src.contains("x-eresult"),
                      "renewRefreshToken must read the x-eresult header — the authoritative AccessDenied signal.")
        XCTAssertTrue(src.contains("eresult == 15"),
                      "renewRefreshToken must branch on eresult 15 for AccessDenied.")
        XCTAssertTrue(src.contains("renewal_type"),
                      "The exchange request must send renewal_type=1 to allow token rotation.")
    }

    func testAuthService_accessDeniedDoesNotExpireSession() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        XCTAssertTrue(src.contains("func renewSessionIfNeeded()"),
                      "SteamAuthService must expose renewSessionIfNeeded().")
        XCTAssertTrue(src.contains("case .accessDenied"),
                      "renewSessionIfNeeded must handle .accessDenied explicitly.")
        XCTAssertTrue(src.contains("func markSessionExpired()"),
                      "SteamAuthService must expose markSessionExpired() for genuinely-dead tokens.")

        // The startup renewal switch must NOT call markSessionExpired in ANY
        // arm. Neither .accessDenied (EResult 15, Pattern 23) nor .invalid
        // (empty/ambiguous exchange body with a flapping eresult, July 2 2026)
        // is proof the token is dead — signing out here logged users out on
        // every launch with a valid session. The authoritative dead-token
        // signal is DepotDownloader exit 3 at the point of use.
        if let switchRange = src.range(of: "switch outcome {") {
            // Bound the window at whichever comes FIRST after the switch: the
            // next MARK or markSessionExpired's own declaration. (The function
            // is legitimately DEFINED right below the switch — only a CALL
            // inside the switch body is a regression.)
            let candidates = [
                src.range(of: "// MARK:", range: switchRange.upperBound..<src.endIndex),
                src.range(of: "func markSessionExpired", range: switchRange.upperBound..<src.endIndex),
            ].compactMap { $0 }
            if let endRange = candidates.min(by: { $0.lowerBound < $1.lowerBound }) {
                let switchBody = String(src[switchRange.upperBound..<endRange.lowerBound])
                XCTAssertFalse(switchBody.contains("markSessionExpired("),
                               "renewSessionIfNeeded's startup probe MUST NOT call markSessionExpired in any branch — an empty/ambiguous renewal response is not proof the token is dead; re-auth is driven by point-of-use failure (DepotDownloader exit 3).")
            }
        }
    }

    func testRestoreSession_rejectsIdentityWithoutRefreshToken() throws {
        // A Keychain steamID surviving while UserDefaults (refresh token) were
        // wiped produces a half-session: the app looks signed in but installs
        // and DRM launches fail. restoreSession must fail fast to the sign-in
        // sheet instead of restoring the broken state (observed July 2 2026:
        // full wipe left Keychain intact → no onboarding, install dead).
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        guard let fnRange = src.range(of: "private func restoreSession()") else {
            return XCTFail("SteamAuthService must declare restoreSession()")
        }
        let body = String(src[fnRange.lowerBound...].prefix(2200))
        XCTAssertTrue(body.contains("steamCredentialRefreshToken.isEmpty"),
                      "restoreSession must verify a refresh token exists before treating the Keychain identity as authenticated.")
        if let guardRange = body.range(of: "steamCredentialRefreshToken.isEmpty"),
           let authRange = body.range(of: "isAuthenticated = true") {
            XCTAssertTrue(guardRange.lowerBound < authRange.lowerBound,
                          "The refresh-token guard must run BEFORE isAuthenticated is set.")
        }
    }

    func testStartupRenewal_isKickedOffFromRestoreSession() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        // restoreSession should schedule the renewal.
        XCTAssertTrue(src.contains("renewSessionIfNeeded()"),
                      "restoreSession must kick off renewSessionIfNeeded() so the token is validated every cold start.")
    }

    func testInstallExit3_routesToReauth() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("refreshTokenInvalid"),
                      "Launcher must special-case DepotDownloader .refreshTokenInvalid (exit 3).")
        XCTAssertTrue(src.contains("meridianSteamSessionExpired"),
                      "Launcher must post .meridianSteamSessionExpired on a genuinely-dead token so the sheet re-appears.")
    }

    func testSessionExpiredNotification_isObservedByAuthService() throws {
        let src = try readSource("Meridian/Steam/SteamAuthService.swift")
        XCTAssertTrue(src.contains(".meridianSteamSessionExpired"),
                      "SteamAuthService must observe .meridianSteamSessionExpired to drive re-auth.")
    }
}
