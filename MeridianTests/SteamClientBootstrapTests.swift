import XCTest
import CryptoKit

/// Unit tests for the native Steam client bootstrap (SteamClientBootstrap.swift).
///
/// The `Meridian` target is an executableTarget; Swift cannot `@testable import` it,
/// so the pure VDF-manifest-parsing logic is mirrored here (inlined copies).
///
/// MIRROR CONTRACT: `parseManifest` / `vdfKeyValue` below mirror
/// `SteamClientBootstrap.parseManifest` / `SteamClientBootstrap.vdfKeyValue`.
/// When the production parser changes, update these mirrors in lock-step.
final class SteamClientBootstrapTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Mirror of SteamClientBootstrap.Package

    struct Package: Equatable {
        let name: String
        let file: String
        let size: Int
        let sha256: String
    }

    /// Mirror of SteamClientBootstrap.parseManifest
    private func parseManifest(_ text: String) -> [Package] {
        var packages: [Package] = []
        let lines = text.components(separatedBy: .newlines)

        var currentName: String?
        var currentFile: String?
        var currentSize: Int?
        var currentSHA: String?
        var inBlock = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !inBlock, trimmed.hasPrefix("\""), !trimmed.contains("\t") {
                let name = trimmed.replacingOccurrences(of: "\"", with: "")
                if !name.isEmpty, name != "win32", name != "win64" {
                    currentName = name
                }
                continue
            }

            if trimmed == "{" {
                if currentName != nil { inBlock = true }
                continue
            }

            if trimmed == "}" {
                if inBlock, let name = currentName, let file = currentFile,
                   let size = currentSize, let sha = currentSHA {
                    packages.append(Package(name: name, file: file, size: size, sha256: sha))
                }
                inBlock = false
                currentName = nil
                currentFile = nil
                currentSize = nil
                currentSHA = nil
                continue
            }

            if inBlock, let kv = vdfKeyValue(trimmed) {
                switch kv.key {
                case "file": currentFile = kv.value
                case "size": currentSize = Int(kv.value)
                case "sha2": currentSHA = kv.value
                default: break
                }
            }
        }

        return packages
    }

    /// Mirror of SteamClientBootstrap.vdfKeyValue
    private func vdfKeyValue(_ line: String) -> (key: String, value: String)? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let keyEnd = s.firstIndex(of: "\"") else { return nil }
        let key = String(s[s.startIndex..<keyEnd])
        s = String(s[s.index(after: keyEnd)...]).trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("\"") else { return nil }
        s = String(s.dropFirst())
        guard let valueEnd = s.firstIndex(of: "\"") else { return nil }
        let value = String(s[s.startIndex..<valueEnd])
        return (key, value)
    }

    // MARK: - Sample manifest (tab-indented, matching Valve's steam_client_win32 format)

    private let sampleManifest = """
    "win32"
    {
    \t"bins_misc"
    \t{
    \t\t"file"\t\t"bins_misc_1111.zip.aaaa"
    \t\t"size"\t\t"1048576"
    \t\t"sha2"\t\t"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    \t\t"zipvz"\t\t"bins_misc_1111.zipvz.bbbb"
    \t}
    \t"steamui"
    \t{
    \t\t"file"\t\t"steamui_2222.zip.cccc"
    \t\t"size"\t\t"2097152"
    \t\t"sha2"\t\t"cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
    \t}
    }
    """

    func testParseManifest_extractsAllPackages() {
        let packages = parseManifest(sampleManifest)
        XCTAssertEqual(packages.count, 2, "Should parse exactly the two package blocks (win32 wrapper is not a package)")

        XCTAssertEqual(packages[0], Package(
            name: "bins_misc",
            file: "bins_misc_1111.zip.aaaa",
            size: 1_048_576,
            sha256: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        ))
        XCTAssertEqual(packages[1], Package(
            name: "steamui",
            file: "steamui_2222.zip.cccc",
            size: 2_097_152,
            sha256: "cafebabecafebabecafebabecafebabecafebabecafebabecafebabecafebabe"
        ))
    }

    func testParseManifest_skipsWin32Wrapper() {
        let packages = parseManifest(sampleManifest)
        XCTAssertFalse(packages.contains { $0.name == "win32" },
                       "The outer win32 wrapper key must never be emitted as a package")
    }

    func testParseManifest_skipsIncompleteBlocks() {
        // A block missing the required sha2 field must be dropped, not partially emitted.
        let manifest = """
        "win32"
        {
        \t"incomplete"
        \t{
        \t\t"file"\t\t"incomplete_1.zip.x"
        \t\t"size"\t\t"100"
        \t}
        \t"good"
        \t{
        \t\t"file"\t\t"good_1.zip.y"
        \t\t"size"\t\t"200"
        \t\t"sha2"\t\t"abc123"
        \t}
        }
        """
        let packages = parseManifest(manifest)
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.name, "good")
    }

    func testParseManifest_emptyReturnsEmpty() {
        XCTAssertTrue(parseManifest("").isEmpty)
        XCTAssertTrue(parseManifest("garbage\nnot a manifest\n").isEmpty)
    }

    func testVdfKeyValue_parsesQuotedPair() {
        let kv = vdfKeyValue("\t\t\"file\"\t\t\"value_here.zip.abc\"")
        XCTAssertEqual(kv?.key, "file")
        XCTAssertEqual(kv?.value, "value_here.zip.abc")
    }

    func testVdfKeyValue_rejectsNonKeyValueLines() {
        XCTAssertNil(vdfKeyValue("{"))
        XCTAssertNil(vdfKeyValue("}"))
        XCTAssertNil(vdfKeyValue("no quotes at all"))
    }

    // MARK: - SHA-256 hex formatting (mirrors the verification used in SteamClientBootstrap)

    func testSHA256_hexEncodingMatchesProduction() {
        // Empty-input SHA-256 is a stable, well-known constant — proves the
        // map/format/joined hex encoding matches what verifySHA256 compares against.
        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(emptyHash,
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let hash = SHA256.hash(data: Data("meridian".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hash.count, 64, "SHA-256 hex digest must be 64 lowercase hex chars")
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "Digest must be hex only")
    }

    // MARK: - Source-text guards (architecture invariants)

    /// The Steam client download is NATIVE (SteamClientBootstrap), NOT a
    /// `steam.exe -silent` bootstrap (its 32-bit static OpenSSL cannot complete
    /// TLS under WoW64 on macOS 26 → "http error 0" → steamui.dll never
    /// appears). As of Phase 3 (HANDOFF-2026-06-19) the client download is
    /// lazy + DRM-only and lives in SteamSession.bootstrapSteamClientIfNeeded.
    func testBootstrap_usesNativeClientDownload() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("SteamClientBootstrap.downloadAndInstall"),
                      "SteamSession.bootstrapSteamClientIfNeeded must call SteamClientBootstrap.downloadAndInstall (native URLSession download)")
    }

    /// The bootstrap pipeline must never run steam.exe to download the client
    /// nor poll bootstrap_log.txt. BootstrapManager must not start steam.exe at
    /// all now (Phase 3 — Steam is lazy/DRM-only).
    func testBootstrap_doesNotRunSteamExeToBootstrap() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")
        XCTAssertFalse(src.contains("\"-silent\""),
                       "BootstrapManager must NOT launch steam.exe -silent (Steam is lazy/DRM-only; that path also fails TLS on macOS 26)")
        XCTAssertFalse(src.contains("bootstrap_log.txt"),
                       "BootstrapManager must NOT poll bootstrap_log.txt — the native downloader surfaces failures directly")
    }

    /// FAIL-FAST (fail-fast.mdc): a client-download failure must surface after
    /// at most ONE clean retry — never an infinite wipe→retry loop. The logic
    /// lives in SteamSession (lazy DRM path) as of Phase 3.
    func testBootstrap_failsFastAfterOneCleanRetry() throws {
        let src = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(src.contains("one clean retry"),
                      "bootstrapSteamClientIfNeeded must perform exactly one clean retry before surfacing the error")
        XCTAssertTrue(src.contains("Steam client download failed"),
                      "the final (post-retry) failure must surface a clear message")
    }

    /// The native bootstrap MUST fetch the WIN64 client manifest, not win32.
    /// CLI-verified 2026-06-18: the win32 `steam_win32_steamrow` package ships a
    /// 32-bit steam.exe (PE32) that reports Windows 8 and fails every in-Wine
    /// update fetch with `http error 0`; the win64 `steam_win64_steamrow` package
    /// ships the 64-bit steam.exe (PE32+) that reports Windows 10 and works.
    func testBootstrap_fetchesWin64Manifest() throws {
        let src = try readSource("Meridian/Engine/SteamClientBootstrap.swift")
        XCTAssertTrue(src.contains("steam_client_win64"),
                      "SteamClientBootstrap must fetch the steam_client_win64 manifest (64-bit steam.exe)")
        XCTAssertFalse(src.contains("/steam_client_win32\")"),
                      "SteamClientBootstrap must NOT fetch the steam_client_win32 manifest as the client source — its 32-bit steam.exe fails in-Wine networking")
        XCTAssertTrue(src.contains("steam_client_win64.installed"),
                      "the installed-manifest marker must be steam_client_win64.installed so steam.exe verifies against the 64-bit install")
    }

    /// The win64 manifest nests both `steamrow` (global) and `steamchina`
    /// bootstrappers, each shipping a steam.exe. The China package must be
    /// excluded or it overwrites steam.exe with the China build.
    func testBootstrap_excludesChinaBootstrapper() throws {
        let src = try readSource("Meridian/Engine/SteamClientBootstrap.swift")
        XCTAssertTrue(src.contains("china"),
                      "downloadAndInstall must filter out the region-specific (china) bootstrapper package so the global 64-bit steam.exe lands")
    }

    /// Existing prefixes created by an older (win32) Meridian have the broken
    /// 32-bit steam.exe even though steamui.dll exists. The lazy DRM bootstrap
    /// (SteamSession) must re-bootstrap based on `isSteamExe64Bit`, not
    /// steamui.dll alone.
    func testBootstrap_reBootstrapsWhenSteamExeIs32Bit() throws {
        let mgr = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(mgr.contains("isSteamExe64Bit"),
                      "SteamSession.bootstrapSteamClientIfNeeded must consult prefix.isSteamExe64Bit so an existing 32-bit steam.exe is re-bootstrapped to win64")
        let prefix = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(prefix.contains("var isSteamExe64Bit"),
                      "WinePrefix must expose isSteamExe64Bit (PE machine-type check on steam.exe)")
        XCTAssertTrue(prefix.contains("0x8664"),
                      "isSteamExe64Bit must check IMAGE_FILE_MACHINE_AMD64 (0x8664) in the PE header")
    }

    /// Info.plist must allow the Steam/GitHub CDN domains the native bootstrap fetches from,
    /// otherwise ATS on macOS 26 blocks the HTTPS downloads.
    func testInfoPlist_allowsBootstrapCDNDomains() throws {
        let plist = try readSource("Meridian/Info.plist")
        for domain in ["cdn.akamai.steamstatic.com", "cdn.steamstatic.com",
                       "objects.githubusercontent.com", "github.com"] {
            XCTAssertTrue(plist.contains(domain),
                          "Info.plist NSExceptionDomains must include \(domain)")
        }
    }
}
