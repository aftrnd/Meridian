import CryptoKit
import Foundation
import Observation

private let log = MeridianLog(category: "LicenseManager")

// MARK: - License

/// A verified, signed Meridian license. Keys are issued offline by
/// `Scripts/license-keygen.swift` (Ed25519) and verified locally against the
/// embedded public key — no activation server, no network, no account.
///
/// Key format: `MRDN1.<base64url(payload JSON)>.<base64url(signature)>`.
/// Any payment provider (Paddle, Lemon Squeezy, manual) can issue keys by
/// running the signer in its post-purchase webhook.
struct License: Equatable, Sendable {
    let id: String
    let email: String
    let plan: String
    let issuedAt: Date
    let expiresAt: Date?
    let orderID: String?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt < .now
    }

    enum VerificationError: Error, Equatable {
        case malformed
        case badSignature
        case unsupportedVersion
        case expired
    }

    private struct Payload: Decodable {
        let v: Int
        let id: String
        let email: String
        let plan: String
        let iat: Int
        let exp: Int?
        let order: String?
    }

    /// Parses and verifies a key. Pure and nonisolated so tests can exercise
    /// it with their own keypair.
    static func verify(key rawKey: String, publicKeyBase64: String, now: Date = .now) throws -> License {
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

        let license = License(
            id: payload.id,
            email: payload.email,
            plan: payload.plan,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(payload.iat)),
            expiresAt: payload.exp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            orderID: payload.order
        )
        if let exp = license.expiresAt, exp < now { throw VerificationError.expired }
        return license
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str += "=" }
        return Data(base64Encoded: str)
    }
}

// MARK: - LicenseManager

/// Owns licensing state: a stored license key (verified on every read) plus a
/// time-limited trial for unlicensed installs. Views observe `status`; the
/// Play/Install buttons consult `allowsPlay`.
@Observable
@MainActor
final class LicenseManager {

    enum Status: Equatable {
        case licensed(License)
        case trial(daysRemaining: Int)
        case trialExpired
        /// A key is stored but no longer verifies (tampered, expired, or
        /// signed for a different public key).
        case invalid(String)
    }

    /// Ed25519 public key matching the private key in
    /// `~/.config/meridian/license-signing.key` on the maintainer's machine.
    /// Regenerate with `swift Scripts/license-keygen.swift gen`.
    nonisolated static let publicKeyBase64 = "lI0JUa15quDPgzY4RNhh8+sNSIZiCfcoJPscm1Rllwo="

    nonisolated static let trialLength = 14

    /// Where "Buy Meridian" sends the user. Point at the payment provider's
    /// checkout once it exists.
    nonisolated static let purchaseURL = URL(string: "https://github.com/aftrnd/meridian/releases")!

    nonisolated static let licenseKeyDefaultsKey = "license.key"
    nonisolated static let trialStartDefaultsKey = "license.trialStartedAt"

    private(set) var status: Status = .trial(daysRemaining: trialLength)

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { .now }) {
        self.defaults = defaults
        self.now = now
        refresh()
    }

    // MARK: Derived

    var license: License? {
        if case .licensed(let l) = status { return l }
        return nil
    }

    var isLicensed: Bool { license != nil }

    /// Launching and installing games is allowed while licensed or in trial.
    var allowsPlay: Bool {
        switch status {
        case .licensed, .trial: true
        case .trialExpired, .invalid: false
        }
    }

    var storedKey: String? {
        defaults.string(forKey: Self.licenseKeyDefaultsKey)
    }

    // MARK: Actions

    /// Verifies and stores a key. Returns the verification error on failure;
    /// the previous state is left untouched so a typo can't revoke a trial.
    @discardableResult
    func activate(key: String) -> License.VerificationError? {
        do {
            let license = try License.verify(key: key, publicKeyBase64: Self.publicKeyBase64, now: now())
            defaults.set(key.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Self.licenseKeyDefaultsKey)
            status = .licensed(license)
            log.info("[activate] licensed to \(license.email) (\(license.plan))")
            return nil
        } catch let error as License.VerificationError {
            log.warning("[activate] rejected key: \(String(describing: error))")
            return error
        } catch {
            return .malformed
        }
    }

    func deactivate() {
        defaults.removeObject(forKey: Self.licenseKeyDefaultsKey)
        log.info("[deactivate] license removed")
        refresh()
    }

    /// Re-derives `status` from persisted state. Called at init and after
    /// any mutation; cheap enough to call on app activation.
    func refresh() {
        if let key = storedKey {
            do {
                status = .licensed(try License.verify(key: key, publicKeyBase64: Self.publicKeyBase64, now: now()))
                return
            } catch let error as License.VerificationError {
                status = .invalid(Self.describe(error))
                return
            } catch {
                status = .invalid("Unrecognised license key.")
                return
            }
        }
        status = trialStatus()
    }

    // MARK: Trial

    private func trialStatus() -> Status {
        let start = trialStart()
        let elapsed = Calendar.current.dateComponents([.day], from: start, to: now()).day ?? 0
        let remaining = Self.trialLength - elapsed
        return remaining > 0 ? .trial(daysRemaining: remaining) : .trialExpired
    }

    /// First-launch timestamp. Persisted in UserDefaults and mirrored to a
    /// marker file so clearing one store doesn't restart the trial; the
    /// earlier of the two wins.
    private func trialStart() -> Date {
        let marker = Self.trialMarkerURL
        let fromDefaults = (defaults.object(forKey: Self.trialStartDefaultsKey) as? Date)
        let fromFile = (try? Data(contentsOf: marker))
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(TimeInterval.init)
            .map(Date.init(timeIntervalSince1970:))

        if let start = [fromDefaults, fromFile].compactMap({ $0 }).min() {
            if fromDefaults == nil { defaults.set(start, forKey: Self.trialStartDefaultsKey) }
            if fromFile == nil { Self.writeMarker(start, to: marker) }
            return start
        }

        let start = now()
        defaults.set(start, forKey: Self.trialStartDefaultsKey)
        Self.writeMarker(start, to: marker)
        log.info("[trial] started \(Self.trialLength)-day trial")
        return start
    }

    nonisolated private static var trialMarkerURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "com.meridian.app/.trial")
    }

    nonisolated private static func writeMarker(_ date: Date, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? String(date.timeIntervalSince1970).write(to: url, atomically: true, encoding: .utf8)
    }

    static func describe(_ error: License.VerificationError) -> String {
        switch error {
        case .malformed:          "That doesn't look like a Meridian license key."
        case .badSignature:       "This key isn't valid for Meridian."
        case .unsupportedVersion: "This key was issued for a newer version of Meridian."
        case .expired:            "This license has expired."
        }
    }
}
