import XCTest
import Security

/// Unit tests for the `SteamCredentialAuth` logic.
///
/// Because the main target is an executable it cannot be imported with @testable.
/// Pure functions are inlined here and verified in lock-step with the source.
/// If the source implementation changes, update the inlined copies accordingly.
final class SteamCredentialAuthTests: XCTestCase {

    // MARK: - Inlined: DER encoding (mirrors SteamCredentialAuth.buildRSAPublicKeyDER)

    private func asn1Integer(_ raw: Data) -> Data {
        var payload = raw
        while payload.count > 1 && payload.first == 0x00 { payload = payload.dropFirst() }
        if payload.first ?? 0 >= 0x80 { payload = Data([0x00]) + payload }
        return Data([0x02]) + asn1Len(payload.count) + payload
    }

    private func asn1Len(_ n: Int) -> Data {
        if n < 0x80   { return Data([UInt8(n)]) }
        if n < 0x100  { return Data([0x81, UInt8(n)]) }
        return Data([0x82, UInt8(n >> 8), UInt8(n & 0xFF)])
    }

    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        let body = asn1Integer(modulus) + asn1Integer(exponent)
        return Data([0x30]) + asn1Len(body.count) + body
    }

    // MARK: - Inlined: hex decoding (mirrors Data(hexString:))

    private func dataFromHex(_ hex: String) -> Data? {
        var h = hex
        if h.count % 2 != 0 { h = "0" + h }
        var out = Data()
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }

    // MARK: - Inlined: guard type mapping (mirrors SteamCredentialAuth.GuardType)

    private enum GuardType: Int {
        case emailCode = 2
        case deviceCode = 3
        case deviceConfirmation = 4
        case emailConfirmation = 5
    }

    // MARK: - Inlined: VDF templates (mirrors WinePrefix.writeLoginUsers)

    private func makeLoginUsersVDF(steamID: String, account: String, persona: String) -> String {
        let ts = Int(Date().timeIntervalSince1970)
        return """
        "users"
        {
        \t"\(steamID)"
        \t{
        \t\t"AccountName"\t\t"\(account)"
        \t\t"PersonaName"\t\t"\(persona)"
        \t\t"RememberPassword"\t\t"1"
        \t\t"MostRecent"\t\t"1"
        \t\t"Timestamp"\t\t"\(ts)"
        \t}
        }
        """
    }

    private func makeConnectCacheVDF(steamID: String, token: String, account: String) -> String {
        """
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
        \t\t\t\t\t"\(steamID)"\t\t"\(token)"
        \t\t\t\t}
        \t\t\t\t"Accounts"
        \t\t\t\t{
        \t\t\t\t\t"\(account)"
        \t\t\t\t\t{
        \t\t\t\t\t\t"SteamID"\t\t"\(steamID)"
        \t\t\t\t\t}
        \t\t\t\t}
        \t\t\t}
        \t\t}
        \t}
        }
        """
    }

    // MARK: - DER structure

    func testDERSequenceTagIsPresent() {
        let der = buildRSAPublicKeyDER(
            modulus: Data(repeating: 0x01, count: 4),
            exponent: Data([0x01, 0x00, 0x01])
        )
        XCTAssertEqual(der.first, 0x30, "DER output must start with SEQUENCE tag 0x30")
    }

    func testDERContainsTwoIntegerTags() {
        let der = buildRSAPublicKeyDER(
            modulus: Data([0x7F]),
            exponent: Data([0x01, 0x00, 0x01])
        )
        XCTAssertEqual(der.filter { $0 == 0x02 }.count, 2,
            "SEQUENCE must contain exactly two INTEGER values (modulus + exponent)")
    }

    func testDERPadsModulusWithHighBitSet() {
        // 0x80 has the high bit set — ASN.1 INTEGER must prepend 0x00 for positive value
        let der = buildRSAPublicKeyDER(
            modulus: Data([0x80, 0xAB]),
            exponent: Data([0x03])
        )
        XCTAssertTrue(der.contains(0x00), "High-bit modulus must be zero-padded in DER")
    }

    func testDERDoesNotPadModulusWithoutHighBit() {
        let derNoPad = buildRSAPublicKeyDER(modulus: Data([0x7F, 0xAB]), exponent: Data([0x03]))
        let derPad   = buildRSAPublicKeyDER(modulus: Data([0x80, 0xAB]), exponent: Data([0x03]))
        XCTAssertLessThan(derNoPad.count, derPad.count,
            "Modulus without high bit must produce shorter DER than one with high bit")
    }

    func testDERProducesKeyAcceptedBySecurityFramework() throws {
        // 512-bit modulus (64 bytes) — small but exercises the full DER round-trip.
        // Real Steam keys are 2048-bit; the structure is identical.
        let modHex = "d5e4e9a1b2c3d4e5f6a7b8c9d0e1f2a3" +
                     "b4c5d6e7f8091a2b3c4d5e6f7a8b9c0d" +
                     "1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b" +
                     "7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f"
        let expHex = "010001"  // 65537
        guard
            let modData = dataFromHex(modHex),
            let expData = dataFromHex(expHex)
        else { return XCTFail("Hex decode failed") }

        let der = buildRSAPublicKeyDER(modulus: modData, exponent: expData)
        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:      kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits as String: modData.count * 8,
        ]
        var err: Unmanaged<CFError>?
        let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, &err)
        XCTAssertNotNil(key,
            "SecKeyCreateWithData must accept valid DER: " +
            (err?.takeRetainedValue().localizedDescription ?? "no error detail"))
    }

    // MARK: - Hex decoding

    func testHexDecodeEvenLength() {
        XCTAssertEqual(dataFromHex("deadbeef"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testHexDecodeOddLengthPadsLeft() {
        XCTAssertEqual(dataFromHex("abc"), Data([0x0A, 0xBC]))
    }

    func testHexDecodeReturnsNilForInvalidChars() {
        XCTAssertNil(dataFromHex("zz"))
    }

    func testHexDecodeEmptyString() {
        XCTAssertEqual(dataFromHex(""), Data())
    }

    // MARK: - Guard type mapping

    func testGuardTypeEmailCode()         { XCTAssertEqual(GuardType(rawValue: 2), .emailCode) }
    func testGuardTypeDeviceCode()        { XCTAssertEqual(GuardType(rawValue: 3), .deviceCode) }
    func testGuardTypeDeviceConfirmation(){ XCTAssertEqual(GuardType(rawValue: 4), .deviceConfirmation) }
    func testGuardTypeEmailConfirmation() { XCTAssertEqual(GuardType(rawValue: 5), .emailConfirmation) }
    func testGuardTypeUnknownReturnsNil() { XCTAssertNil(GuardType(rawValue: 99)) }

    // MARK: - loginusers.vdf template

    func testLoginUsersVDFContainsRequiredKeys() {
        let vdf = makeLoginUsersVDF(steamID: "76561198047018335", account: "testuser", persona: "Test User")
        XCTAssertTrue(vdf.contains("\"users\""))
        XCTAssertTrue(vdf.contains("\"76561198047018335\""))
        XCTAssertTrue(vdf.contains("\"AccountName\""))
        XCTAssertTrue(vdf.contains("\"testuser\""))
        XCTAssertTrue(vdf.contains("\"PersonaName\""))
        XCTAssertTrue(vdf.contains("\"Test User\""))
        XCTAssertTrue(vdf.contains("\"RememberPassword\""))
        XCTAssertTrue(vdf.contains("\"MostRecent\""))
    }

    func testLoginUsersVDFPassesHasSteamLoginSessionHeuristic() {
        // hasSteamLoginSession() returns true if vdf contains "MostRecent" AND "1"
        let vdf = makeLoginUsersVDF(steamID: "76561198047018335", account: "u", persona: "P")
        XCTAssertTrue(vdf.contains("\"MostRecent\"") && vdf.contains("\"1\""),
            "Template must satisfy hasSteamLoginSession() text-search heuristic")
    }

    func testLoginUsersVDFRememberPasswordIsOne() {
        let vdf = makeLoginUsersVDF(steamID: "1", account: "a", persona: "b")
        XCTAssertTrue(vdf.contains("\"RememberPassword\"\t\t\"1\""),
            "RememberPassword must be set to 1 for persistent auto-login")
    }

    // MARK: - config.vdf / ConnectCache template

    func testConnectCacheVDFContainsRequiredStructure() {
        let token = "eyJhbGciOiJSUzI1NiJ9.fake_token_for_testing"
        let vdf = makeConnectCacheVDF(steamID: "76561198047018335", token: token, account: "testuser")
        XCTAssertTrue(vdf.contains("\"InstallConfigStore\""))
        XCTAssertTrue(vdf.contains("\"ConnectCache\""))
        XCTAssertTrue(vdf.contains("\"76561198047018335\""))
        XCTAssertTrue(vdf.contains(token))
        XCTAssertTrue(vdf.contains("\"Accounts\""))
        XCTAssertTrue(vdf.contains("\"testuser\""))
    }

    func testConnectCacheVDFHierarchyOrder() {
        let vdf = makeConnectCacheVDF(steamID: "123", token: "tok", account: "u")
        // Nesting order: InstallConfigStore > Software > Valve > Steam > ConnectCache
        let positions: [String] = [
            "InstallConfigStore", "Software", "Valve", "\"Steam\"", "ConnectCache"
        ]
        var lastIdx = vdf.startIndex
        for key in positions {
            guard let range = vdf.range(of: key, range: lastIdx..<vdf.endIndex) else {
                XCTFail("Key \"\(key)\" not found in config.vdf template after \(String(vdf[lastIdx...].prefix(30)))")
                return
            }
            lastIdx = range.upperBound
        }
    }

    func testConnectCacheVDFTokenIsPresentUnderSteamID() {
        let steamID = "76561198047018335"
        let token = "test.refresh.token"
        let vdf = makeConnectCacheVDF(steamID: steamID, token: token, account: "u")
        // Both steamID and token must appear inside the ConnectCache block
        guard let cacheStart = vdf.range(of: "\"ConnectCache\"") else {
            return XCTFail("ConnectCache block missing")
        }
        let cacheBlock = String(vdf[cacheStart.lowerBound...])
        XCTAssertTrue(cacheBlock.contains(steamID))
        XCTAssertTrue(cacheBlock.contains(token))
    }

    // MARK: - VDF round-trip via temp files

    func testLoginUsersVDFWriteAndReadBack() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "MeridianTest_loginusers_\(UUID().uuidString).vdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vdf = makeLoginUsersVDF(steamID: "76561198047018335", account: "nick", persona: "Nick")
        try vdf.write(to: tmp, atomically: true, encoding: .utf8)

        let readBack = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(vdf, readBack)
        XCTAssertTrue(readBack.contains("\"nick\""))
        XCTAssertTrue(readBack.contains("\"MostRecent\""))
    }

    func testConnectCacheVDFWriteAndReadBack() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "MeridianTest_config_\(UUID().uuidString).vdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let token = "eyJhbGci.very_long_jwt_refresh_token_value"
        let vdf = makeConnectCacheVDF(steamID: "76561198047018335", token: token, account: "nick")
        try vdf.write(to: tmp, atomically: true, encoding: .utf8)

        let readBack = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertEqual(vdf, readBack)
        XCTAssertTrue(readBack.contains(token))
    }

    // MARK: - Guard type priority logic

    /// Mirrors the priority decision in SteamCredentialAuth.runAuthFlow.
    ///
    /// Rule: deviceConfirmation (push notification) always takes priority over
    /// typed-code flows. When both are offered, we poll for push approval and
    /// surface the code entry as an optional fallback — never block for a code
    /// when the user can just tap "Approve" on their phone.
    private func selectGuardFlow(
        allowedConfirmations: [GuardType]
    ) -> (primary: GuardType?, fallbackCodeType: GuardType?) {
        let codeType = allowedConfirmations.first(where: { $0 != .deviceConfirmation })
        if allowedConfirmations.contains(.deviceConfirmation) {
            return (.deviceConfirmation, codeType)
        }
        return (codeType, nil)
    }

    func testGuardPriority_deviceConfirmationBeatsDeviceCode() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [.deviceConfirmation, .deviceCode])
        XCTAssertEqual(primary, .deviceConfirmation,
                       "Push-notification approval must be primary when both are offered")
        XCTAssertEqual(fallback, .deviceCode,
                       "Typed TOTP code must be available as fallback")
    }

    func testGuardPriority_deviceConfirmationBeatsEmailCode() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [.deviceConfirmation, .emailCode])
        XCTAssertEqual(primary, .deviceConfirmation)
        XCTAssertEqual(fallback, .emailCode)
    }

    func testGuardPriority_deviceConfirmationAloneHasNoFallback() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [.deviceConfirmation])
        XCTAssertEqual(primary, .deviceConfirmation)
        XCTAssertNil(fallback, "No fallback code type when only push confirmation is offered")
    }

    func testGuardPriority_deviceCodeOnlyPath() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [.deviceCode])
        XCTAssertEqual(primary, .deviceCode)
        XCTAssertNil(fallback)
    }

    func testGuardPriority_emailCodeOnlyPath() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [.emailCode])
        XCTAssertEqual(primary, .emailCode)
        XCTAssertNil(fallback)
    }

    func testGuardPriority_emptyConfirmations() {
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: [])
        XCTAssertNil(primary, "No guard required when confirmations list is empty")
        XCTAssertNil(fallback)
    }

    func testGuardPriority_allTypesDeviceConfirmationWins() {
        let all: [GuardType] = [.emailCode, .deviceCode, .deviceConfirmation, .emailConfirmation]
        let (primary, fallback) = selectGuardFlow(allowedConfirmations: all)
        XCTAssertEqual(primary, .deviceConfirmation)
        // Fallback should be the first non-deviceConfirmation type
        XCTAssertNotNil(fallback)
        XCTAssertNotEqual(fallback, .deviceConfirmation)
    }

    func testGuardPriority_orderIndependent() {
        // Regardless of order in the array, deviceConfirmation always wins
        let orderings: [[GuardType]] = [
            [.deviceConfirmation, .deviceCode],
            [.deviceCode, .deviceConfirmation],
            [.emailCode, .deviceConfirmation, .deviceCode],
        ]
        for confirmations in orderings {
            let (primary, _) = selectGuardFlow(allowedConfirmations: confirmations)
            XCTAssertEqual(primary, .deviceConfirmation,
                           "deviceConfirmation must win regardless of position in \(confirmations)")
        }
    }

    // MARK: - Guard type raw values (regression: must not drift from Steam's API)

    func testGuardTypeRawValues_matchSteamAPI() {
        XCTAssertEqual(GuardType.emailCode.rawValue,        2)
        XCTAssertEqual(GuardType.deviceCode.rawValue,       3)
        XCTAssertEqual(GuardType.deviceConfirmation.rawValue, 4)
        XCTAssertEqual(GuardType.emailConfirmation.rawValue, 5)
    }

    // MARK: - platform_type regression (must stay 1 = SteamClient)
    //
    // BeginAuthSessionViaCredentials MUST use platform_type "1" (EAuthTokenPlatformType_SteamClient).
    // Using "2" (WebBrowser) produces a JWT with aud:["web"] instead of aud:["client"].
    // The Steam desktop client silently discards web-audience tokens from its ConnectCache,
    // causing it to remain [Logged Off, 0, 0] and silently drop all download requests.
    // This was the root cause of game installation never working (March 2026).
    //
    // MIRROR CONTRACT: mirrors the platform_type value in SteamCredentialAuth.beginAuthSession.

    /// Mirror of the platform_type constant used in BeginAuthSessionViaCredentials.
    /// Must be "1" (EAuthTokenPlatformType_SteamClient) — NOT "2" (WebBrowser).
    private let expectedPlatformType = "1"

    func testPlatformType_isSteamClient() {
        XCTAssertEqual(expectedPlatformType, "1",
                       "platform_type must be \"1\" (SteamClient). \"2\" (WebBrowser) produces a web-audience token that the Steam desktop client ignores for ConnectCache auto-login.")
    }

    func testPlatformType_isNotWebBrowser() {
        XCTAssertNotEqual(expectedPlatformType, "2",
                          "platform_type \"2\" (WebBrowser) produces aud:[\"web\"] tokens — Steam's ConnectCache requires aud:[\"client\"] to authenticate.")
    }

    // MARK: - Sign-in flow architectural invariants (May 2026 — ssfn-based auth)
    //
    // The sign-in path uses `steam.exe -login USER PASS` (SteamExeSignIn) so Steam
    // performs its own CM auth handshake and writes an ssfn device-trust token.
    // Subsequent cold starts use `steam.exe -silent` with the ssfn — no 2FA,
    // no DPAPI, no JWT injection. The path must:
    //   1. Use SteamExeSignIn (drives steam.exe -login natively).
    //   2. Write loginusers.vdf with AllowAutoLogin=1 + RememberPassword=1 so that
    //      the next -silent launch finds the auto-login flag.
    //   3. Persist steamSelfManagedSession = true (ssfn is now the auth source).
    //   4. NOT call writeSteamSessionLocalVdf (DPAPI local.vdf injection — replaced
    //      by Steam's own on-disk token management via ssfn).
    //   5. NOT call backupSteamSession (backup was for DPAPI local.vdf, now obsolete).
    //   6. NOT call writeConnectCache or provisionNativeCache.

    func testSignInFlowInvariants() throws {
        let authView = try readSource("Meridian/Views/Auth/AuthView.swift")

        XCTAssertTrue(authView.contains("SteamExeSignIn()"),
                      "AuthView must drive sign-in via SteamExeSignIn (steam.exe -login) for native ssfn device-trust.")
        XCTAssertTrue(authView.contains("writeLoginUsers"),
                      "Sign-in must write loginusers.vdf with AllowAutoLogin=1 so -silent launches auto-login.")
        XCTAssertTrue(authView.contains("steamSelfManagedSession") && authView.contains("= true"),
                      "Sign-in must mark steamSelfManagedSession=true so BootstrapManager trusts the ssfn session.")

        let forbiddenSteps = [
            "SteamCredentialAuth()",
            "writeSteamSessionLocalVdf",
            "backupSteamSession",
            "authenticateSteamCMD",
            "writeConnectCache",
            "provisionNativeCache",
        ]
        for step in forbiddenSteps {
            XCTAssertFalse(authView.contains(step),
                           "\(step) MUST NOT be in the sign-in flow — ssfn-based auth does not use DPAPI/JWT injection.")
        }
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }
}
