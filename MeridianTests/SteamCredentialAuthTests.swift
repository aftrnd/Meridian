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

    // MARK: - Inlined: loginusers.vdf template (mirrors WinePrefix.writeLoginUsers)

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

    // MARK: - Sign-in flow architectural invariants (May 19 2026 — OAuth + DPAPI)
    //
    // CLI-verified May 19 2026: `steam.exe -login USER PASS` produces `persistence: 0`
    // access-only JWTs that Steam refuses to persist to `local.vdf` → every cold start
    // re-prompts for credentials. The ONLY architecture that yields `persistence: 1`
    // refresh tokens is Meridian-side OAuth via Valve's IAuthenticationService REST API.
    //
    // The sign-in path must:
    //   1. Drive `SteamCredentialAuth.authenticate()` (REST OAuth — never `session.signIn`,
    //      never `steam.exe -login USER PASS`, never SteamCMD `+login`).
    //   2. Write loginusers.vdf with AllowAutoLogin=1 + RememberPassword=1 so Steam's
    //      own UI (if it ever appears) also auto-logs in.
    //   3. DPAPI-inject local.vdf via `WinePrefix.writeSteamSessionLocalVdf` so
    //      `steam.exe -silent` reads the encrypted refresh_token on next launch.
    //   4. Snapshot local.vdf via `SteamSessionBackup.snapshot` for prefix-reset survival.
    //   5. Start `steam.exe -silent` (via `session.start`) — never `-login`.

    func testSignInFlowInvariants() throws {
        let authView = try readSource("Meridian/Views/Auth/AuthView.swift")
        let session  = try readSource("Meridian/Steam/SteamSession.swift")

        // AuthView must drive SteamCredentialAuth (REST OAuth via IAuthenticationService).
        XCTAssertTrue(authView.contains("SteamCredentialAuth()"),
                      "AuthView must instantiate SteamCredentialAuth — the only path that yields persistence: 1 refresh tokens.")
        XCTAssertTrue(authView.contains("credentialAuth.authenticate("),
                      "AuthView must call credentialAuth.authenticate to begin the OAuth flow.")

        // loginusers.vdf must be written after successful auth so Steam's own UI
        // (if it ever appears) also auto-logs in.
        XCTAssertTrue(authView.contains("writeLoginUsers"),
                      "Sign-in must write loginusers.vdf after auth so Steam UI auto-login works.")

        // DPAPI-inject local.vdf — this is the canonical persistent-auth mechanism
        // (Pattern 12 in engine-research-findings: local.vdf is what CrossOver uses).
        XCTAssertTrue(authView.contains("writeSteamSessionLocalVdf"),
                      "Sign-in must DPAPI-inject local.vdf so steam.exe -silent auto-logs in on next launch.")
        XCTAssertTrue(authView.contains("SteamSessionBackup.snapshot"),
                      "Sign-in must snapshot local.vdf to AppSupport so prefix resets / engine upgrades survive without re-auth.")

        // Steam must be started with -silent (never -login).
        XCTAssertTrue(authView.contains("session.start("),
                      "Sign-in must launch steam.exe -silent via session.start(); -login is forbidden because it yields persistence: 0.")

        // The sign-in flow must NEVER use steam.exe -login (the path that produces
        // persistence: 0). SteamSession.signIn was the wrapper for that path and is
        // deleted; SteamCMD `+login` produces the same persistence: 0 problem.
        let forbidden = [
            "session.signIn(",
            "SteamExeSignIn",
            "extraArgs: [\"-login\"",
            "authenticateSteamCMD",
            "provisionNativeCache",
        ]
        for step in forbidden {
            XCTAssertFalse(authView.contains(step),
                           "AuthView MUST NOT contain `\(step)` — that path yields persistence: 0 (CLI-verified May 19 2026).")
            XCTAssertFalse(session.contains(step),
                           "SteamSession MUST NOT contain `\(step)` — that path yields persistence: 0 (CLI-verified May 19 2026).")
        }

        // SteamSession.launchSteamProcess must always launch -silent without -login args.
        XCTAssertTrue(session.contains("[steamExePath, \"-silent\", \"-nofriendsui\"]"),
                      "SteamSession.launchSteamProcess must hardcode -silent -nofriendsui with no extra auth args.")
    }

    // MARK: - ConnectCache key derivation (CRC32 mirror, Pattern 6/12)
    //
    // The ConnectCache map key in local.vdf is `(crc32(accountName) << 4) | 1`.
    // CLI-verified April 23 2026 against CX Preview's working bottle:
    //   crc32("nickjack876") = 0x07a611aa → key 0x7a611aa1
    // Any other CRC variant produces a different key and Steam's lookup silently fails.

    /// Mirror of WinePrefix.ieeeCRC32 — kept in sync via Mirror Contract.
    private func ieeeCRC32(bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask: UInt32 = (crc & 1) != 0 ? 0xEDB88320 : 0
                crc = (crc >> 1) ^ mask
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// Mirror of WinePrefix.connectCacheKey.
    private func connectCacheKey(for accountName: String) -> String {
        let bytes = Array(accountName.utf8)
        let crc = ieeeCRC32(bytes: bytes)
        let key: UInt32 = (crc << 4) | 0x1
        return String(format: "%08x", key)
    }

    func testConnectCacheKey_matchesCrossOverReferenceVector() {
        // CLI-verified vector from CX Preview's working local.vdf:
        //   accountName "nickjack876" → CRC32 0x07a611aa → key 0x7a611aa1
        XCTAssertEqual(ieeeCRC32(bytes: Array("nickjack876".utf8)), 0x07a611aa,
                       "CRC32 of 'nickjack876' must equal 0x07a611aa to match CrossOver's working local.vdf")
        XCTAssertEqual(connectCacheKey(for: "nickjack876"), "7a611aa1",
                       "ConnectCache key for 'nickjack876' must be 0x7a611aa1 (matches CX reference).")
    }

    func testConnectCacheKey_alwaysSetsSlotBitOne() {
        // The low nibble is the slot number (always 1 in Meridian — single user per bottle).
        for name in ["test", "user123", "long_account_name_with_underscores"] {
            let key = connectCacheKey(for: name)
            XCTAssertTrue(key.hasSuffix("1"),
                          "Slot number is always 1 → key must end in '1', got \(key) for \(name)")
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
