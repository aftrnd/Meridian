#!/usr/bin/env swift
//
// license-keygen.swift — issue and verify Meridian license keys (Ed25519, offline).
//
// Usage:
//   swift Scripts/license-keygen.swift gen
//       Creates ~/.config/meridian/license-signing.key (chmod 600) and prints the
//       PUBLIC key. Paste the public key into `LicenseManager.publicKeyBase64`.
//       Never commit the private key. Back it up in a password manager — losing
//       it means every issued key becomes unverifiable by future builds.
//
//   swift Scripts/license-keygen.swift sign --email you@example.com [--plan personal] [--exp 2027-12-31] [--order ORDER_ID]
//       Prints a license key. Wire this into your payment provider's
//       post-purchase webhook (Paddle / Lemon Squeezy) or run it by hand.
//
//   swift Scripts/license-keygen.swift verify MRDN1.… [--pub BASE64]
//       Verifies a key against the private key's public half (or --pub).
//
// Key format:  MRDN1.<base64url(payload JSON)>.<base64url(Ed25519 signature)>
// Payload:     {"v":1,"id":"…","email":"…","plan":"…","iat":<unix>,"exp":<unix>?,"order":"…"?}
//
// The same payload/signature layout is parsed by Meridian/Models/LicenseManager.swift.

import CryptoKit
import Foundation

let keyPath = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: ".config/meridian/license-signing.key")

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func base64urlDecode(_ s: String) -> Data? {
    var str = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while str.count % 4 != 0 { str += "=" }
    return Data(base64Encoded: str)
}

func loadPrivateKey() -> Curve25519.Signing.PrivateKey {
    guard let raw = try? Data(contentsOf: keyPath),
          let text = String(data: raw, encoding: .utf8),
          let bytes = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes) else {
        fail("No signing key at \(keyPath.path). Run: swift Scripts/license-keygen.swift gen")
    }
    return key
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    fail("usage: license-keygen.swift gen | sign --email … | verify KEY")
}

switch command {
case "gen":
    if FileManager.default.fileExists(atPath: keyPath.path) {
        fail("Refusing to overwrite existing key at \(keyPath.path)")
    }
    let key = Curve25519.Signing.PrivateKey()
    try? FileManager.default.createDirectory(at: keyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    do {
        try key.rawRepresentation.base64EncodedString().write(to: keyPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyPath.path)
    } catch {
        fail("Could not write key: \(error)")
    }
    print("Private key written to \(keyPath.path) (chmod 600). Back it up now.")
    print("")
    print("PUBLIC KEY (paste into LicenseManager.publicKeyBase64):")
    print(key.publicKey.rawRepresentation.base64EncodedString())

case "sign":
    guard let email = option("--email", in: args) else { fail("--email is required") }
    let plan = option("--plan", in: args) ?? "personal"
    var payload: [String: Any] = [
        "v": 1,
        "id": UUID().uuidString.lowercased(),
        "email": email,
        "plan": plan,
        "iat": Int(Date().timeIntervalSince1970),
    ]
    if let exp = option("--exp", in: args) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        guard let date = fmt.date(from: exp) else { fail("--exp must be yyyy-MM-dd") }
        payload["exp"] = Int(date.timeIntervalSince1970)
    }
    if let order = option("--order", in: args) { payload["order"] = order }

    let key = loadPrivateKey()
    guard let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
        fail("Could not encode payload")
    }
    guard let sig = try? key.signature(for: json) else { fail("Signing failed") }
    print("MRDN1.\(base64url(json)).\(base64url(sig))")

case "verify":
    guard args.count >= 2 else { fail("verify needs a key") }
    let licenseKey = args[1]
    let pubKeyData: Data
    if let pub = option("--pub", in: args) {
        guard let d = Data(base64Encoded: pub) else { fail("--pub is not base64") }
        pubKeyData = d
    } else {
        pubKeyData = loadPrivateKey().publicKey.rawRepresentation
    }
    let parts = licenseKey.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "MRDN1",
          let payload = base64urlDecode(String(parts[1])),
          let sig = base64urlDecode(String(parts[2])),
          let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: pubKeyData) else {
        fail("Malformed key")
    }
    guard pub.isValidSignature(sig, for: payload) else { fail("INVALID signature") }
    print("VALID")
    print(String(data: payload, encoding: .utf8) ?? "")

default:
    fail("unknown command \(command)")
}
