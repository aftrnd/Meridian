import XCTest

/// Guard tests for launching: every game goes through the real Steam client
/// (`-applaunch`), started silently, so cloud saves, achievements and
/// multiplayer always work. The per-game Offline mode (gbe_fork emulator +
/// direct wine64) was removed Oct 8 2026.
final class LaunchModeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Launcher wiring

    func testOnlineMode_usesSteamApplaunchNotGbeFork() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        guard let fn = src.range(of: "func launchOnline(") else {
            return XCTFail("launchOnline must exist")
        }
        // Bound the search to the launchOnline body (up to the next `// MARK:`).
        let after = src[fn.lowerBound...]
        let body = String(after.prefix(through: after.range(of: "// MARK:")?.lowerBound ?? after.endIndex))

        XCTAssertTrue(body.contains("ensureReadyForDRM"),
                      "Online mode must bring the real Steam client online via ensureReadyForDRM.")
        XCTAssertTrue(body.contains("launchGameViaSteam"),
                      "Online mode must dispatch -applaunch via session.launchGameViaSteam.")
        XCTAssertFalse(body.contains("installSteamEmulator"),
                       "Online mode must NOT install the gbe_fork shim — the game must talk to Valve, not a local emulator.")
        XCTAssertFalse(body.contains("launchDirect("),
                       "Online mode must NOT launchDirect — Steam owns the launch (avoids the custom-args dialog, Pattern 20).")
    }

    // MARK: - SteamStub detection

    /// Mirror of GameStackDetector.hasSteamStub (the `.bind` PE section probe).
    private func hasSteamStub(exe: URL) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: exe) else { return false }
        defer { try? fh.close() }

        guard let dosData = try? fh.read(upToCount: 0x40), dosData.count >= 0x40 else { return false }
        let dos = [UInt8](dosData)
        guard dos[0] == 0x4D, dos[1] == 0x5A else { return false }
        let eLfanew = Int(dos[0x3C]) | Int(dos[0x3D]) << 8 | Int(dos[0x3E]) << 16 | Int(dos[0x3F]) << 24
        guard eLfanew > 0, eLfanew < 4_000_000 else { return false }

        try? fh.seek(toOffset: UInt64(eLfanew))
        guard let coffData = try? fh.read(upToCount: 24), coffData.count >= 24 else { return false }
        let coff = [UInt8](coffData)
        guard coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else { return false }
        let numberOfSections     = Int(coff[6])  | Int(coff[7])  << 8
        let sizeOfOptionalHeader = Int(coff[20]) | Int(coff[21]) << 8

        try? fh.seek(toOffset: UInt64(eLfanew + 24 + sizeOfOptionalHeader))
        let tableSize = min(numberOfSections, 96) * 40
        guard tableSize > 0, let table = try? fh.read(upToCount: tableSize), table.count >= 40 else { return false }
        let bytes = [UInt8](table)
        let bind: [UInt8] = [0x2E, 0x62, 0x69, 0x6E, 0x64]
        for i in stride(from: 0, to: bytes.count - 39, by: 40) {
            if Array(bytes[i..<(i + 5)]) == bind, bytes[i + 5] == 0 { return true }
        }
        return false
    }

    /// Builds a minimal synthetic PE with the given section names
    /// (DOS header → PE sig → COFF with SizeOfOptionalHeader=0 → section table).
    private func makeFakePE(sections: [String]) -> Data {
        var d = Data(count: 0x40)
        d[0] = 0x4D; d[1] = 0x5A          // "MZ"
        d[0x3C] = 0x40                     // e_lfanew = 0x40
        var coff = Data([0x50, 0x45, 0, 0]) // "PE\0\0"
        coff += Data([0x64, 0x86])          // Machine = x64
        let n = UInt16(sections.count)
        coff += Data([UInt8(n & 0xFF), UInt8(n >> 8)])
        coff += Data(count: 12)             // TimeDateStamp, SymTab ptr, NumSyms
        coff += Data([0, 0])                // SizeOfOptionalHeader = 0
        coff += Data([0, 0])                // Characteristics
        d += coff
        for s in sections {
            var name = Data(s.utf8.prefix(8))
            name += Data(count: 8 - name.count)
            d += name + Data(count: 32)
        }
        return d
    }

    func testHasSteamStub_detectsBindSection() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "steamstub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stubbed = tmp.appending(path: "stubbed.exe")
        try makeFakePE(sections: [".text", ".rdata", ".bind"]).write(to: stubbed)
        XCTAssertTrue(hasSteamStub(exe: stubbed),
                      "A PE with a .bind section is SteamStub-wrapped and must be detected")

        let clean = tmp.appending(path: "clean.exe")
        try makeFakePE(sections: [".text", ".rdata", ".data"]).write(to: clean)
        XCTAssertFalse(hasSteamStub(exe: clean),
                       "A PE without .bind must NOT be flagged as SteamStub")

        // `.bindat` (prefix collision) must not false-positive: the production
        // check requires the name to be exactly ".bind" (NUL-terminated).
        let collide = tmp.appending(path: "collide.exe")
        try makeFakePE(sections: [".text", ".bindat"]).write(to: collide)
        XCTAssertFalse(hasSteamStub(exe: collide),
                       "Section names that merely START with .bind must not match")

        let notPE = tmp.appending(path: "not-pe.exe")
        try Data("hello".utf8).write(to: notPE)
        XCTAssertFalse(hasSteamStub(exe: notPE), "Non-PE files must return false")
    }

    // MARK: - One-time Steam sign-in

    /// Online mode's auth contract (HANDOFF-2026-07-02-v2/v3):
    /// - Injected tokens are REJECTED by Valve's CM (Pattern 6) and feed the
    ///   anti-abuse lockout (Pattern 23) — ensureReadyForDRM must NOT inject.
    /// - The one-time interactive sign-in (Steam's own window, no -silent) is
    ///   the sanctioned way to establish a session; Steam persists it itself,
    ///   so later launches take the silent path.
    /// - No Steam window may open without user consent: launchOnline raises
    ///   signInRequired first, and only proceeds after confirmSteamPrompt.
    func testOnlineMode_oneTimeInteractiveSignIn() throws {
        let session = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(session.contains("func signInInteractively("),
                      "SteamSession must implement the interactive sign-in")
        XCTAssertTrue(session.contains("interactive: Bool = false"),
                      "launchSteamProcess must support an interactive (no -silent) launch")
        XCTAssertTrue(session.contains("? [steamExePath, \"-nofriendsui\"]"),
                      "Interactive launch must omit -silent so Steam renders its sign-in window")
        XCTAssertTrue(session.contains("func waitForInteractiveLogon("),
                      "Interactive sign-in must use the no-auth-deadline logon wait (user is typing)")

        // The dead injection path must stay out of ensureReadyForDRM.
        if let fn = session.range(of: "func ensureReadyForDRM(") {
            let after = session[fn.lowerBound...]
            let body = String(after.prefix(through: after.range(of: "// MARK:")?.lowerBound ?? after.endIndex))
            // Match the CALL syntax specifically — the doc comment legitimately
            // names the function while explaining why it must not be called.
            XCTAssertFalse(body.contains("prefix.writeSteamSessionLocalVdf("),
                           "ensureReadyForDRM must NOT inject the OAuth token into local.vdf — CM rejects it (Pattern 6) and it feeds the anti-abuse lockout (Pattern 23)")
        } else {
            XCTFail("ensureReadyForDRM must exist")
        }

        let launcher = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(launcher.contains("AppSettings.shared.steamClientSignedIn"),
                      "launchOnline must branch silent-vs-interactive on Meridian's record of Steam's sign-in, not on Steam's files")
        XCTAssertTrue(launcher.contains(".signInRequired(game)"),
                      "First-time Online must raise the consent prompt before any Steam window opens")
        XCTAssertTrue(launcher.contains("signInInteractively"),
                      "launchOnline must fall back to the interactive sign-in")

        let detail = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(detail.contains("launcher.steamPrompt") && detail.contains("confirmSteamPrompt"),
                      "GameDetailView must render the Steam consent prompt and wire confirm/dismiss")
    }

    /// Valve can end Steam's saved sign-in on its own (meridian.log Oct 11
    /// 2026: 'Access Denied' for a sign-in that logged on 7 times on Oct 8).
    /// Meridian forgets the sign-in and, inside the same launch, opens Steam's
    /// sign-in with the card saying why. An alert and then a fresh launch
    /// read as a restart (user, Oct 11 2026).
    func testSteamSignOut_signsInWithinTheSameLaunch() throws {
        let session = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(session.contains("log.error(\"[waitForLoggedOn] Valve rejected token — auth failed\")\n                killWebhelper()\n                return .signedOut"),
                      "A Valve rejection must come back as .signedOut, not a generic failure")
        guard let mark = session.range(of: "private func markSignedOut()") else {
            return XCTFail("SteamSession must have markSignedOut()")
        }
        let markBody = String(session[mark.upperBound...].prefix(400))
        XCTAssertTrue(markBody.contains("AppSettings.shared.steamClientSignedIn = false"),
                      "A sign-out must clear Meridian's record of Steam's sign-in so a later cold launch asks first")
        XCTAssertTrue(markBody.contains("SteamSessionBackup.clear()"),
                      "A sign-out must drop the session backup, which would only restore the rejected sign-in")
        XCTAssertTrue(session.contains("throw state == .signedOut ? SessionError.signedOut : SessionError.steamNotReady"),
                      "ensureReadyForDRM must tell a sign-out apart from other failures")

        let launcher = try readSource("Meridian/Launch/Launcher.swift")
        guard let catchSignOut = launcher.range(of: "} catch SessionError.signedOut where !Task.isCancelled {") else {
            return XCTFail("launchOnline must catch a Steam sign-out separately")
        }
        let branch = String(launcher[catchSignOut.upperBound...].prefix(900))
        let signOutBranch = String(branch[..<(branch.range(of: "} catch {")?.lowerBound ?? branch.endIndex)])
        XCTAssertTrue(signOutBranch.contains("try await signInToSteam(.signedOut, appID: game.id, session: session, engine: engine)"),
                      "A sign-out must continue into Steam's sign-in within the same launch")
        XCTAssertFalse(signOutBranch.contains("steamPrompt") || signOutBranch.contains("launchState = .idle"),
                       "A sign-out must not end the launch and start over")
    }

    /// Steam boots in the background once the library is up, so Play doesn't
    /// wait on it. A Play during the warm-up must JOIN it (start() skips while
    /// .startingSilent, so racing it reported "not ready" mid-boot), and a
    /// sign-out the warm-up found sends Play straight to Steam's sign-in.
    func testSteamWarmUp_isJoinedByPlay() throws {
        let session = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(session.contains("guard warmUpTask == nil, AppSettings.shared.steamClientSignedIn else { return }"),
                      "Warm-up only for a Mac where Steam's own sign-in succeeded (no sign-in window from the background)")
        XCTAssertTrue(session.contains("guard state == .idle || missingGame else { return }"),
                      "Warm-up starts an idle Steam, or restarts a running one only for a game it hasn't loaded")
        XCTAssertTrue(session.contains("if let warmUpTask {"),
                      "ensureReadyForDRM must wait for a running warm-up instead of racing it")
        XCTAssertTrue(session.contains("try await bringUpForDRM(engine: engine, appID: appID, onStatus: nil)"),
                      "The warm-up must use the inner bring-up, or it would wait on itself")

        let launcher = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(launcher.contains("let signedOut = session.state == .signedOut"),
                      "Play must use a sign-out the warm-up already found")
        XCTAssertTrue(launcher.contains("try await signInToSteam(.signedOut, appID: game.id, session: session, engine: engine)"),
                      "A known sign-out goes straight to Steam's sign-in")
        XCTAssertTrue(launcher.contains("session.warmUp(engine: engine, appID: game.id)"),
                      "A finished install brings Steam up with the new game, so its first Play doesn't wait")

        let content = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertTrue(content.contains("session.warmUp(engine: engine)"),
                      "The app must warm Steam up once the library is loaded")
    }

    /// Steam reads appmanifest_*.acf once per start. A game Meridian installs
    /// while Steam runs (DepotDownloader) is unknown to it, and -applaunch
    /// fails at once with AppError_18 (Steam console_log, Oct 12 2026:
    /// Endacopia and The Baby in Yellow, both installed after Steam started).
    /// Play restarts Steam first for such a game.
    func testGameInstalledAfterSteamStarted_restartsSteamBeforeLaunch() throws {
        let session = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(session.contains("appsSteamLoaded = prefix.appManifestIDs()"),
                      "Every steam.exe start must record which games Steam loaded")
        XCTAssertTrue(session.contains("} else if let appID, !appsSteamLoaded.contains(appID) {"),
                      "A ready Steam that never loaded the game must be restarted before -applaunch")

        let launcher = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(launcher.contains("try await session.ensureReadyForDRM(engine: engine, appID: game.id)"),
                      "Play must tell Steam's bring-up which game it is for")
        XCTAssertTrue(launcher.contains("try await session.ensureReadyForDRM(engine: engine, appID: appID)"),
                      "The bring-up after Steam's sign-in must check the game too")
    }

    func testEveryLaunchGoesThroughSteam_withItsArguments() throws {
        let launcher = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(launcher.contains("await launchOnline(game: game, engine: engine, session: session, library: library)"),
                      "The pipeline must hand every game to launchOnline.")
        XCTAssertFalse(launcher.contains("func launchDirect("),
                       "There is no direct wine64 launch path any more.")
        XCTAssertTrue(launcher.contains("launchArguments(for: game, engine: engine)"),
                      "Compat-profile arguments (HL2 -game, Unity -force-d3d11) must still reach the game through Steam.")

        let session = try readSource("Meridian/Steam/SteamSession.swift")
        XCTAssertTrue(session.contains(#"["-applaunch", "\(appID)"] + arguments"#),
                      "launchGameViaSteam must forward the arguments after -applaunch <appID>.")

        let settings = try readSource("Meridian/Models/AppSettings.swift")
        XCTAssertFalse(settings.contains("enum LaunchMode"), "There is no per-game launch mode setting.")
        let detail = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertFalse(detail.contains("Play Online"), "The Play button has no Online/Offline variant.")
        XCTAssertFalse(detail.contains("launchModePopover"), "There is no launch-mode picker.")
    }

}
