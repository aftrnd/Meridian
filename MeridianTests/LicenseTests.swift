import CryptoKit
import XCTest

/// Tests for offline Ed25519 license verification, plus contract tests for the
/// Play/Install gate, Settings wiring, and the dev-only gbe_fork gate.
///
/// `MeridianTests` cannot link the `Meridian` executable target (see
/// WinePrefixTests.swift), so `verifyMirror` below mirrors `License.verify` in
/// Meridian/Models/LicenseManager.swift. Keep them in sync;
/// `testMirror_matchesProductionSource` pins the load-bearing lines.
final class LicenseTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Mirror of License.verify

    enum VerificationError: Error, Equatable {
        case malformed, badSignature, unsupportedVersion, expired
    }

    struct Payload: Decodable {
        let v: Int
        let id: String
        let email: String
        let plan: String
        let iat: Int
        let exp: Int?
        let order: String?
    }

    private func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }

    private func verifyMirror(key rawKey: String, publicKeyBase64: String, now: Date = .now) throws -> Payload {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = key.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw VerificationError.malformed }
        guard parts[0] == "MRDN1" else { throw VerificationError.unsupportedVersion }
        guard let payloadData = base64urlDecode(String(parts[1])),
              let signature = base64urlDecode(String(parts[2])),
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            throw VerificationError.malformed
        }
        guard publicKey.isValidSignature(signature, for: payloadData) else {
            throw VerificationError.badSignature
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw VerificationError.malformed
        }
        guard payload.v == 1 else { throw VerificationError.unsupportedVersion }
        if let exp = payload.exp, Date(timeIntervalSince1970: TimeInterval(exp)) < now {
            throw VerificationError.expired
        }
        return payload
    }

    // MARK: - Key fixtures (same layout as Scripts/license-keygen.swift)

    private func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func makeKey(
        signer: Curve25519.Signing.PrivateKey,
        email: String = "buyer@example.com",
        plan: String = "personal",
        exp: Int? = nil,
        prefix: String = "MRDN1"
    ) throws -> String {
        var payload: [String: Any] = [
            "v": 1, "id": "abc-123", "email": email, "plan": plan, "iat": 1_760_000_000,
        ]
        if let exp { payload["exp"] = exp }
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let sig = try signer.signature(for: json)
        return "\(prefix).\(base64url(json)).\(base64url(sig))"
    }

    // MARK: - Verification

    func testVerify_acceptsValidKey() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()
        let key = try makeKey(signer: signer)

        let payload = try verifyMirror(key: "  \(key)\n", publicKeyBase64: pub)
        XCTAssertEqual(payload.email, "buyer@example.com")
        XCTAssertEqual(payload.plan, "personal")
        XCTAssertNil(payload.exp)
    }

    func testVerify_rejectsWrongPublicKey() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let other = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        let key = try makeKey(signer: signer)

        XCTAssertThrowsError(try verifyMirror(key: key, publicKeyBase64: other)) { error in
            XCTAssertEqual(error as? VerificationError, .badSignature)
        }
    }

    func testVerify_rejectsTamperedPayload() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()
        let key = try makeKey(signer: signer, email: "a@example.com")

        let forgedPayload = try JSONSerialization.data(
            withJSONObject: ["v": 1, "id": "abc-123", "email": "b@example.com", "plan": "personal", "iat": 1],
            options: [.sortedKeys]
        )
        var parts = key.split(separator: ".").map(String.init)
        parts[1] = base64url(forgedPayload)

        XCTAssertThrowsError(try verifyMirror(key: parts.joined(separator: "."), publicKeyBase64: pub)) { error in
            XCTAssertEqual(error as? VerificationError, .badSignature)
        }
    }

    func testVerify_rejectsMalformedAndUnsupportedVersion() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertThrowsError(try verifyMirror(key: "not-a-key", publicKeyBase64: pub)) { error in
            XCTAssertEqual(error as? VerificationError, .malformed)
        }
        XCTAssertThrowsError(try verifyMirror(key: "", publicKeyBase64: pub)) { error in
            XCTAssertEqual(error as? VerificationError, .malformed)
        }
        let v2 = try makeKey(signer: signer, prefix: "MRDN2")
        XCTAssertThrowsError(try verifyMirror(key: v2, publicKeyBase64: pub)) { error in
            XCTAssertEqual(error as? VerificationError, .unsupportedVersion)
        }
    }

    func testVerify_honoursExpiry() throws {
        let signer = Curve25519.Signing.PrivateKey()
        let pub = signer.publicKey.rawRepresentation.base64EncodedString()
        let expiry = 1_800_000_000
        let key = try makeKey(signer: signer, exp: expiry)

        let before = Date(timeIntervalSince1970: TimeInterval(expiry - 60))
        let after  = Date(timeIntervalSince1970: TimeInterval(expiry + 60))

        XCTAssertNoThrow(try verifyMirror(key: key, publicKeyBase64: pub, now: before))
        XCTAssertThrowsError(try verifyMirror(key: key, publicKeyBase64: pub, now: after)) { error in
            XCTAssertEqual(error as? VerificationError, .expired)
        }
    }

    // MARK: - Production source contracts

    /// The embedded public key must be a real 32-byte Ed25519 key, not a placeholder.
    func testEmbeddedPublicKey_isValidEd25519() throws {
        let src = try readSource("Meridian/Models/LicenseManager.swift")
        let pattern = #"publicKeyBase64 = "([A-Za-z0-9+/=]+)""#
        let match = try XCTUnwrap(src.range(of: pattern, options: .regularExpression))
        let b64 = String(src[match]).split(separator: "\"")[1]
        let data = try XCTUnwrap(Data(base64Encoded: String(b64)))
        XCTAssertEqual(data.count, 32, "Ed25519 public keys are 32 bytes")
        XCTAssertNoThrow(try Curve25519.Signing.PublicKey(rawRepresentation: data))
    }

    func testMirror_matchesProductionSource() throws {
        let src = try readSource("Meridian/Models/LicenseManager.swift")
        for needle in [
            "guard parts.count == 3 else { throw VerificationError.malformed }",
            "guard parts[0] == \"MRDN1\" else { throw VerificationError.unsupportedVersion }",
            "guard publicKey.isValidSignature(signature, for: payloadData) else {",
            "guard payload.v == 1 else { throw VerificationError.unsupportedVersion }",
            "if let exp = license.expiresAt, exp < now { throw VerificationError.expired }",
        ] {
            XCTAssertTrue(src.contains(needle), "License.verify drifted from the test mirror: missing `\(needle)`")
        }
    }

    func testLicenseManager_trialAndGateContracts() throws {
        let src = try readSource("Meridian/Models/LicenseManager.swift")
        XCTAssertTrue(src.contains("static let trialLength = 14"), "Trial is 14 days.")
        XCTAssertTrue(src.contains("case .licensed, .trial: true") && src.contains("case .trialExpired, .invalid: false"),
                      "allowsPlay must be true only while licensed or in trial.")
        // The trial start is the EARLIER of UserDefaults and the on-disk marker,
        // so wiping one store cannot restart the trial.
        XCTAssertTrue(src.contains("[fromDefaults, fromFile].compactMap({ $0 }).min()"),
                      "Trial start must take the earlier of the two persisted timestamps.")
        XCTAssertTrue(src.contains("func activate(key: String) -> License.VerificationError?"),
                      "activate returns the error instead of mutating status on failure.")
    }

    func testGameDetail_gatesPlayAndInstallOnLicense() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("@Environment(LicenseManager.self)"),
                      "GameDetailView must observe LicenseManager.")
        XCTAssertEqual(src.components(separatedBy: "guard licenseManager.allowsPlay else { showLicenseRequired = true; return }").count - 1, 2,
                       "Both Play and Install must be gated on licenseManager.allowsPlay.")
        XCTAssertTrue(src.contains("LicenseRequiredSheet()"),
                      "The trial-expired sheet must be presented from GameDetailView.")
    }

    func testApp_providesLicenseManagerToMainAndSettingsScenes() throws {
        let src = try readSource("Meridian/App/MeridianApp.swift")
        XCTAssertEqual(src.components(separatedBy: ".environment(licenseManager)").count - 1, 2,
                       "LicenseManager must be injected into both the main window and Settings.")
        let settings = try readSource("Meridian/Views/Settings/SettingsView.swift")
        XCTAssertTrue(settings.contains("LicenseStatusView()") && settings.contains(".tag(\"license\")"),
                      "Settings must have a License tab.")
    }

    // MARK: - Licensing must not alter the launch path

    /// Regression guard (2026-09-10): the licensing pass briefly forced every
    /// game to Online behind a dev flag. That made per-game compat fixes
    /// unreachable (Steam owns the exe environment in Online mode) and put
    /// the Steam UI in front of users. Offline stays the default and the
    /// launch-mode picker is always available.
    func testLaunchMode_isNotGatedByAFeatureFlag() throws {
        let src = try readSource("Meridian/Models/AppSettings.swift")
        XCTAssertFalse(src.contains("localLaunchMode"),
                       "Launch mode must not be gated behind a feature flag.")
        XCTAssertTrue(src.contains("onlineModeAppIDs.contains(appID) ? .online : .offline"),
                      "launchMode(appID:) must default to .offline.")

        let detail = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertFalse(detail.contains("localLaunchModeEnabled"),
                       "The launch-mode chevron/popover must render unconditionally.")
    }
}
