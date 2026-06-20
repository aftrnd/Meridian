import XCTest
import Foundation

/// Tests for the game tech-stack detection + resolution subsystem
/// (`Meridian/Engine/GameStackResolver.swift`).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// MIRROR CONTRACT — READ BEFORE MODIFYING
/// ─────────────────────────────────────────────────────────────────────────────
/// The helpers below are exact copies of pure logic in GameStackResolver.swift.
/// WHENEVER you change that logic, update these mirrors.
///
/// Mirrored functions:
///   • peBitnessMirror(_:)        ← GameStackDetector.peBitness
///   • fingerprintEngineMirror(…) ← GameStackDetector.fingerprintEngine
///   • parseEngineMirror(_:)      ← PCGamingWikiService.parseEngine
///   • parseDirect3DMirror(_:)    ← PCGamingWikiService.parseDirect3D
///   • mergeAPIMirror(…)          ← GameStackResolver.merge (graphics-API priority)
/// ─────────────────────────────────────────────────────────────────────────────
final class GameStackResolverTests: XCTestCase {

    // MARK: - PE bitness

    /// Mirror of `GameStackDetector.peBitness`, operating over a full byte
    /// buffer (production reads the same offsets via FileHandle + seek).
    private func peBitnessMirror(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 0x40 else { return nil }
        guard bytes[0] == 0x4D, bytes[1] == 0x5A else { return nil } // "MZ"
        let eLfanew = UInt32(bytes[0x3C]) | (UInt32(bytes[0x3D]) << 8)
            | (UInt32(bytes[0x3E]) << 16) | (UInt32(bytes[0x3F]) << 24)
        guard eLfanew < 0x1000_0000, Int(eLfanew) + 6 <= bytes.count else { return nil }
        let pe = Int(eLfanew)
        guard bytes[pe] == 0x50, bytes[pe + 1] == 0x45,
              bytes[pe + 2] == 0, bytes[pe + 3] == 0 else { return nil } // "PE\0\0"
        let machine = UInt16(bytes[pe + 4]) | (UInt16(bytes[pe + 5]) << 8)
        switch machine {
        case 0x8664, 0xAA64: return 64
        case 0x014C:         return 32
        default:             return nil
        }
    }

