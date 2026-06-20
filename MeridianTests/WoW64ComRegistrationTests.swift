import XCTest

/// Architectural-invariant guard for the 32-bit (WoW64) COM class registration
/// that restores audio (and DirectInput / WMI) to 32-bit games such as
/// Half-Life 2 (engine-research-findings.mdc Pattern 7 / Pattern 11 family).
///
/// CLI-confirmed root cause (2026-06-19): the prefix template Wine ships has
/// the 64-bit `HKLM\Software\Classes\CLSID` hive fully populated (1935 classes)
/// but the 32-bit `Software\Classes\Wow6432Node\CLSID` view EMPTY — the
/// `release-engine.sh` `wineboot --init` was killed before its 32-bit wine.inf
/// registration pass ran. A 32-bit (WoW64) process resolving a class through
/// `HKCR\CLSID` is redirected to the empty Wow6432Node view, so
/// `CoCreateInstance` returns `REGDB_E_CLASSNOTREG` (0x80040154).
///
/// Half-Life 2 (32-bit) logged `class {bcde0395-...} not registered` →
/// `dsound:get_mmdevenum CoCreateInstance failed: 80040154` → no audio device →
/// NO SOUND. CLI-verified: a 32-bit `CoCreateInstance(CLSID_MMDeviceEnumerator)`
/// returned 0x80040154 before the registration and S_OK after.
///
/// These tests grep the production source so a refactor that drops the
/// registration, removes a required class, or fails to wire it into the
/// bootstrap pipeline trips during `swift test`.
final class WoW64ComRegistrationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MeridianTests/
            .deletingLastPathComponent()  // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - WinePrefix.swift invariants

    func testWinePrefixDeclaresRegisterWoW64ComClasses() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(
            src.contains("func registerWoW64ComClasses(engine: WineEngine) async"),
            "WinePrefix must declare `func registerWoW64ComClasses(engine: WineEngine) async` — restores audio/input/WMI to 32-bit games (HL2)"
        )
    }

    func testRegisterWoW64ComClassesCoversAudioInputAndWMI() throws {
        let src = try readSource("Meridian/Engine/WinePrefix.swift")
        guard let funcRange = src.range(of: "func registerWoW64ComClasses(engine: WineEngine) async"),
              let bodyStart = src.range(of: "{", range: funcRange.upperBound..<src.endIndex)
        else {
            XCTFail("Could not locate registerWoW64ComClasses body"); return
        }
        let body = String(src[bodyStart.lowerBound...])

        // MMDeviceEnumerator (audio) is the mandatory one — its absence is the
        // direct cause of "no sound" in 32-bit games.
        XCTAssertTrue(
            body.contains("BCDE0395-E52F-467C-8E3D-C4579291692E"),
            "must register MMDeviceEnumerator {BCDE0395-...} → mmdevapi.dll — without it 32-bit games have NO SOUND"
        )
        XCTAssertTrue(
            body.contains("mmdevapi.dll"),
            "MMDeviceEnumerator must map to mmdevapi.dll"
        )
        XCTAssertTrue(
            body.contains("25E609E4-B259-11CF-BFC7-444553540000") && body.contains("dinput8.dll"),
            "must register DirectInput8 {25E609E4-...} → dinput8.dll (32-bit game input)"
        )
        XCTAssertTrue(
            body.contains("4590F811-1D3A-11D0-891F-00AA004B2E24"),
            "must register the WBEM locator {4590F811-...} (32-bit WMI startup queries)"
        )

        // Must register into the 32-bit WoW64 view (NOT the 64-bit hive, which
        // is already populated). And must dispatch via reg add, not FileHandle.
        XCTAssertTrue(
            body.contains(#"Wow6432Node\CLSID"#),
            "must write to the 32-bit `Software\\Classes\\Wow6432Node\\CLSID` view (the empty one), not the populated 64-bit hive"
        )
        XCTAssertTrue(
            body.contains(#"\InprocServer32"#) && body.contains("ThreadingModel"),
            "each class needs an InprocServer32 subkey + ThreadingModel=Both (mirrors the working 64-bit entries)"
        )
        XCTAssertTrue(
            body.contains("engine.run(args:"),
            "must persist classes via `engine.run(args: [\"reg\", \"add\", ...])` (wineserver-resolved), never FileHandle surgery"
        )
        XCTAssertFalse(
            body.contains("FileHandle"),
            "must not write system.reg via FileHandle"
        )
    }

    // MARK: - BootstrapManager.swift wiring

    func testBootstrapAppliesWoW64ComRegistration() throws {
        let src = try readSource("Meridian/App/BootstrapManager.swift")
        XCTAssertTrue(
            src.contains("await prefix.registerWoW64ComClasses(engine: engine)"),
            "BootstrapManager must `await prefix.registerWoW64ComClasses(engine: engine)` in step 3 registry setup"
        )
        XCTAssertTrue(
            src.contains("settings.wow64ComRegistrationAppliedVersion = WinePrefix.wow64ComRegistrationVersion"),
            "BootstrapManager must persist the applied version after registering"
        )
        XCTAssertTrue(
            src.contains("settings.wow64ComRegistrationAppliedVersion = 0"),
            "resetVersionedRegistryCounters must zero wow64ComRegistrationAppliedVersion so a (re)built prefix re-applies the registration"
        )
    }
}
