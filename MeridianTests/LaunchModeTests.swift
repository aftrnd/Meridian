import XCTest

/// Guard tests for Phase A3 — per-game Offline (gbe_fork) vs Online
/// (real steam.exe `-applaunch`) launch modes.
///
/// Offline is the default (proven, seamless, no cloud/multiplayer). Online is
/// an opt-in that brings the real Steam client online in the background so
/// cloud saves, online multiplayer, EULAs, and genuine DRM work.
final class LaunchModeTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - AppSettings persistence contract

    func testAppSettings_defaultsToOfflineAndPersistsOnlineOptIn() throws {
        let src = try readSource("Meridian/Models/AppSettings.swift")
        XCTAssertTrue(src.contains("enum LaunchMode"),
                      "AppSettings must define a LaunchMode enum.")
        XCTAssertTrue(src.contains("case offline") && src.contains("case online"),
                      "LaunchMode must have offline + online cases.")
        XCTAssertTrue(src.contains("func launchMode(appID:"),
                      "AppSettings must expose launchMode(appID:).")
        XCTAssertTrue(src.contains("func setLaunchMode("),
                      "AppSettings must expose setLaunchMode(_:appID:).")
        // Default must be Offline: the getter returns .online ONLY when the
        // appID is in the opt-in set, else .offline.
        XCTAssertTrue(src.contains("onlineModeAppIDs.contains(appID) ? .online : .offline"),
                      "launchMode must default to .offline (Online is opt-in only).")
    }

    // MARK: - Launcher wiring

    func testLauncher_branchesOnLaunchMode() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("AppSettings.shared.launchMode(appID:"),
                      "Launcher must consult AppSettings.launchMode to pick Offline vs Online.")
        XCTAssertTrue(src.contains("func launchOnline("),
                      "Launcher must implement the Online-mode launch path.")
        XCTAssertTrue(src.contains("== .online"),
                      "Launcher must branch to Online when launchMode == .online.")
    }

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

    func testOfflineMode_remainsGbeForkDefault() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        // The default (non-online) path must still use the gbe_fork shim +
        // direct exec that is proven reliable today.
        XCTAssertTrue(src.contains("installSteamEmulator"),
                      "Offline (default) path must keep the gbe_fork Steamworks shim.")
        XCTAssertTrue(src.contains("launchDirect("),
                      "Offline (default) path must keep direct wine64 exec.")
    }

    // MARK: - UI toggle (split Play button, HANDOFF-2026-07-03-v6 Goal 1)

    func testGameDetail_exposesLaunchModePicker() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("launchModeBinding"),
                      "GameDetailView must bind the launch-mode control to AppSettings.")
        XCTAssertTrue(src.contains("AppSettings.LaunchMode.offline")
                      && src.contains("AppSettings.LaunchMode.online"),
                      "GameDetailView's mode menu must offer both Offline and Online.")
        // The mode lives on a split Play button, not in the ellipsis menu.
        // The primary segment must be a REAL Button styled identically to
        // ProgressButton (user-verified: Menu(primaryAction:) rendered at
        // the wrong size and without the accent fill on macOS —
        // HANDOFF-2026-07-03-v8 Goal 1). The chevron is SYSTEM GRAY
        // (.bordered) and opens a teardrop POPOVER (like the Meridian
        // Verified badge), not a system menu. Both modes keep the standard
        // accent prominence — the glass-morph experiment was rejected
        // (user direction, 2026-07-03: "the transition to normal to liquid
        // glass, gotta go" / "keep that system gray").
        XCTAssertTrue(src.contains("Button { handlePlayTapped() } label: {"),
                      "The primary Play segment must be a plain Button (matches ProgressButton dims/color).")
        XCTAssertFalse(src.contains("} primaryAction: {"),
                       "Menu(primaryAction:) must NOT be used — it renders at the wrong size/color on macOS.")
        XCTAssertTrue(src.contains(".popover(isPresented: $showLaunchModePopover"),
                      "The chevron segment must open the mode picker as a teardrop popover.")
        // Approved copy (user, Jul 3 2026): rows are "Local — Fast & offline"
        // and "Online — Cloud saves & multiplayer".
        XCTAssertTrue(src.contains("\"Local\"") && src.contains("\"Fast & offline\""),
                      "The default mode row must be titled Local with the Fast & offline subtitle.")
        XCTAssertTrue(src.contains("\"Cloud saves & multiplayer\""),
                      "The Online row must keep the Cloud saves & multiplayer subtitle.")
        XCTAssertFalse(src.contains("playProminence(") || src.contains(".glassProminent"),
                       "No mode-aware glass prominence — both modes use the standard accent button; the chevron is .bordered gray.")
        // Label contract: Offline is the default and reads plain "Play";
        // only the Online opt-in earns a qualifier.
        XCTAssertTrue(src.contains("launchModeUI == .online ? \"Play Online\" : \"Play\""),
                      "The Play label must be \"Play\" for the default mode and \"Play Online\" for Online.")
        XCTAssertFalse(src.contains("Label(\"Launch Mode\", systemImage: \"network\")"),
                       "The old ellipsis-menu Launch Mode submenu must be gone (replaced by the split button).")
    }

    /// SteamStub games can ONLY run through the Steam client. The mode
    /// control must reflect that constraint up-front — Offline disabled in
    /// the menu, Online persisted by the probe — instead of letting the user
    /// pick Offline and get prompted after the fact.
    func testGameDetail_steamStubDisablesOfflineInModeMenu() throws {
        let src = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(src.contains("steamStubRequiresOnline"),
                      "GameDetailView must track the SteamStub constraint state.")
        XCTAssertTrue(src.contains("disabled: steamStubRequiresOnline"),
                      "The Offline popover row must be disabled for SteamStub games.")
        XCTAssertTrue(src.contains("gameHasSteamStubDRM"),
                      "GameDetailView must probe the installed exe for SteamStub DRM.")
        XCTAssertTrue(src.contains("Task.detached"),
                      "The SteamStub probe touches disk — it must run off the main thread.")
        XCTAssertTrue(src.contains("AppSettings.shared.setLaunchMode(.online, appID: appID)"),
                      "The probe must persist Online for SteamStub games (same switch confirmSteamPrompt makes).")
    }

    // MARK: - SteamStub detection (.bind PE section)

    /// Mirror of GameStackDetector.hasSteamStub
    /// MIRROR CONTRACT: must match GameStackDetector.hasSteamStub in
    /// Meridian/Engine/GameStackResolver.swift.
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

    // MARK: - SteamStub → Online prompt wiring

    /// SteamStub-encrypted exes cannot run under the gbe_fork shim (the exe
    /// itself is encrypted; only a signed-in Steam client decrypts it). The
    /// Offline pipeline must detect this and raise the consent prompt instead
    /// of attempting a shim launch that fails opaquely.
    func testLauncher_promptsForSteamOnSteamStubGames() throws {
        let src = try readSource("Meridian/Launch/Launcher.swift")
        XCTAssertTrue(src.contains("gameHasSteamStubDRM"),
                      "The Offline pipeline must probe for SteamStub DRM")
        XCTAssertTrue(src.contains("enum SteamPrompt"),
                      "Launcher must publish a SteamPrompt for UI consent")
        XCTAssertTrue(src.contains("case steamRequired(Game)")
                      && src.contains("case signInRequired(Game)"),
                      "SteamPrompt must cover SteamStub (steamRequired) and first-time Online (signInRequired)")
        XCTAssertTrue(src.contains("func confirmSteamPrompt(") && src.contains("func dismissSteamPrompt()"),
                      "Launcher must expose confirm/dismiss entry points for the prompt")
        XCTAssertTrue(src.contains("setLaunchMode(.online, appID: game.id)"),
                      "Confirming the SteamStub prompt must switch the game to Online mode")

        let prefixSrc = try readSource("Meridian/Engine/WinePrefix.swift")
        XCTAssertTrue(prefixSrc.contains("func gameHasSteamStubDRM(appID:"),
                      "WinePrefix must expose the SteamStub probe")
        let resolverSrc = try readSource("Meridian/Engine/GameStackResolver.swift")
        XCTAssertTrue(resolverSrc.contains("static func hasSteamStub(exe:"),
                      "GameStackDetector must implement the .bind PE section probe")
    }

    // MARK: - One-time interactive Steam sign-in (Online mode)

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
        XCTAssertTrue(launcher.contains("hasSteamLoginSession()"),
                      "launchOnline must branch silent-vs-interactive on the on-disk Steam session")
        XCTAssertTrue(launcher.contains(".signInRequired(game)"),
                      "First-time Online must raise the consent prompt before any Steam window opens")
        XCTAssertTrue(launcher.contains("signInInteractively"),
                      "launchOnline must fall back to the interactive sign-in")

        let detail = try readSource("Meridian/Views/Library/GameDetailView.swift")
        XCTAssertTrue(detail.contains("launcher.steamPrompt") && detail.contains("confirmSteamPrompt"),
                      "GameDetailView must render the Steam consent prompt and wire confirm/dismiss")
    }
}