    /// Builds a minimal synthetic PE buffer with the given machine type.
    private func makePE(machine: UInt16, eLfanew: UInt32 = 0x80) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: Int(eLfanew) + 8)
        b[0] = 0x4D; b[1] = 0x5A // MZ
        b[0x3C] = UInt8(eLfanew & 0xFF)
        b[0x3D] = UInt8((eLfanew >> 8) & 0xFF)
        b[0x3E] = UInt8((eLfanew >> 16) & 0xFF)
        b[0x3F] = UInt8((eLfanew >> 24) & 0xFF)
        let pe = Int(eLfanew)
        b[pe] = 0x50; b[pe + 1] = 0x45; b[pe + 2] = 0; b[pe + 3] = 0 // PE\0\0
        b[pe + 4] = UInt8(machine & 0xFF)
        b[pe + 5] = UInt8((machine >> 8) & 0xFF)
        return b
    }

    func testPEBitness_x64() {
        XCTAssertEqual(peBitnessMirror(makePE(machine: 0x8664)), 64)
    }

    func testPEBitness_x86() {
        XCTAssertEqual(peBitnessMirror(makePE(machine: 0x014C)), 32)
    }

    func testPEBitness_arm64IsTreatedAs64() {
        XCTAssertEqual(peBitnessMirror(makePE(machine: 0xAA64)), 64)
    }

    func testPEBitness_notPEReturnsNil() {
        // Missing MZ signature.
        var b = [UInt8](repeating: 0, count: 0x88)
        b[0] = 0x00; b[1] = 0x00
        XCTAssertNil(peBitnessMirror(b))
    }

    func testPEBitness_unknownMachineReturnsNil() {
        XCTAssertNil(peBitnessMirror(makePE(machine: 0x1234)))
    }

    // MARK: - Engine fingerprint

    /// Mirror of `GameStackDetector.fingerprintEngine`'s decision ordering.
    /// `dirNames` = lowercased names that are directories; `unrealBinaries` =
    /// top dirs that contain `Binaries/Win64`.
    private func fingerprintEngineMirror(
        top: [String],
        dirNames: Set<String>,
        unrealBinaries: Set<String> = []
    ) -> String {
        let lower = Set(top.map { $0.lowercased() })
        func isDir(_ n: String) -> Bool { dirNames.contains(n.lowercased()) }

        if lower.contains("unityplayer.dll")
            || lower.contains("unitycrashhandler64.exe")
            || lower.contains("unitycrashhandler32.exe")
            || top.contains(where: { $0.hasSuffix("_Data") && isDir($0) }) {
            return "unity"
        }
        if isDir("Engine") || top.contains(where: { $0.lowercased().hasSuffix("-shipping.exe") }) {
            return "unreal"
        }
        for entry in top where isDir(entry) {
            if unrealBinaries.contains(entry.lowercased()) { return "unreal" }
        }
        if isDir("bin") {
            let sourceish = top.contains { name in
                let l = name.lowercased()
                return l.hasSuffix(".vpk") || l.hasSuffix("_complete") || l == "platform"
                    || l == "hl2.exe" || l == "portal2.exe" || l == "left4dead2.exe"
            }
            if sourceish { return "source" }
        }
        if top.contains(where: { $0.lowercased().hasSuffix(".pck") }) { return "godot" }
        if top.contains(where: { $0.lowercased().hasSuffix(".exe") }) { return "custom" }
        return "unknown"
    }

    func testFingerprint_unityByDataFolder() {
        let r = fingerprintEngineMirror(
            top: ["MyGame.exe", "MyGame_Data"],
            dirNames: ["mygame_data"]
        )
        XCTAssertEqual(r, "unity")
    }

    func testFingerprint_unrealByShippingExe() {
        let r = fingerprintEngineMirror(
            top: ["ProjectCards.exe", "ProjectCards-Win64-Shipping.exe", "Engine"],
            dirNames: ["engine"]
        )
        XCTAssertEqual(r, "unreal")
    }

    func testFingerprint_unrealByBinariesWin64() {
        let r = fingerprintEngineMirror(
            top: ["Launcher.exe", "MyGame"],
            dirNames: ["mygame"],
            unrealBinaries: ["mygame"]
        )
        XCTAssertEqual(r, "unreal")
    }

    func testFingerprint_sourceByBinAndVpk() {
        let r = fingerprintEngineMirror(
            top: ["hl2.exe", "bin", "hl2_complete", "pak01_dir.vpk"],
            dirNames: ["bin", "hl2_complete"]
        )
        XCTAssertEqual(r, "source")
    }

    func testFingerprint_godotByPck() {
        let r = fingerprintEngineMirror(
            top: ["Game.exe", "Game.pck"],
            dirNames: []
        )
        XCTAssertEqual(r, "godot")
    }

    func testFingerprint_customWhenOnlyExe() {
        let r = fingerprintEngineMirror(top: ["weird.exe"], dirNames: [])
        XCTAssertEqual(r, "custom")
    }

    // MARK: - PCGamingWiki parsing

    /// Mirror of `PCGamingWikiService.parseEngine`.
    private func parseEngineMirror(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let l = raw.lowercased()
        if l.contains("unreal") { return "unreal" }
        if l.contains("unity")  { return "unity" }
        if l.contains("source") { return "source" }
        if l.contains("godot")  { return "godot" }
        return "custom"
    }

    /// Mirror of `PCGamingWikiService.parseDirect3D`.
    private func parseDirect3DMirror(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let l = raw.lowercased()
        if l.contains("12") { return "dx12" }
        if l.contains("11") || l.contains("10") { return "dx11" }
        if l.contains("9") || l.contains("8") || l.contains("7") { return "dx9" }
        return nil
    }

    func testParseEngine_variants() {
        XCTAssertEqual(parseEngineMirror("Engine:Unreal Engine 4"), "unreal")
        XCTAssertEqual(parseEngineMirror("Engine:Unity"), "unity")
        XCTAssertEqual(parseEngineMirror("Engine:Source"), "source")
        XCTAssertEqual(parseEngineMirror("Engine:Godot"), "godot")
        XCTAssertEqual(parseEngineMirror("Engine:Glacier 2"), "custom")
        XCTAssertNil(parseEngineMirror(nil))
        XCTAssertNil(parseEngineMirror(""))
    }

    func testParseDirect3D_picksMostCapable() {
        XCTAssertEqual(parseDirect3DMirror("11"), "dx11")
        XCTAssertEqual(parseDirect3DMirror("9.0c • 11"), "dx11") // 11 present, no 12
        XCTAssertEqual(parseDirect3DMirror("11 • 12"), "dx12")
        XCTAssertEqual(parseDirect3DMirror("12"), "dx12")
        XCTAssertEqual(parseDirect3DMirror("9.0c"), "dx9")
        XCTAssertNil(parseDirect3DMirror("unknown"))
        XCTAssertNil(parseDirect3DMirror(""))
        XCTAssertNil(parseDirect3DMirror(nil))
    }

    // MARK: - Resolver graphics-API priority

    /// Mirror of `GameStackResolver.merge`'s graphics-API selection:
    /// explicit › pcgw › detected › unknown. Returns the chosen value + source.
    private func mergeAPIMirror(explicit: String?, pcgw: String?, detected: String?) -> (api: String, source: String) {
        if let a = explicit, a != "unknown" { return (a, "explicit") }
        if let p = pcgw, p != "unknown" { return (p, "pcgw") }
        if let d = detected, d != "unknown" { return (d, "detected") }
        return ("unknown", "unknown")
    }

    func testMergeAPI_explicitWins() {
        let r = mergeAPIMirror(explicit: "dx11", pcgw: "dx12", detected: "dx9")
        XCTAssertEqual(r.api, "dx11"); XCTAssertEqual(r.source, "explicit")
    }

    func testMergeAPI_pcgwBeatsDetected() {
        let r = mergeAPIMirror(explicit: nil, pcgw: "dx12", detected: "dx11")
        XCTAssertEqual(r.api, "dx12"); XCTAssertEqual(r.source, "pcgw")
    }

    func testMergeAPI_detectedFallback() {
        let r = mergeAPIMirror(explicit: nil, pcgw: nil, detected: "dx11")
        XCTAssertEqual(r.api, "dx11"); XCTAssertEqual(r.source, "detected")
    }

    func testMergeAPI_allUnknown() {
        let r = mergeAPIMirror(explicit: "unknown", pcgw: nil, detected: "unknown")
        XCTAssertEqual(r.api, "unknown"); XCTAssertEqual(r.source, "unknown")
    }

    // MARK: - Wiring guards

    func testWiring_resolverSubsystemPresentAndIntegrated() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let resolver = try String(
            contentsOf: root.appendingPathComponent("Meridian/Engine/GameStackResolver.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(resolver.contains("enum GameStackDetector"),
                      "Local file detector must exist")
        XCTAssertTrue(resolver.contains("static func peBitness"),
                      "PE bitness reader must exist")
        XCTAssertTrue(resolver.contains("actor PCGamingWikiService"),
                      "PCGamingWiki service must exist")
        XCTAssertTrue(resolver.contains("cargoquery") && resolver.contains("Infobox_game,API"),
                      "PCGW fetch must join Infobox_game + API via the Cargo API")
        XCTAssertTrue(resolver.contains("Steam_AppID HOLDS"),
                      "PCGW query must look up by Steam AppID (HOLDS for the list column)")
        XCTAssertTrue(resolver.contains("final class GameStackResolver"),
                      "Resolver must exist")
        XCTAssertTrue(resolver.contains("func cached(appID:") && resolver.contains("func resolve("),
                      "Resolver must expose cached() (sync read) + resolve() (async warm)")

        // SteamSession routes detected/PCGW DX12 games through GPTK.
        let session = try String(
            contentsOf: root.appendingPathComponent("Meridian/Steam/SteamSession.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(session.contains("GameStackResolver.shared.cached(appID: appID)"),
                      "gameEnvironment must read the resolved graphics API so DX12 games without an explicit profile still get GPTK")
        XCTAssertTrue(session.contains("effectiveAPI == .dx12"),
                      "gameEnvironment must route the EFFECTIVE DX12 api through GPTK, not just explicit-profile DX12")

        // Launcher warms the resolver before building the env.
        let launcher = try String(
            contentsOf: root.appendingPathComponent("Meridian/Launch/Launcher.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(launcher.contains("GameStackResolver.shared.resolve(appID:"),
                      "Launcher must warm the resolver cache before gameEnvironment reads it")

        // Info.plist must allow the PCGamingWiki domain under ATS.
        let plist = try String(
            contentsOf: root.appendingPathComponent("Meridian/Info.plist"),
            encoding: .utf8
        )
        XCTAssertTrue(plist.contains("pcgamingwiki.com"),
                      "Info.plist NSExceptionDomains must include pcgamingwiki.com for the Cargo API")

        // New file must be registered in the Xcode project.
        let pbx = try String(
            contentsOf: root.appendingPathComponent("Meridian.xcodeproj/project.pbxproj"),
            encoding: .utf8
        )
        XCTAssertTrue(pbx.contains("GameStackResolver.swift"),
                      "GameStackResolver.swift must be registered in project.pbxproj or the Xcode build won't compile it")
    }
}
