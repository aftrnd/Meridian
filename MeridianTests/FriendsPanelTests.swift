import XCTest

/// Guard tests for the Discord-style friends panel (July 2026):
/// persona-state mapping, panel wiring, and the enriched profile fields.
final class FriendsPanelTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appending(path: relativePath), encoding: .utf8)
    }

    // MARK: - Persona-state mapping (mirror of PlayerSummary)

    /// Mirror of PlayerSummary.personaStateText (in-game handled separately).
    /// Valve's personastate values: 0 Offline, 1 Online, 2 Busy, 3 Away,
    /// 4 Snooze, 5 Looking to Trade, 6 Looking to Play.
    private func personaStateText(_ state: Int) -> String {
        switch state {
        case 1:  return "Online"
        case 2:  return "Busy"
        case 3:  return "Away"
        case 4:  return "Snooze"
        case 5:  return "Looking to Trade"
        case 6:  return "Looking to Play"
        default: return "Offline"
        }
    }

    /// Mirror of PlayerSummary.activitySortOrder.
    private func activitySortOrder(personaState: Int, isInGame: Bool) -> Int {
        if isInGame { return 0 }
        switch personaState {
        case 1, 5, 6: return 1
        case 2, 3, 4: return 2
        default:      return 3
        }
    }

    func testPersonaStateText_coversAllValveStates() {
        XCTAssertEqual(personaStateText(0), "Offline")
        XCTAssertEqual(personaStateText(1), "Online")
        XCTAssertEqual(personaStateText(2), "Busy")
        XCTAssertEqual(personaStateText(3), "Away")
        XCTAssertEqual(personaStateText(4), "Snooze")
        XCTAssertEqual(personaStateText(5), "Looking to Trade")
        XCTAssertEqual(personaStateText(6), "Looking to Play")
        // Unknown future states degrade to Offline rather than crashing.
        XCTAssertEqual(personaStateText(99), "Offline")
    }

    func testActivitySortOrder_inGameBeatsOnlineBeatsAwayBeatsOffline() {
        let inGame  = activitySortOrder(personaState: 1, isInGame: true)
        let online  = activitySortOrder(personaState: 1, isInGame: false)
        let away    = activitySortOrder(personaState: 3, isInGame: false)
        let offline = activitySortOrder(personaState: 0, isInGame: false)
        XCTAssertLessThan(inGame, online)
        XCTAssertLessThan(online, away)
        XCTAssertLessThan(away, offline)
    }

    // MARK: - Wiring guards

    func testPlayerSummary_decodesEnrichedProfileFields() throws {
        let source = try readSource("Meridian/Models/PlayerSummary.swift")
        for field in ["realname", "loccountrycode", "timecreated"] {
            XCTAssertTrue(source.contains("\"\(field)\""),
                          "PlayerSummary must decode \(field) for the friend detail popover.")
        }
        XCTAssertTrue(source.contains("var personaStateText"),
                      "PlayerSummary must expose personaStateText.")
        XCTAssertTrue(source.contains("var statusColor"),
                      "PlayerSummary must expose statusColor for the Discord-style dots.")
    }

    func testSteamAPIService_exposesSteamLevelEndpoint() throws {
        let source = try readSource("Meridian/Steam/SteamAPIService.swift")
        XCTAssertTrue(source.contains("func fetchSteamLevel("),
                      "SteamAPIService must expose fetchSteamLevel for the friend detail popover.")
        XCTAssertTrue(source.contains("/IPlayerService/GetSteamLevel/v1/"),
                      "fetchSteamLevel must call IPlayerService/GetSteamLevel.")
    }

    func testLibraryStore_fetchesOwnSummaryAndFriendsSince() throws {
        let source = try readSource("Meridian/Steam/SteamLibraryStore.swift")
        XCTAssertTrue(source.contains("var ownSummary: PlayerSummary?"),
                      "SteamLibraryStore must expose ownSummary for the panel header.")
        XCTAssertTrue(source.contains("var friendsSince: [String: Date]"),
                      "SteamLibraryStore must expose the friendsSince map from GetFriendList.")
    }

    func testContentView_wiresFriendsInspector() throws {
        let source = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertTrue(source.contains(".inspector(isPresented: $showFriendsPanel)"),
                      "ContentView must present FriendsPanel as a trailing inspector.")
        XCTAssertTrue(source.contains("FriendsPanel()"),
                      "The inspector content must be FriendsPanel.")
    }

    /// REVERSAL GUARD (July 11 2026, same session): window expansion was tried
    /// first and user-rejected as "really messy and out of sync". The panel
    /// must NEVER resize the window — standard inspector compression instead,
    /// with Home's scroll rows relaxing their minimum column count (5 → 3) via
    /// the friendsPanelOpen environment flag so cards stay full-size (Apple
    /// Music lyrics-panel pattern). Do not reintroduce NSWindow.setFrame here.
    func testContentView_doesNotResizeWindowForFriendsPanel() throws {
        let source = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertFalse(source.contains("window.setFrame("),
                       "The friends panel must not resize the window — user-rejected as messy/out of sync.")
        XCTAssertTrue(source.contains(#".environment(\.friendsPanelOpen, showFriendsPanel)"#),
                      "ContentView must publish friendsPanelOpen so Home rows can relax their column floor.")
    }

    /// FINAL DESIGN GUARD (July 12 2026, third iteration — history matters):
    /// 1. Window expansion (NSWindow.setFrame) — rejected: messy/out of sync.
    /// 2. Whole-content width lock ("cover everything") — rejected: rows
    ///    showed an arbitrary mid-card slice at the panel edge.
    /// 3. CURRENT: the HERO stays pixel-locked at its pre-open width (panel
    ///    covers its trailing edge; explicit minWidth 0 stops the fixed width
    ///    from becoming a window minimum → AppKit window growth; .leading
    ///    stops the vertical ScrollView centering oversized content), while
    ///    the GAME ROWS re-fit ONCE to the computed visible width
    ///    (locked − FriendsPanel.width) with a 3-column floor — "3 full games
    ///    + the exact edge spacing the row would have if the panel wasn't
    ///    there". Rows are driven by the computed target, never per-frame
    ///    geometry, so the slide stays smooth.
    /// FINAL DESIGN GUARD (July 12 2026, FOURTH iteration — full history):
    /// 1. Window expansion (NSWindow.setFrame) — rejected: messy/out of sync.
    /// 2. Metric compression (rows re-fit to 3-4 smaller/larger cards) —
    ///    rejected: "nothing should change size".
    /// 3. Hero locked + rows re-fit to visible strip — rejected: rows still
    ///    moved ("those rows shouldn't move AT ALL").
    /// 4. CURRENT: the ENTIRE Home layout freezes at its pre-open width
    ///    (explicit minWidth 0 stops window growth; .leading stops ScrollView
    ///    centering). Nothing moves or resizes — ever. Instead the PANEL
    ///    WIDTH is computed (ContentView.friendsPanelWidth) so its edge lands
    ///    exactly on the row's natural "3 full cards + standard peek"
    ///    boundary. The close direction keeps the lock (generation-guarded
    ///    deferred release) so the slide reveals static geometry.
    func testHome_freezesLayoutAndPanelWidthLandsOnCardBoundary() throws {
        let home = try readSource("Meridian/Views/HomeView.swift")
        XCTAssertTrue(home.contains("lockedWidth = contentWidth"),
                      "HomeView must capture the pre-open width when the friends panel opens.")
        XCTAssertTrue(home.contains(".frame(width: lockedWidth, alignment: .leading)"),
                      "The whole Home content must pin to the locked width so the panel covers rather than compresses.")
        XCTAssertTrue(home.contains(".frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)"),
                      "The locked content needs an outer frame with EXPLICIT minWidth 0 + leading alignment (window-growth + ScrollView-centering regressions).")
        XCTAssertTrue(home.contains("guard generation == panelTransitionGeneration"),
                      "Lock release must be deferred (generation-guarded) until the close animation completes.")
        XCTAssertFalse(home.contains("FriendsPanel.width"),
                       "Rows must NOT subtract the panel width — nothing re-fits; the panel is sized to the layout, not vice versa.")

        let content = try readSource("Meridian/Views/ContentView.swift")
        XCTAssertTrue(content.contains("private var friendsPanelWidth"),
                      "ContentView must compute the panel width from the frozen layout.")
        XCTAssertTrue(content.contains("CardLayoutMetrics.peekFraction"),
                      "Panel width math must land the panel edge on the natural card-peek boundary.")
        XCTAssertTrue(content.contains("if !showFriendsPanel { detailFullWidth = newWidth }"),
                      "The width the panel math is based on must only be measured while the panel is closed.")
    }

    /// Apple-standard large title (Sept 7 2026, user direction): the panel
    /// title lives IN the scroll content like Apple Music's Home/New/Radio
    /// pages — large, bold, leading-aligned, scrolling with the content.
    /// The earlier pinned nav-strip design (safeAreaInset + ignoresSafeArea,
    /// July 12 2026) is retired — do not reintroduce it.
    func testFriendsPanel_titleFollowsAppleLargeTitleStyle() throws {
        let source = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        XCTAssertTrue(source.contains(".font(.largeTitle.bold())"),
                      "Panel title keeps the major page-title weight.")
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .top"),
                       "Title must scroll with the content (Apple Music style), not pin into the nav strip.")
        XCTAssertFalse(source.contains(".ignoresSafeArea(edges: .top)"),
                       "No safe-area hoist — that was the retired nav-strip title design.")
    }

    /// Friend sections are collapsible — the header row toggles its group
    /// with a rotating chevron (user request July 12 2026). Collapse state
    /// is a title-keyed set so every persona-state section gets it for free.
    func testFriendsPanel_sectionsAreCollapsible() throws {
        let source = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        XCTAssertTrue(source.contains("collapsedSections: Set<String>"),
                      "FriendsPanel must track collapsed sections by title.")
        XCTAssertTrue(source.contains("expanded: Binding<Bool>"),
                      "Section headers must take an expansion binding and act as the toggle.")
        XCTAssertTrue(source.contains(".rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))"),
                      "The header chevron must rotate to indicate expansion state.")
    }

    /// The rows' forward chevrons must shift inward by the covered width so
    /// they stay visible at the panel edge, mirroring the leading side
    /// (user report July 12 2026: right chevron lost under the panel).
    func testHome_forwardChevronsStayVisibleAtPanelEdge() throws {
        let home = try readSource("Meridian/Views/HomeView.swift")
        XCTAssertTrue(home.contains("trailingObscured: coverWidth"),
                      "GameScrollRow must receive the covered width for its forward chevron inset.")
        XCTAssertTrue(home.contains("10 + trailingObscured"),
                      "The forward chevron must shift inward by the covered width.")
        let panel = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        XCTAssertTrue(panel.contains("@Entry var friendsPanelCoverWidth"),
                      "The covered width must be published through the environment.")
    }

    func testFriendsPanel_usesLiquidGlassIslands() throws {
        let source = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        XCTAssertTrue(source.contains("GlassRoundedBackground"),
                      "Online/Offline friend groups must sit in Liquid Glass islands (glassEffect on macOS 26, material fallback) so the panel doesn't read as a second sidebar.")
        XCTAssertTrue(source.contains("@Entry var friendsPanelOpen"),
                      "FriendsPanel.swift must declare the friendsPanelOpen environment key.")
    }

    func testFriendsPanel_groupsByActivity() throws {
        let source = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        // Steam-client-style persona-state sections (user request July 12
        // 2026): In Game, then Online / Busy / Away / Snooze / Offline.
        for section in ["\"In Game\"", "\"Online\"", "\"Busy\"", "\"Away\"", "\"Snooze\"", "\"Offline\""] {
            XCTAssertTrue(source.contains(section),
                          "FriendsPanel must group friends into the \(section) section.")
        }
        // Own-profile header: removed July 12 2026 (status can't be changed
        // from Meridian), REINSTATED Sept 10 2026 by user direction as a
        // read-only identity row matching the Steam client's friends
        // window. It opens the same detail popover as a friend row.
        XCTAssertTrue(source.contains("OwnProfileHeader(me: me)"),
                      "FriendsPanel must show the user's own profile at the top, like Steam's friends list.")
        XCTAssertFalse(source.contains("ownProfileHero"),
                       "The old editable-status hero card design must not come back — the header is read-only.")
    }

    /// Sidebar parity (Sept 10 2026): section headers are sentence case in
    /// the sidebar's 11 pt header style, rows use the 13 pt body size, and
    /// Offline starts collapsed so an opened panel shows who's around.
    func testFriendsPanel_matchesSidebarTypographyAndCollapsesOffline() throws {
        let source = try readSource("Meridian/Views/Friends/FriendsPanel.swift")
        XCTAssertFalse(source.contains("Text(title.uppercased())"),
                       "No all-caps section headers — sentence case like the sidebar.")
        XCTAssertFalse(source.contains(".textCase(.uppercase)"),
                       "No all-caps labels in the friends surfaces.")
        XCTAssertTrue(source.contains("collapsedSections: Set<String> = [\"Offline\"]"),
                      "Offline must start collapsed.")
    }

    /// Online friends use GREEN, not Steam blue (user direction July 12 2026:
    /// "dont think we need the steam blue for online status. green was fine").
    func testStatusColor_onlineIsGreenNotBlue() throws {
        let source = try readSource("Meridian/Models/PlayerSummary.swift")
        XCTAssertTrue(source.contains("case 1, 5, 6: return .green"),
                      "Online persona states must map to green.")
        XCTAssertFalse(source.contains("return .blue"),
                       "No Steam-blue status dots.")
    }

    func testHomeView_carouselShowsFiveGames() throws {
        let source = try readSource("Meridian/Views/HomeView.swift")
        XCTAssertTrue(source.contains("carouselCount = 5"),
                      "Home hero carousel must rotate the 5 most recent games (user direction July 11 2026).")
    }

    func testHomeFriendCard_opensDetailPopover() throws {
        let source = try readSource("Meridian/Views/HomeView.swift")
        XCTAssertTrue(source.contains("FriendDetailPopover(friend: friend)"),
                      "Home friend cards must open the shared FriendDetailPopover on click.")
    }
}
