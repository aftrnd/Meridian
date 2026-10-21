import XCTest
@testable import Meridian

/// Engine updates lay the new engine's prefix template over the prefix
/// (`WinePrefix.applyEngineTemplate`) instead of deleting it. Each deleted-and-
/// restored round lost something: accepted EULAs, the MachineGuid Steam's
/// saved sign-in is tied to, Steam's own service (engine-research Pattern 58).
final class EngineTemplateUpdateTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "EngineTemplateUpdateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    /// Wine registry text in the engine's format: keys as Wine writes them
    /// (`Software\\Valve\\Steam`), each followed by a blank line.
    private func hive(_ keys: [(String, [String])]) -> String {
        var lines = ["WINE REGISTRY Version 2", #";; All keys relative to REGISTRY\\Machine"#, "", "#arch=win64", ""]
        for (key, values) in keys {
            lines += ["[\(key)] 1792530437", "#time=1dd60d6fd32d0ca"] + values + [""]
        }
        return lines.joined(separator: "\n")
    }

    private func write(_ text: String, _ root: URL, _ relative: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ root: URL, _ relative: String) -> String? {
        try? String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }

    private let cryptography = #"Software\\Microsoft\\Cryptography"#

    /// A template, an installed prefix with user state in every place the old
    /// reset lost it, and an engine i386 directory.
    private func makeUpdateFixture() throws -> (template: URL, prefix: URL, i386: URL) {
        let template = tempDir.appending(path: "engine/prefix-template")
        try write(hive([
            (cryptography, [#""MachineGuid"="9a6a7b0e-1942-4698-9ad2-239a9ca70b58""#]),
            (#"Software\\Wine\\Engine"#, [#""Version"="new""#]),
        ]), template, "system.reg")
        try write(hive([(#"Software\\Wine\\Fonts"#, [#""Engine"="new""#])]), template, "user.reg")
        try write("userdef", template, "userdef.reg")
        try write("2", template, ".update-timestamp")
        try write("new", template, "drive_c/windows/system32/kernel32.dll")
        try write("template", template, "drive_c/users/steamuser/AppData/Local/Microsoft/desktop.ini")
        try FileManager.default.createDirectory(
            at: template.appending(path: "drive_c/Program Files (x86)/Common Files"),
            withIntermediateDirectories: true
        )

        let prefix = tempDir.appending(path: "bottles/steam")
        try write(hive([
            (cryptography, [#""MachineGuid"="2210b9eb-4578-4d98-8d08-8bda454c32df""#]),
            (#"Software\\Wine\\Engine"#, [#""Version"="old""#]),
            (#"System\\ControlSet001\\Services\\Steam Client Service"#,
             [#""ImagePath"="C:\\Program Files (x86)\\Common Files\\Steam\\steamservice.exe""#]),
        ]), prefix, "system.reg")
        try write(hive([
            (#"Software\\Valve\\Steam"#, [#""AutoLoginUser"="player""#]),
            (#"Software\\Fake Studio\\Fake Game"#, [#""Volume_h123"=dword:00000001"#]),
        ]), prefix, "user.reg")
        try write("1", prefix, ".update-timestamp")
        try write("old", prefix, "drive_c/windows/system32/kernel32.dll")
        try write("native", prefix, "drive_c/windows/system32/physxloader.dll")
        try write("client", prefix, "drive_c/Program Files (x86)/Steam/steam.exe")
        try write(#""3124540_eula_0" "6""#, prefix, "drive_c/Program Files (x86)/Steam/userdata/1/config/localconfig.vdf")
        try write("service", prefix, "drive_c/Program Files (x86)/Common Files/Steam/steamservice.exe")
        try write("token", prefix, "drive_c/users/steamuser/AppData/Local/Steam/local.vdf")
        try write("mine", prefix, "drive_c/users/steamuser/AppData/Local/Microsoft/desktop.ini")

        let i386 = tempDir.appending(path: "engine/wine/lib/wine/i386-windows")
        for file in ["kernel32.dll", "winemac.drv", "README"] {
            try write("i386", i386, file)
        }
        return (template, prefix, i386)
    }

    // MARK: - applyEngineTemplate

    func testUpdate_replacesEngineFilesAndKeepsEverythingElse() throws {
        let (template, prefix, i386) = try makeUpdateFixture()

        _ = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        XCTAssertEqual(read(prefix, "drive_c/windows/system32/kernel32.dll"), "new", "engine files come from the template")
        XCTAssertEqual(read(prefix, ".update-timestamp"), "2", "the timestamp must match the new engine, or Wine runs wineboot --update")
        XCTAssertEqual(read(prefix, "drive_c/windows/system32/physxloader.dll"), "native", "files an installer wrote stay")
        XCTAssertEqual(read(prefix, "drive_c/Program Files (x86)/Steam/steam.exe"), "client", "the Steam client stays")
        XCTAssertEqual(read(prefix, "drive_c/Program Files (x86)/Steam/userdata/1/config/localconfig.vdf"),
                       #""3124540_eula_0" "6""#, "accepted EULAs stay")
        XCTAssertEqual(read(prefix, "drive_c/Program Files (x86)/Common Files/Steam/steamservice.exe"), "service",
                       "Steam's service binary lives outside the Steam folder and must stay")
        XCTAssertEqual(read(prefix, "drive_c/users/steamuser/AppData/Local/Steam/local.vdf"), "token", "Steam's sign-in stays")
        XCTAssertEqual(read(prefix, "drive_c/users/steamuser/AppData/Local/Microsoft/desktop.ini"), "mine",
                       "the template never overwrites a file in the user profile")
    }

    func testUpdate_mergesTheRegistry() throws {
        let (template, prefix, i386) = try makeUpdateFixture()

        _ = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        let system = try XCTUnwrap(read(prefix, "system.reg"))
        let user = try XCTUnwrap(read(prefix, "user.reg"))
        XCTAssertTrue(system.contains(#""Version"="new""#), "a key the template defines comes from the template")
        XCTAssertFalse(system.contains(#""Version"="old""#))
        XCTAssertTrue(system.contains(#"[System\\ControlSet001\\Services\\Steam Client Service]"#),
                      "Steam's service registration stays; without it Steam sits on a hidden Steam Service Error")
        XCTAssertTrue(user.contains(#"[Software\\Valve\\Steam]"#), "Steam's settings stay")
        XCTAssertTrue(user.contains(#""Volume_h123"=dword:00000001"#), "games' own keys (Unity PlayerPrefs) stay")
        XCTAssertTrue(user.contains(#""Engine"="new""#), "the template's user keys arrive")
        XCTAssertTrue(user.hasPrefix("WINE REGISTRY Version 2"))
    }

    func testUpdate_keepsThePrefixMachineGuid() throws {
        let (template, prefix, i386) = try makeUpdateFixture()

        let update = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        let system = try XCTUnwrap(read(prefix, "system.reg"))
        XCTAssertEqual(WinePrefix.machineGuid(inSystemReg: system), "2210b9eb-4578-4d98-8d08-8bda454c32df",
                       "Steam's machine ID hashes the MachineGuid; the template's would sign Steam out")
        XCTAssertFalse(system.contains("9a6a7b0e-1942-4698-9ad2-239a9ca70b58"))
        XCTAssertEqual(update.keptMachineGuid, "2210b9eb-4578-4d98-8d08-8bda454c32df")
    }

    func testUpdate_isIdempotent() throws {
        let (template, prefix, i386) = try makeUpdateFixture()

        _ = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)
        let system = read(prefix, "system.reg")
        let user = read(prefix, "user.reg")
        _ = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        XCTAssertEqual(read(prefix, "system.reg"), system, "an interrupted update is retried on the next launch")
        XCTAssertEqual(read(prefix, "user.reg"), user)
    }

    func testUpdate_createsDosdevicesAndFillsSyswow64() throws {
        let (template, prefix, i386) = try makeUpdateFixture()

        let update = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        let fm = FileManager.default
        let dosdev = prefix.appending(path: "dosdevices")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dosdev.appending(path: "c:").path(percentEncoded: false)), "../drive_c")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dosdev.appending(path: "z:").path(percentEncoded: false)), "/",
                       "z: is required for host-path resolution (SteamSetup.exe)")
        let syswow64 = prefix.appending(path: "drive_c/windows/syswow64")
        XCTAssertTrue(fm.fileExists(atPath: syswow64.appending(path: "kernel32.dll").path(percentEncoded: false)))
        XCTAssertTrue(fm.fileExists(atPath: syswow64.appending(path: "winemac.drv").path(percentEncoded: false)))
        XCTAssertFalse(fm.fileExists(atPath: syswow64.appending(path: "README").path(percentEncoded: false)))
        XCTAssertEqual(update.syswow64Added, 2)
    }

    /// A prefix whose engine named the Windows user differently keeps its
    /// profile under the current name (Pattern 45).
    func testUpdate_renamesAnOlderProfile() throws {
        let (template, prefix, i386) = try makeUpdateFixture()
        let users = prefix.appending(path: "drive_c/users")
        try FileManager.default.moveItem(at: users.appending(path: "steamuser"), to: users.appending(path: "crossover"))

        let update = try WinePrefix.applyEngineTemplate(template, to: prefix, engineI386: i386)

        XCTAssertEqual(update.renamedProfile, "crossover")
        XCTAssertEqual(read(prefix, "drive_c/users/steamuser/AppData/Local/Steam/local.vdf"), "token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: users.appending(path: "crossover").path(percentEncoded: false)))
    }

    /// The template's profile links to the Mac's folders (Music, Desktop).
    /// They must arrive as links; following one would copy the folder.
    func testOverlay_copiesSymlinksWithoutFollowingThem() throws {
        let fm = FileManager.default
        let macFolder = tempDir.appending(path: "Music")
        try write("song", macFolder, "song.mp3")
        let template = tempDir.appending(path: "template")
        let link = template.appending(path: "drive_c/users/steamuser/Music")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: macFolder)
        // The profile folder exists, so the walk reaches the link itself.
        let prefix = tempDir.appending(path: "prefix")
        try fm.createDirectory(at: prefix.appending(path: "drive_c/users/steamuser"), withIntermediateDirectories: true)

        let result = try WinePrefix.overlay(template, onto: prefix)

        let copiedLink = prefix.appending(path: "drive_c/users/steamuser/Music").path(percentEncoded: false)
        XCTAssertEqual(try fm.attributesOfItem(atPath: copiedLink)[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: copiedLink), macFolder.path(percentEncoded: false))
        XCTAssertEqual(result.copied, 1, "the link alone is copied; the walk does not descend into it")
    }

    /// A PE file: MZ, e_lfanew past the signature area, and Wine's marker
    /// right after the DOS header when `wine` is set.
    private func pe(wine signature: String?, _ body: String) -> Data {
        var bytes = [UInt8](repeating: 0, count: 128)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes[60] = 128
        if let signature {
            bytes.replaceSubrange(64..<64 + signature.utf8.count, with: Array(signature.utf8))
        }
        return Data(bytes) + Data(body.utf8)
    }

    /// Wine's rule (setupapi fakedll.c): its own DLL never replaces one that
    /// isn't Wine's. Steam's redistributable installers put Microsoft's
    /// runtimes in system32 and record that in the registry, which the
    /// update keeps, so replacing them would leave Steam's record false.
    func testOverlay_keepsNativeDLLsAndReplacesWineOnes() throws {
        let fm = FileManager.default
        let template = tempDir.appending(path: "template")
        let prefix = tempDir.appending(path: "prefix")
        let system32 = "drive_c/windows/system32"
        for root in [template, prefix] {
            try fm.createDirectory(at: root.appending(path: system32), withIntermediateDirectories: true)
        }
        try pe(wine: "Wine builtin DLL", "new").write(to: template.appending(path: "\(system32)/msvcp140.dll"))
        try pe(wine: "Wine builtin DLL", "new").write(to: template.appending(path: "\(system32)/d3d11.dll"))
        try pe(wine: "Wine builtin DLL", "new").write(to: template.appending(path: "\(system32)/xinput1_3.dll"))
        try pe(wine: nil, "microsoft").write(to: prefix.appending(path: "\(system32)/msvcp140.dll"))
        try pe(wine: "Wine builtin DLL", "old").write(to: prefix.appending(path: "\(system32)/d3d11.dll"))
        try pe(wine: "Wine placeholder DLL", "old").write(to: prefix.appending(path: "\(system32)/xinput1_3.dll"))

        let result = try WinePrefix.overlay(template, onto: prefix)

        let body = { (name: String) in
            (try? Data(contentsOf: prefix.appending(path: "\(system32)/\(name)"))).map { String(decoding: $0.dropFirst(128), as: UTF8.self) }
        }
        XCTAssertEqual(body("msvcp140.dll"), "microsoft", "Microsoft's runtime stays")
        XCTAssertEqual(body("d3d11.dll"), "new", "an older Wine builtin is replaced")
        XCTAssertEqual(body("xinput1_3.dll"), "new", "a Wine placeholder is replaced")
        XCTAssertEqual(result.nativeKept, 1)
        XCTAssertTrue(WinePrefix.isWineBuiltin(prefix.appending(path: "\(system32)/d3d11.dll")))
        XCTAssertFalse(WinePrefix.isWineBuiltin(prefix.appending(path: "\(system32)/msvcp140.dll")))
    }

    // MARK: - mergedRegistry

    /// Registry keys are case-insensitive: one key spelled two ways must not
    /// end up twice (Wine would load both and the later one wins).
    func testMergedRegistry_matchesKeysCaseInsensitively() {
        let installed = hive([(#"Software\\Wine\\FONTS"#, [#""Engine"="old""#])])
        let template = hive([(#"Software\\Wine\\Fonts"#, [#""Engine"="new""#])])

        let merge = WinePrefix.mergedRegistry(installed: installed, template: template)

        XCTAssertEqual(merge.keptKeys, 0)
        XCTAssertFalse(merge.text.contains("old"))
    }

    /// Multi-line hex values (continuation lines) travel with their key.
    func testMergedRegistry_keepsMultiLineValuesWhole() {
        let value = [#""Blob"=hex:00,01,02,\"#, "  03,04,05"]
        let installed = hive([(#"Software\\Fake Studio\\Fake Game"#, value)])
        let template = hive([(#"Software\\Wine"#, [])])

        let merge = WinePrefix.mergedRegistry(installed: installed, template: template)

        XCTAssertEqual(merge.keptKeys, 1)
        XCTAssertTrue(merge.text.contains(value.joined(separator: "\n")))
    }
}
