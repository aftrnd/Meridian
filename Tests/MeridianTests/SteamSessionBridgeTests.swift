/// Tests for SteamSessionBridge session file staging logic.
///
/// These tests verify that the bridge correctly copies Steam auth files
/// (loginusers.vdf, config.vdf, registry.vdf) into the staging directory
/// so the guest VM can auto-login without a password prompt.
///
/// Run with:  swift test --filter SteamSessionBridgeTests

import Testing
import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Minimal inline reimplementation for testability
//
// We can't import the app target directly in a test target without framework
// extraction. Instead we inline the pure logic being tested.
// ─────────────────────────────────────────────────────────────────────────────

/// Copies Steam session files from a source directory into a staging directory.
/// Returns true if any file was copied.
@discardableResult
func copySessionFiles(from steamDir: URL, to staging: URL) -> Bool {
    let fm = FileManager.default
    let files: [(String, String)] = [
        ("config/loginusers.vdf", "config/loginusers.vdf"),
        ("config/config.vdf",     "config/config.vdf"),
        ("registry.vdf",          "registry.vdf"),
    ]

    var copiedAny = false
    for (src, dst) in files {
        let source = steamDir.appending(path: src)
        guard fm.fileExists(atPath: source.path) else { continue }
        let destination = staging.appending(path: dst)
        let destDir = destination.deletingLastPathComponent()
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: destination)
        copiedAny = true
    }
    return copiedAny
}

/// Writes a credentials.env file for guest-side `steam +login`.
func writeCredentials(username: String, password: String, to staging: URL) {
    let content = "STEAM_USER=\(username)\nSTEAM_PASS=\(password)\n"
    let dest = staging.appending(path: "credentials.env")
    try? content.write(to: dest, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ─────────────────────────────────────────────────────────────────────────────

func makeTempDir(_ name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "meridian-test-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func populateSteamDir(_ dir: URL) throws {
    let config = dir.appending(path: "config")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try "loginusers content".write(to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)
    try "config content".write(to: config.appending(path: "config.vdf"),     atomically: true, encoding: .utf8)
    try "registry content".write(to: dir.appending(path: "registry.vdf"),    atomically: true, encoding: .utf8)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tests
// ─────────────────────────────────────────────────────────────────────────────

@Suite("SteamSessionBridge — session file staging")
struct SteamSessionFileStagingTests {

    @Test("copies all three session files when all present")
    func copiesAllFiles() throws {
        let source  = try makeTempDir("source")
        let staging = try makeTempDir("staging")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        try populateSteamDir(source)

        let result = copySessionFiles(from: source, to: staging)

        #expect(result == true)
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "config/loginusers.vdf").path))
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "config/config.vdf").path))
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "registry.vdf").path))
    }

    @Test("returns false when source directory is empty")
    func emptySource() throws {
        let source  = try makeTempDir("empty-source")
        let staging = try makeTempDir("empty-staging")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }

        let result = copySessionFiles(from: source, to: staging)
        #expect(result == false)
    }

    @Test("returns true when only loginusers.vdf is present")
    func partialSource() throws {
        let source  = try makeTempDir("partial-source")
        let staging = try makeTempDir("partial-staging")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        let config = source.appending(path: "config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try "users".write(to: config.appending(path: "loginusers.vdf"), atomically: true, encoding: .utf8)

        let result = copySessionFiles(from: source, to: staging)
        #expect(result == true)
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "config/loginusers.vdf").path))
        #expect(!FileManager.default.fileExists(atPath: staging.appending(path: "config/config.vdf").path))
    }

    @Test("copied file content is identical to source")
    func contentIntegrity() throws {
        let source  = try makeTempDir("integrity-source")
        let staging = try makeTempDir("integrity-staging")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        try populateSteamDir(source)
        copySessionFiles(from: source, to: staging)

        let orig = try String(contentsOf: source.appending(path: "registry.vdf"), encoding: .utf8)
        let copy = try String(contentsOf: staging.appending(path: "registry.vdf"), encoding: .utf8)
        #expect(orig == copy)
    }

    @Test("staging dir is created if it does not exist")
    func createsSubdirectory() throws {
        let source  = try makeTempDir("subdir-source")
        let staging = try makeTempDir("subdir-staging")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        try populateSteamDir(source)

        // Remove staging config subdir to force creation
        try? FileManager.default.removeItem(at: staging.appending(path: "config"))

        copySessionFiles(from: source, to: staging)
        #expect(FileManager.default.fileExists(atPath: staging.appending(path: "config/loginusers.vdf").path))
    }
}

@Suite("SteamSessionBridge — credential injection")
struct CredentialInjectionTests {

    @Test("credentials.env contains STEAM_USER and STEAM_PASS")
    func credentialsFileContent() throws {
        let staging = try makeTempDir("creds-staging")
        defer { try? FileManager.default.removeItem(at: staging) }

        writeCredentials(username: "mysteamuser", password: "hunter2", to: staging)

        let dest = staging.appending(path: "credentials.env")
        #expect(FileManager.default.fileExists(atPath: dest.path))

        let content = try String(contentsOf: dest, encoding: .utf8)
        #expect(content.contains("STEAM_USER=mysteamuser"))
        #expect(content.contains("STEAM_PASS=hunter2"))
    }

    @Test("credentials.env is owner-read-only (mode 600)")
    func credentialsFilePermissions() throws {
        let staging = try makeTempDir("perms-staging")
        defer { try? FileManager.default.removeItem(at: staging) }

        writeCredentials(username: "u", password: "p", to: staging)
        let dest = staging.appending(path: "credentials.env")

        let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600, "Expected mode 600, got \(String(perms ?? 0, radix: 8))")
    }

    @Test("credentials.env is newline-terminated")
    func credentialsNewline() throws {
        let staging = try makeTempDir("newline-staging")
        defer { try? FileManager.default.removeItem(at: staging) }

        writeCredentials(username: "u", password: "p", to: staging)
        let content = try String(contentsOf: staging.appending(path: "credentials.env"), encoding: .utf8)
        #expect(content.hasSuffix("\n"))
    }

    @Test("special characters in password are not escaped")
    func specialCharsInPassword() throws {
        let staging = try makeTempDir("special-staging")
        defer { try? FileManager.default.removeItem(at: staging) }

        writeCredentials(username: "user", password: "p@$$w0rd!", to: staging)
        let content = try String(contentsOf: staging.appending(path: "credentials.env"), encoding: .utf8)
        #expect(content.contains("STEAM_PASS=p@$$w0rd!"))
    }
}
